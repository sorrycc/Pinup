package hosts

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"pinup/internal/imageproc"
)

func TestRenderPath(t *testing.T) {
	date := time.Unix(1_790_000_000, 0)
	got := RenderPath("{year}/{month}/{name}.{ext}", "Cat Pic.png", date)
	if !strings.HasSuffix(got, "/Cat Pic.png") || len(strings.Split(got, "/")) != 3 {
		t.Errorf("template: %q", got)
	}
	if got := RenderPath("img/{random}", "Cat Pic.png", date); !strings.HasSuffix(got, ".png") {
		t.Errorf("template adds extension: %q", got)
	}
	if got := RenderPath("{year}/{name}", "Pasted Image 2026-10-01 at 12.30.45.png", date); !strings.HasSuffix(got, "12.30.45.png") {
		t.Errorf("dotted names keep their extension: %q", got)
	}
	if got := RenderPath("/{timestamp}/", "a", date); got != "1790000000" {
		t.Errorf("slashes trimmed: %q", got)
	}
}

func TestWriteBase64(t *testing.T) {
	dir := t.TempDir()
	for _, n := range []int{0, 1, 2, 3, 786_431, 786_432, 786_433, 2_000_001} {
		blob := make([]byte, n)
		for i := range blob {
			blob[i] = byte(i * 31)
		}
		src := filepath.Join(dir, "blob")
		os.WriteFile(src, blob, 0o644)
		dst := filepath.Join(dir, "blob.b64")
		if err := writeBase64(dst, "<", src, ">"); err != nil {
			t.Fatal(err)
		}
		got, _ := os.ReadFile(dst)
		if string(got) != "<"+base64.StdEncoding.EncodeToString(blob)+">" {
			t.Errorf("base64 stream of %d bytes", n)
		}
	}
}

func prepared(t *testing.T, name string) imageproc.File {
	t.Helper()
	path := filepath.Join(t.TempDir(), "c.png")
	os.WriteFile(path, []byte("hello"), 0o644)
	return imageproc.File{Path: path, Name: name, MIMEType: "image/png", Size: 5}
}

func jsonBody(t *testing.T, req *Request) map[string]string {
	t.Helper()
	data, err := os.ReadFile(req.Body)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]string
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatalf("not JSON: %s", data)
	}
	return m
}

