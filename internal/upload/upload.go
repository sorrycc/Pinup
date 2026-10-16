// Package upload runs uploads: up to three at a time across every batch,
// each prepared and sent off the main thread, with combined progress for
// the menu bar icon.
package upload

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"pinup/internal/history"
	"pinup/internal/hosts"
	"pinup/internal/imageproc"
	"pinup/internal/paths"
)

// Concurrency is how many files upload at once.
const Concurrency = 3

// Source is a file to upload. Temporary ones, like a pasted image or a
// screenshot, sit in a folder of their own, which is deleted once they
// upload.
type Source struct {
	Path      string
	Name      string
	Temporary bool
}

// NewSource is a file the user chose, uploaded under its own name.
func NewSource(path string) Source { return Source{Path: path, Name: filepath.Base(path)} }

// Failure is an upload that failed, with the source to retry it from.
type Failure struct {
	Source Source
	Err    error
}

// Result is how a batch went.
type Result struct {
	Entries  []history.Entry
	Failures []Failure
	Total    int
}

// tracked is one file of the batches in flight. Finished files stay until
// every file is done, so the ring only moves forward as they finish.
type tracked struct {
	weight   int64
	fraction float64
	finished bool
}

// batch is a batch in flight: what is still on its way and what has
// arrived, so a quit in the middle of it loses neither.
type batch struct {
	waiting  map[string]Source
	uploaded []indexed
}

type indexed struct {
	index int
	entry history.Entry
}

// Uploader keeps the state of the uploads. Its methods and callbacks run
// on the main thread; Post brings the work done off it back there.
type Uploader struct {
	// Post runs fn on the main thread, later, in the order posted.
	Post func(fn func())
	// OnProgress reports combined progress from 0 to 1 while anything
	// uploads, at most 30 times a second.
	OnProgress func(progress float64)
	// OnIdle is called once, the next time nothing is uploading. For a
	// quit that waits.
	OnIdle func()

	tracked    map[string]*tracked
	batches    map[string]*batch
	lastReport time.Time
	progress   float64
	// lastError says why the last batch failed, until a later upload
	// succeeds. The menu shows it, for a HUD that went unseen.
	lastError string
	// failed are the files whose last upload failed, ready for Retry.
	failed []Source
	slots  chan struct{}
	client *http.Client
}

// New makes an uploader that posts to the main thread with post.
func New(post func(func())) *Uploader {
	return &Uploader{
		Post:    post,
		tracked: map[string]*tracked{},
		batches: map[string]*batch{},
		slots:   make(chan struct{}, Concurrency),
		client: &http.Client{Transport: &http.Transport{
			Proxy:                 http.ProxyFromEnvironment,
			MaxConnsPerHost:       Concurrency,
			ResponseHeaderTimeout: idleTimeout,
			TLSHandshakeTimeout:   idleTimeout,
			ForceAttemptHTTP2:     true,
		}},
	}
}

// idleTimeout is the silence that ends an upload. There is no limit on
// the whole transfer: a large file on a slow line takes as long as it
// takes.
const idleTimeout = 60 * time.Second

// Busy reports whether anything uploads.
func (u *Uploader) Busy() bool { return len(u.tracked) > 0 || len(u.batches) > 0 }

// ActiveCount is the files still uploading or waiting their turn.
func (u *Uploader) ActiveCount() int {
	n := 0
	for _, t := range u.tracked {
		if !t.finished {
			n++
		}
	}
	return n
}

// Progress is the combined progress of the uploads in flight.
func (u *Uploader) Progress() float64 { return u.progress }

// LastError says why the last batch failed, or "".
func (u *Uploader) LastError() string { return u.lastError }

// Failed are the files whose last upload failed.
func (u *Uploader) Failed() []Source { return u.failed }

