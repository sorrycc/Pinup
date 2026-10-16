package upload

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"pinup/internal/hosts"
	"pinup/internal/imageproc"
	"pinup/internal/paths"
)

func TestMain(m *testing.M) {
	dir, _ := os.MkdirTemp("", "pinup-upload-test")
	paths.SetRoot(dir)
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

// run uploads sources on a main loop of the test's own until the batch is
// done.
func run(t *testing.T, u *Uploader, queue chan func(), sources []Source, host hosts.Host) Result {
	t.Helper()
	var res *Result
	u.Upload(sources, host, imageproc.Options{Conversion: imageproc.Original, Quality: 1}, func(r Result) { res = &r })
	deadline := time.After(20 * time.Second)
	for res == nil {
		select {
		case fn := <-queue:
			fn()
		case <-deadline:
			t.Fatal("upload never finished")
		}
	}
	return *res
}

func newUploader() (*Uploader, chan func()) {
	queue := make(chan func(), 1024)
	return New(func(fn func()) { queue <- fn }), queue
}

func TestUploadAndRetry(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if calls.Add(1) == 1 {
			w.WriteHeader(502)
			return
		}
		w.Write([]byte(`{"data":{"url":"https://cdn/` + r.URL.Query().Get("n") + `","size":` + itoa(len(body)) + `}}`))
	}))
	defer server.Close()
	cfg := hosts.DefaultCustom()
	cfg.URL = server.URL + "/up?n={name}"
	cfg.Body = hosts.Binary
	host := hosts.Custom{HostName: "Test", Config: cfg}

	file := filepath.Join(t.TempDir(), "a.png")
	os.WriteFile(file, imageproc.TestImage(), 0o644)
	u, queue := newUploader()
	var progress []float64
	u.OnProgress = func(p float64) { progress = append(progress, p) }
	res := run(t, u, queue, []Source{NewSource(file)}, host)
	if len(res.Entries) != 1 || res.Entries[0].URL != "https://cdn/a.png" || res.Entries[0].Host != "Test" ||
		res.Entries[0].Width != 64 || res.Entries[0].Thumbnail == "" {
		t.Fatalf("result %+v", res)
	}
	if calls.Load() != 2 {
		t.Errorf("retried once after a 502: %d calls", calls.Load())
	}
	if u.Busy() || u.LastError() != "" || len(progress) == 0 {
		t.Errorf("idle after: busy=%v err=%q progress=%v", u.Busy(), u.LastError(), progress)
	}
}

func TestFailureKeepsTemporary(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(401)
		w.Write([]byte(`{"message":"bad token"}`))
	}))
	defer server.Close()
	cfg := hosts.DefaultCustom()
	cfg.URL = server.URL
	host := hosts.Custom{HostName: "Test", Config: cfg}

	dir := paths.Scratch()
	shot := filepath.Join(dir, "Screenshot.png")
	os.WriteFile(shot, imageproc.TestImage(), 0o644)
	u, queue := newUploader()
	res := run(t, u, queue, []Source{{Path: shot, Name: "Screenshot.png", Temporary: true}}, host)
	if len(res.Failures) != 1 || !hosts.NeedsSettings(res.Failures[0].Err) {
		t.Fatalf("failures %+v", res.Failures)
	}
	if u.LastError() != "Screenshot.png: The server answered 401: bad token" {
		t.Errorf("last error %q", u.LastError())
	}
	kept := u.Failed()[0].Path
	if filepath.Dir(filepath.Dir(kept)) != paths.Failed() {
		t.Errorf("kept in Failed: %s", kept)
	}
	if _, err := os.Stat(dir); err == nil {
		t.Error("scratch folder removed")
	}
	// A new launch finds it.
	u2, _ := newUploader()
	u2.RestoreFailed()
	if len(u2.Failed()) != 1 || u2.LastError() == "" {
		t.Error("restore failed")
	}
	u2.DiscardFailed()
	time.Sleep(100 * time.Millisecond)
	if _, err := os.Stat(kept); err == nil {
		t.Error("discard deletes it")
	}
}

func TestFoldersRefused(t *testing.T) {
	u, _ := newUploader()
	if u.Upload([]Source{NewSource(t.TempDir())}, hosts.NoHost{}, imageproc.Options{}, nil) {
		t.Error("only folders")
	}
}

func TestCombinedProgress(t *testing.T) {
	if CombinedProgress(nil) != 0 || CombinedProgress([][2]float64{{100, 1}, {300, 0}}) != 0.25 ||
		CombinedProgress([][2]float64{{1, 1}, {1, 0.5}}) != 0.75 {
		t.Error("progress weighed by size")
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for ; n > 0; n /= 10 {
		b = append([]byte{byte('0' + n%10)}, b...)
	}
	return string(b)
}