func TestCustomJSON(t *testing.T) {
	file := prepared(t, `c "q".png`)
	hello := base64.StdEncoding.EncodeToString([]byte("hello"))
	cfg := DefaultCustom()
	cfg.URL = "https://example.com/up"
	cfg.Body = JSON
	cfg.FileField = "image"
	cfg.Fields = "album=cats\nimage=ignored"
	req, err := Custom{Config: cfg, Headers: "Authorization: Bearer x"}.Request(file, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	got := jsonBody(t, req)
	want := map[string]string{"album": "cats", "fileName": `c "q".png`, "image": hello}
	if len(got) != len(want) || got["album"] != "cats" || got["fileName"] != want["fileName"] || got["image"] != hello {
		t.Errorf("custom JSON body: %v", got)
	}
	if req.Header.Get("Authorization") != "Bearer x" {
		t.Error("custom headers")
	}

	token := DefaultCustom()
	token.URL = "https://example.com/api/upload"
	token.Body = JSON
	token.URLPath = "data"
	req, _ = Custom{Config: token}.Request(file, t.TempDir())
	if got := jsonBody(t, req); len(got) != 2 || got["file"] != hello || got["fileName"] != `c "q".png` {
		t.Errorf("token JSON body: %v", got)
	}
	link, err := Custom{Config: token}.Link([]byte(`{"data":"https://x/a.png"}`), file, req)
	if link != "https://x/a.png" || err != nil {
		t.Errorf("link at top-level key: %q %v", link, err)
	}

	cfg.FileField = "fileName"
	req, _ = Custom{Config: cfg}.Request(file, t.TempDir())
	data, _ := os.ReadFile(req.Body)
	if strings.Count(string(data), `"fileName"`) != 1 {
		t.Errorf("duplicate fileName key: %s", data)
	}
	cfg.Fields = ""
	req, _ = Custom{Config: cfg}.Request(file, t.TempDir())
	if got := jsonBody(t, req); len(got) != 1 || got["fileName"] != hello {
		t.Errorf("JSON body with only the file: %v", got)
	}
}

func TestCustomMultipartAndURL(t *testing.T) {
	file := prepared(t, "a b.png")
	cfg := DefaultCustom()
	cfg.URL = "https://example.com/up/{name}"
	cfg.Fields = "k=v"
	req, err := Custom{Config: cfg}.Request(file, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if req.URL != "https://example.com/up/a%20b.png" || req.Method != "POST" {
		t.Errorf("url %q method %q", req.URL, req.Method)
	}
	data, _ := os.ReadFile(req.Body)
	if !bytes.Contains(data, []byte(`name="k"`)) || !bytes.Contains(data, []byte(`filename="a b.png"`)) || !bytes.Contains(data, []byte("hello")) {
		t.Errorf("multipart: %s", data)
	}
	cfg.URL = "ftp://x"
	if _, err := (Custom{HostName: "API", Config: cfg}).Request(file, t.TempDir()); !NeedsSettings(err) {
		t.Errorf("bad URL needs settings: %v", err)
	}
}

func TestValueAt(t *testing.T) {
	var v any
	dec := json.NewDecoder(strings.NewReader(`{"data":{"links":["https://a","https://b"],"id":7}}`))
	dec.UseNumber()
	dec.Decode(&v)
	if ValueAt("data.links.1", v) != "https://b" || ValueAt("data.id", v) != "7" || ValueAt("data.nope", v) != "" {
		t.Error("json paths")
	}
}

func TestS3Signature(t *testing.T) {
	body := filepath.Join(t.TempDir(), "s3.png")
	os.WriteFile(body, []byte("pinup-s3-body"), 0o644)
	file := imageproc.File{Path: body, Name: "s3.png", MIMEType: "image/png", Size: 13}
	// From the Swift version's self test, which matched botocore.
	cases := []struct {
		pathStyle bool
		key, url  string
		signature string
	}{
		{true, "2026/10/hello.png", "https://s3.example.com:9000/pics/2026/10/hello.png",
			"a96211e6f3d13bff74f04c8453102bcf7320e2c490b015cd5f15f12b02995bcb"},
		{false, "2026/10/hello world+中.png", "https://pics.s3.example.com:9000/2026/10/hello%20world%2B%E4%B8%AD.png",
			"e6f9358826e3fd350ca23020cb665638ebe294a90fc7b02389bd34510366a342"},
	}
	for _, c := range cases {
		cfg := DefaultS3()
		cfg.Endpoint = "https://s3.example.com:9000"
		cfg.Region = "auto"
		cfg.Bucket = "pics"
		cfg.AccessKeyID = "AKIDEXAMPLE"
		cfg.PathStyle = c.pathStyle
		h := S3{Config: cfg, Secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"}
		req, err := h.Sign(file, c.key, time.Unix(1_790_000_000, 0))
		if err != nil {
			t.Fatal(err)
		}
		want := "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20260921/auto/s3/aws4_request, " +
			"SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, Signature=" + c.signature
		if req.URL != c.url || req.Header.Get("Authorization") != want {
			t.Errorf("S3 %s\n%s", req.URL, req.Header.Get("Authorization"))
		}
		cfg.PublicURL = "https://img.example.com/{key}"
		link, _ := S3{Config: cfg, Secret: "x"}.Link(nil, file, req)
		if !strings.HasPrefix(link, "https://img.example.com/2026/10/hello") {
			t.Errorf("public link %q", link)
		}
	}
	if _, err := (S3{HostName: "B", Config: DefaultS3()}).Request(file, ""); !NeedsSettings(err) {
		t.Error("an empty S3 host needs settings")
	}
}

func TestErrorText(t *testing.T) {
	cases := map[string]string{
		`{"message":"bad token"}`:          "bad token",
		`{"error":{"message":"nope"}}`:     "nope",
		"<Error><Message>Denied</Message>": "Denied",
		"  plain  ":                        "plain",
	}
	for in, want := range cases {
		if got := ErrorText([]byte(in)); got != want {
			t.Errorf("ErrorText(%q) = %q", in, got)
		}
	}
	if (&Error{Kind: HTTP, Status: 401}).Error() != "The server answered 401 Unauthorized." {
		t.Error("HTTP error text")
	}
}