// Upload sends sources to host, and calls done on the main thread when the
// batch is over. Folders are left out; it returns false when only folders
// were given.
func (u *Uploader) Upload(sources []Source, host hosts.Host, opts imageproc.Options, done func(Result)) bool {
	var files []Source
	for _, s := range sources {
		if info, err := os.Stat(s.Path); err == nil && info.IsDir() {
			continue
		}
		files = append(files, s)
	}
	if len(files) == 0 {
		return len(sources) == 0
	}
	log.Printf("uploading %d file(s)", len(files))
	ids := make([]string, len(files))
	b := &batch{waiting: map[string]Source{}}
	for i, s := range files {
		ids[i] = paths.NewID()
		b.waiting[ids[i]] = s
		size := int64(1)
		if info, err := os.Stat(s.Path); err == nil && info.Size() > 0 {
			size = info.Size()
		}
		u.tracked[ids[i]] = &tracked{weight: size}
	}
	batchID := paths.NewID()
	u.batches[batchID] = b
	u.report(true)

	go func() {
		results := make([]result, len(files))
		var wg sync.WaitGroup
		for i, s := range files {
			// In order, and before anything is read, converted or signed.
			u.slots <- struct{}{}
			wg.Add(1)
			go func() {
				defer wg.Done()
				id := ids[i]
				entry, err := perform(u.client, s, id, host, opts, true, u.reporter(id))
				<-u.slots
				results[i] = result{entry, err}
				u.Post(func() { u.finished(id, i, results[i], batchID) })
			}()
		}
		wg.Wait()
		u.Post(func() {
			// Gone when a quit took the batch over, which has recorded it.
			if _, ok := u.batches[batchID]; !ok {
				return
			}
			delete(u.batches, batchID)
			u.finish(results, done)
		})
	}()
	return true
}

type result struct {
	entry history.Entry
	err   error // a *Failure
}

// finished notes one file's outcome in its batch right away, in case a
// quit comes before the rest.
func (u *Uploader) finished(id string, index int, r result, batchID string) {
	if b := u.batches[batchID]; b != nil {
		source := b.waiting[id]
		delete(b.waiting, id)
		if r.err == nil {
			b.uploaded = append(b.uploaded, indexed{index, r.entry})
			// Only now that the upload is on record does its screenshot
			// or pasted image go.
			if source.Temporary {
				go removeTemporary(source.Path)
			}
		}
	}
	if t := u.tracked[id]; t != nil {
		t.fraction, t.finished = 1, true
	}
	all := true
	for _, t := range u.tracked {
		all = all && t.finished
	}
	if all {
		clear(u.tracked)
	}
	u.report(true)
}

func (u *Uploader) finish(results []result, done func(Result)) {
	res := Result{Total: len(results)}
	for _, r := range results {
		if r.err == nil {
			res.Entries = append(res.Entries, r.entry)
			continue
		}
		var f *Failure
		errors.As(r.err, &f)
		res.Failures = append(res.Failures, *f)
		log.Printf("%s: %v", f.Source.Name, f.Err)
	}
	for _, f := range res.Failures {
		u.failed = append(u.failed, f.Source)
	}
	if len(res.Failures) > 0 {
		u.lastError = FailureMessage(res.Failures)
	} else if len(res.Entries) > 0 {
		u.lastError = ""
	}
	if done != nil {
		done(res)
	}
	if !u.Busy() && u.OnIdle != nil {
		idle := u.OnIdle
		u.OnIdle = nil
		idle()
	}
}

// FailureMessage names the first failure and counts the rest.
func FailureMessage(failures []Failure) string {
	msg := failures[0].Source.Name + ": " + failures[0].Err.Error()
	if len(failures) > 1 {
		msg += fmt.Sprintf(" And %d more.", len(failures)-1)
	}
	return msg
}

func (f *Failure) Error() string { return f.Err.Error() }

// Abandon is for a quit in the middle of uploads. It returns the files
// that already arrived, for History, and moves screenshots and pasted
// images still on their way to the Failed folder, where the next launch
// offers them again.
func (u *Uploader) Abandon() []history.Entry {
	var entries []history.Entry
	for _, b := range u.batches {
		slices.SortFunc(b.uploaded, func(a, b indexed) int { return a.index - b.index })
		for _, up := range b.uploaded {
			entries = append(entries, up.entry)
		}
		for _, s := range b.waiting {
			if s.Temporary {
				keep(s)
			}
		}
	}
	clear(u.batches)
	return entries
}

// RestoreFailed picks up screenshots and pasted images that failed before
// Pinup last quit.
func (u *Uploader) RestoreFailed() {
	folders, _ := os.ReadDir(paths.Failed())
	var files []Source
	for _, folder := range folders {
		if !folder.IsDir() || strings.HasPrefix(folder.Name(), ".") {
			continue
		}
		dir := filepath.Join(paths.Failed(), folder.Name())
		found := ""
		entries, _ := os.ReadDir(dir)
		for _, e := range entries {
			if e.Type().IsRegular() && !strings.HasPrefix(e.Name(), ".") {
				found = filepath.Join(dir, e.Name())
				break
			}
		}
		if found == "" {
			os.RemoveAll(dir)
			continue
		}
		files = append(files, Source{Path: found, Name: filepath.Base(found), Temporary: true})
	}
	if len(files) == 0 {
		return
	}
	u.failed = files
	if len(files) == 1 {
		u.lastError = "1 screenshot or pasted image didn't upload before Pinup quit."
	} else {
		u.lastError = fmt.Sprintf("%d screenshots or pasted images didn't upload before Pinup quit.", len(files))
	}
}

