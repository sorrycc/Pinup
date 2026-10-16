package main

import (
	"os"
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"pinup/internal/history"
	"pinup/internal/paths"
	"pinup/internal/settings"
	"pinup/internal/upload"
)

// testApp is an app with its own folder, whose clipboard and browser are
// slices, and whose posts run when drain says.
type testRig struct {
	a       *app
	clip    []string
	opened  []string
	history *historyWindow
}

func newRig(t *testing.T) *testRig {
	t.Helper()
	paths.SetRoot(t.TempDir())
	// Settings of their own, never those of this Mac's Pinup.
	os.WriteFile(paths.Settings(), []byte("{}"), 0o644)
	r := &testRig{}
	a := &app{posts: make(chan func(), 1024)}
	a.s = settings.Load()
	a.hist = &history.Store{}
	a.up = upload.New(a.post)
	a.hud = &hud{a: a}
	a.writeClipboard = func(s string) { r.clip = append(r.clip, s) }
	a.open = func(u string) { r.opened = append(r.opened, u) }
	r.a = a
	return r
}

func (r *testRig) drain() {
	for {
		select {
		case fn := <-r.a.posts:
			fn()
		default:
			return
		}
	}
}

func entry(name string, age time.Duration) history.Entry {
	return history.Entry{
		ID: paths.NewID(), URL: "https://img.example.com/" + name, Name: name, Host: "Test",
		Size: 48_000, Width: 800, Height: 600, Date: history.Time{Time: time.Now().Add(-age).Truncate(time.Second)},
	}
}

func (r *testRig) historyTester(entries ...history.Entry) *ui.Tester {
	r.a.hist.Add(entries)
	h := &historyWindow{a: r.a, selected: map[string]bool{}, flashes: map[string]flash{},
		thumbs: map[string]*ui.Bitmap{}, loading: map[string]bool{}}
	r.history = h
	return ui.NewTester(h.view, 820, 600)
}

func TestHistoryCopyAndOpen(t *testing.T) {
	r := newRig(t)
	tt := r.historyTester(entry("old.png", 50*time.Hour), entry("a.png", time.Minute), entry("b.png", 0))
	if !tt.HasText("Today") || !tt.HasText("b.png") {
		t.Fatalf("texts %q", tt.Texts())
	}
	if err := tt.Click("a.png"); err != nil {
		t.Fatal(err)
	}
	if len(r.clip) != 1 || r.clip[0] != "![a](https://img.example.com/a.png)" {
		t.Errorf("click copies in the current format: %q", r.clip)
	}
	if !tt.HasText("Copied Markdown") {
		t.Errorf("flash: %q", tt.Texts())
	}
	tt.ClickWith(ui.Cmd, "b.png")
	tt.Command("copy")
	if got := r.clip[len(r.clip)-1]; !strings.Contains(got, "a.png") || !strings.Contains(got, "b.png") || strings.Count(got, "\n") != 1 {
		t.Errorf("⌘C copies the selection, one per line: %q", got)
	}
	tt.Key(0, ui.KeyEnter)
	if len(r.opened) != 2 {
		t.Errorf("Return opens the selection: %q", r.opened)
	}
}

func TestHistoryRemoveAndUndo(t *testing.T) {
	r := newRig(t)
	tt := r.historyTester(entry("a.png", time.Minute), entry("b.png", 0))
	tt.Click("a.png")
	tt.Command("delete")
	if tt.HasText("a.png") || len(r.a.hist.Entries()) != 1 {
		t.Fatalf("removed: %q", tt.Texts())
	}
	tt.Command("undo")
	if !tt.HasText("a.png") || len(r.a.hist.Entries()) != 2 {
		t.Errorf("undo: %q", tt.Texts())
	}
	tt.Command("redo")
	if tt.HasText("a.png") {
		t.Errorf("redo: %q", tt.Texts())
	}
}

func TestHistorySearch(t *testing.T) {
	r := newRig(t)
	tt := r.historyTester(entry("Café.png", 0), entry("dog.png", 0))
	tt.Click("Search uploads")
	tt.Type("cafe")
	if !tt.HasText("Café.png") || tt.HasText("dog.png") {
		t.Errorf("search ignores case and accents: %q", tt.Texts())
	}
	tt.Type("zzz")
	if !tt.HasText("No Results") {
		t.Errorf("no results: %q", tt.Texts())
	}
}

func TestHistoryEmptyAndContextMenu(t *testing.T) {
	r := newRig(t)
	tt := r.historyTester()
	if !tt.HasText("No Uploads Yet") {
		t.Fatalf("empty: %q", tt.Texts())
	}
	r.a.hist.Add([]history.Entry{entry("a.png", 0)})
	tt.Frame()
	tt.RightClick("a.png")
	if err := tt.ChooseMenuItem("Copy as HTML"); err != nil {
		t.Fatalf("menu %q: %v", tt.Menu(), err)
	}
	if len(r.clip) == 0 || r.clip[0] != `<img src="https://img.example.com/a.png" alt="a">` {
		t.Errorf("copy as HTML: %q", r.clip)
	}
}

func settingsTester(r *testRig, pane int) (*settingsWindow, *ui.Tester) {
	s := &settingsWindow{a: r.a, pane: pane}
	return s, ui.NewTester(s.view, 600, 900)
}