// DiscardFailed forgets failed uploads, deleting kept screenshots and
// pasted images.
func (u *Uploader) DiscardFailed() {
	sources := u.failed
	u.failed, u.lastError = nil, ""
	go func() {
		for _, s := range sources {
			if s.Temporary {
				removeTemporary(s.Path)
			}
		}
	}()
}

// TakeFailed returns the failed files and forgets them, for a retry.
func (u *Uploader) TakeFailed() []Source {
	sources := u.failed
	u.failed = nil
	return sources
}

// Test uploads a small generated image to host without touching History
// or the menu bar icon, for the Test button in Settings, and calls done on
// the main thread with the link or the error.
func (u *Uploader) Test(host hosts.Host, done func(link string, err error)) {
	go func() {
		scratch := paths.Scratch()
		defer os.RemoveAll(scratch)
		file := filepath.Join(scratch, "pinup-test.png")
		var link string
		err := os.WriteFile(file, imageproc.TestImage(), 0o644)
		if err == nil {
			var entry history.Entry
			entry, err = perform(u.client, NewSource(file), paths.NewID(), host,
				imageproc.Options{Conversion: imageproc.Original, Quality: 1}, false, func(int64, int64) {})
			link = entry.URL
			var f *Failure
			if errors.As(err, &f) {
				err = f.Err
			}
		}
		u.Post(func() { done(link, err) })
	}()
}

// reporter reports bytes sent for one upload on the main thread.
func (u *Uploader) reporter(id string) func(sent, total int64) {
	return func(sent, total int64) {
		u.Post(func() {
			t := u.tracked[id]
			if t == nil || t.finished || total <= 0 {
				return
			}
			t.fraction = min(1, float64(sent)/float64(total))
			u.report(false)
		})
	}
}

// report tells OnProgress at most 30 times a second, which is all the
// icon can show.
func (u *Uploader) report(force bool) {
	now := time.Now()
	if !force && now.Sub(u.lastReport) < time.Second/30 {
		return
	}
	u.lastReport = now
	if len(u.tracked) == 0 {
		u.progress = 0
	} else {
		var files [][2]float64
		for _, t := range u.tracked {
			files = append(files, [2]float64{float64(t.weight), t.fraction})
		}
		u.progress = CombinedProgress(files)
	}
	if u.OnProgress != nil {
		u.OnProgress(u.progress)
	}
}

// CombinedProgress is each file's fraction, weighed by its size.
func CombinedProgress(files [][2]float64) float64 {
	var total, done float64
	for _, f := range files {
		total += f[0]
		done += f[0] * f[1]
	}
	if total <= 0 {
		return 0
	}
	return min(1, max(0, done/total))
}

// perform prepares and sends one file off the main thread. Its error is a
// *Failure.
func perform(client *http.Client, source Source, id string, host hosts.Host, opts imageproc.Options,
	keepThumbnail bool, progress func(int64, int64)) (history.Entry, error) {
	scratch := paths.Scratch()
	defer os.RemoveAll(scratch)
	fail := func(err error) (history.Entry, error) {
		if source.Temporary {
			source = keep(source)
		}
		return history.Entry{}, &Failure{Source: source, Err: err}
	}
	file, err := imageproc.Prepare(source.Path, source.Name, opts, scratch)
	if err != nil {
		var pe *imageproc.ProcessingError
		if errors.As(err, &pe) {
			err = &hosts.Error{Kind: hosts.Processing, Message: pe.Message}
		}
		return fail(err)
	}
	req, err := host.Request(file, scratch)
	if err != nil {
		return fail(err)
	}
	reply, err := send(client, req, progress)
	if err != nil {
		return fail(err)
	}
	link, err := host.Link(reply, file, req)
	if err != nil {
		return fail(err)
	}
	entry := history.Entry{
		ID: id, URL: link, Name: file.Name, Host: host.Name(), Size: file.Size, Width: file.Width,
		Height: file.Height, Date: history.Time{Time: time.Now().Truncate(time.Second)},
	}
	if keepThumbnail && file.Thumbnail != nil {
		name := id + ".jpg"
		if bytes.HasPrefix(file.Thumbnail, []byte{0x89, 'P', 'N', 'G'}) {
			name = id + ".png"
		}
		if os.WriteFile(filepath.Join(paths.Thumbnails(), name), file.Thumbnail, 0o644) == nil {
			entry.Thumbnail = name
		}
	}
	return entry, nil
}

// send sends the request, trying once more after a dropped connection, a
// timeout or a server error. S3 signatures stay valid for minutes, so the
// same request can be sent again.
func send(client *http.Client, r *hosts.Request, progress func(int64, int64)) ([]byte, error) {
	for attempt := 1; ; attempt++ {
		reply, status, err := sendOnce(client, r, progress)
		if err != nil {
			if attempt == 1 {
				log.Printf("%v, retrying", err)
				time.Sleep(time.Second)
				continue
			}
			return nil, &hosts.Error{Kind: hosts.BadResponse, Message: networkMessage(err)}
		}
		if status >= 500 && attempt == 1 {
			log.Printf("HTTP %d, retrying", status)
			time.Sleep(time.Second)
			continue
		}
		if status < 200 || status >= 300 {
			return nil, &hosts.Error{Kind: hosts.HTTP, Status: status, Message: hosts.ErrorText(reply)}
		}
		return reply, nil
	}
}

func sendOnce(client *http.Client, r *hosts.Request, progress func(int64, int64)) ([]byte, int, error) {
	f, err := os.Open(r.Body)
	if err != nil {
		return nil, 0, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, 0, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	watchdog := time.AfterFunc(idleTimeout, cancel)
	defer watchdog.Stop()
	body := &progressReader{r: f, total: info.Size(), report: progress, watchdog: watchdog}
	req, err := http.NewRequestWithContext(ctx, r.Method, r.URL, body)
	if err != nil {
		return nil, 0, err
	}
	req.ContentLength = info.Size()
	req.GetBody = nil
	for k, v := range r.Header {
		req.Header[k] = v
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	watchdog.Reset(idleTimeout)
	reply, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, 0, err
	}
	return reply, resp.StatusCode, nil
}

// progressReader reports bytes read, at most 30 times a second and always
// at the end, and keeps the idle watchdog from firing while bytes flow.
type progressReader struct {
	r        io.Reader
	sent     int64
	total    int64
	last     time.Time
	report   func(int64, int64)
	watchdog *time.Timer
}

func (p *progressReader) Read(b []byte) (int, error) {
	n, err := p.r.Read(b)
	p.sent += int64(n)
	if n > 0 {
		p.watchdog.Reset(idleTimeout)
	}
	if now := time.Now(); p.sent >= p.total || now.Sub(p.last) > time.Second/30 {
		p.last = now
		p.report(p.sent, p.total)
	}
	return n, err
}

func networkMessage(err error) string {
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return "The upload timed out."
	}
	msg := err.Error()
	// net/http prefixes `Put "https://…": `; the address is long and known.
	if i := strings.Index(msg, `": `); i >= 0 {
		msg = msg[i+3:]
	}
	if msg != "" {
		msg = strings.ToUpper(msg[:1]) + msg[1:]
	}
	if !strings.HasSuffix(msg, ".") {
		msg += "."
	}
	return msg
}

// removeTemporary deletes a temporary file and the folder Pinup made for
// it.
func removeTemporary(path string) {
	folder := filepath.Dir(path)
	if strings.HasPrefix(filepath.Base(folder), paths.ScratchPrefix) || filepath.Dir(folder) == paths.Failed() {
		os.RemoveAll(folder)
	} else {
		os.Remove(path)
	}
}

// keep moves a failed screenshot or pasted image out of the temporary
// folder, so a retry still has it.
func keep(s Source) Source {
	if filepath.Dir(filepath.Dir(s.Path)) == paths.Failed() {
		return s
	}
	folder := filepath.Join(paths.Failed(), paths.NewID())
	dst := filepath.Join(folder, filepath.Base(s.Path))
	if os.MkdirAll(folder, 0o755) != nil {
		return s
	}
	if err := os.Rename(s.Path, dst); err != nil {
		if copyFile(s.Path, dst) != nil {
			return s
		}
	}
	removeTemporary(s.Path)
	return Source{Path: dst, Name: s.Name, Temporary: true}
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