func TestSettingsHosts(t *testing.T) {
	r := newRig(t)
	_, tt := settingsTester(r, paneHosts)
	if !tt.HasText("No hosts yet. Choose Add S3-Compatible or Add Custom HTTP above.") {
		t.Fatalf("texts %q", tt.Texts())
	}
	tt.Click("Add Host")
	if err := tt.ChooseMenuItem("Add S3-Compatible…"); err != nil {
		t.Fatalf("menu %q: %v", tt.Menu(), err)
	}
	if len(r.a.s.Hosts) != 1 || r.a.s.Hosts[0].Provider != settings.S3 {
		t.Fatalf("hosts %+v", r.a.s.Hosts)
	}
	clickField(t, tt, "Bucket")
	tt.Type("pics")
	h, _ := r.a.s.SelectedHostConfig()
	if h.S3.Bucket != "pics" {
		t.Errorf("saved as typed: bucket %q", h.S3.Bucket)
	}
	tt.Click("Add Host")
	tt.ChooseMenuItem("Add Custom HTTP…")
	clickField(t, tt, "Headers")
	tt.Type("Authorization: Bearer s3cret")
	h, _ = r.a.s.SelectedHostConfig()
	if h.Provider != settings.Custom || r.a.s.Secret(h.SecretKey()) != "Authorization: Bearer s3cret" {
		t.Errorf("headers kept as a secret: %+v %q", h, r.a.s.Secret(h.SecretKey()))
	}
	data, _ := os.ReadFile(paths.Settings())
	if !strings.Contains(string(data), `"bucket": "pics"`) || strings.Contains(string(data), "s3cret") {
		t.Errorf("settings.json: %s", data)
	}
}

func TestSettingsGeneral(t *testing.T) {
	r := newRig(t)
	_, tt := settingsTester(r, paneGeneral)
	for _, text := range []string{"Copy links as", "Convert images to", "Remove location from photos", "No uploads yet."} {
		if !tt.HasText(text) {
			t.Errorf("missing %q in %q", text, tt.Texts())
		}
	}
}

func TestShortcutRecorder(t *testing.T) {
	r := newRig(t)
	_, tt := settingsTester(r, paneShortcuts)
	tt.Click(settings.ShortcutDisplay(r.a.s.ClipboardShortcut))
	if !tt.HasText("Type shortcut…") {
		t.Fatalf("recording: %q", tt.Texts())
	}
	tt.Key(ui.Alt|ui.Super, ui.KeyK)
	if r.a.s.ClipboardShortcut != "Alt+Cmd+K" || r.a.recording != 0 {
		t.Errorf("recorded %q, recording %d", r.a.s.ClipboardShortcut, r.a.recording)
	}
	// The other action's combination is refused.
	tt.Click(settings.ShortcutDisplay(r.a.s.ScreenshotShortcut))
	tt.Key(ui.Alt|ui.Super, ui.KeyK)
	if r.a.s.ScreenshotShortcut == "Alt+Cmd+K" || !tt.HasText("⌥⌘K is already used for uploading the clipboard.") {
		t.Errorf("duplicate accepted: %q", tt.Texts())
	}
}

func TestTrayMenu(t *testing.T) {
	r := newRig(t)
	r.a.hist.Add([]history.Entry{entry("shot.png", 0)})
	var labels []string
	for _, it := range r.a.trayMenu() {
		labels = append(labels, it.Label)
	}
	got := strings.Join(labels, "|")
	for _, want := range []string{"Upload Files…", "Recent", "shot.png", "Show History", "Upload To", "Copy As", "Quit Pinup"} {
		if !strings.Contains(got, want) {
			t.Errorf("menu lacks %q: %s", want, got)
		}
	}
}

func TestHelpers(t *testing.T) {
	if got := menuTitle("Screenshot 2026-10-04 at 09.12.44 (annotated copy).png", 34); len([]rune(got)) != 34 ||
		!strings.HasPrefix(got, "Screenshot") || !strings.HasSuffix(got, ".png") || !strings.Contains(got, "…") {
		t.Errorf("menu title %q", got)
	}
	now := time.Date(2026, 10, 15, 12, 0, 0, 0, time.Local)
	cases := map[time.Duration]string{5 * time.Second: "Just now", 5 * time.Minute: "5 minutes ago", 3 * time.Hour: "3 hours ago", 30 * time.Hour: "Yesterday"}
	for age, want := range cases {
		if got := relativeTime(now.Add(-age), now); got != want {
			t.Errorf("relativeTime(%v) = %q", age, got)
		}
	}
	if byteCount(48_000) != "48 KB" || byteCount(1_100_000) != "1.1 MB" || byteCount(12) != "12 bytes" {
		t.Error("byte counts")
	}
	if dayTitle(startOfDay(now), now) != "Today" || dayTitle(startOfDay(now).AddDate(0, 0, -1), now) != "Yesterday" {
		t.Error("day titles")
	}
	if got := accelerator(ui.InputEvent{Key: ui.KeyU, Mods: ui.Alt | ui.Shift | ui.Super}); got != "Alt+Shift+Cmd+U" {
		t.Errorf("accelerator %q", got)
	}
	if accelerator(ui.InputEvent{Key: ui.KeyU, Mods: ui.Shift}) != "" {
		t.Error("a shortcut needs Cmd, Ctrl or Option")
	}
}

// clickField clicks the control on the trailing edge of the row titled
// title, whose field has the same label.
func clickField(t *testing.T, tt *ui.Tester, title string) {
	t.Helper()
	r, ok := tt.Find(title)
	if !ok {
		t.Fatalf("no row %q in %q", title, tt.Texts())
	}
	// The tester's window is 600 wide; fields are 270 wide, inset 38.
	tt.ClickAt(600-24-14-100, r.Y+r.H/2)
}
