package settings

import (
	"encoding/json"
	"os"
	"testing"

	"pinup/internal/hosts"
	"pinup/internal/paths"
)

type mapDefaults map[string]any

func (m mapDefaults) String(k string) (string, bool) { s, ok := m[k].(string); return s, ok }
func (m mapDefaults) Data(k string) ([]byte, bool)   { b, ok := m[k].([]byte); return b, ok }
func (m mapDefaults) Float(k string) (float64, bool) { f, ok := m[k].(float64); return f, ok }
func (m mapDefaults) Bool(k string) (bool, bool)     { b, ok := m[k].(bool); return b, ok }

func withDefaults(t *testing.T, m mapDefaults) {
	t.Helper()
	paths.SetRoot(t.TempDir())
	old := readDefaults
	readDefaults = func() defaults { return m }
	t.Cleanup(func() { readDefaults = old })
}

func TestLinkFormat(t *testing.T) {
	if got := Markdown.Format("https://x/a.png", "My [shot].png"); got != "![My shot](https://x/a.png)" {
		t.Error(got)
	}
	if got := HTML.Format("https://x/a.png", "a.png"); got != `<img src="https://x/a.png" alt="a">` {
		t.Error(got)
	}
}

func TestShortcuts(t *testing.T) {
	cases := map[string]string{
		"32:1179648:U": "Shift+Cmd+U", "1:1703936:S": "Alt+Shift+Cmd+S", "49:262144:Space": "Ctrl+Space",
		"122:1048576:F1": "Cmd+F1", "36:1572864:↩": "Alt+Cmd+Enter", "": "", "junk": "",
	}
	for in, want := range cases {
		if got := LegacyShortcut(in); got != want {
			t.Errorf("LegacyShortcut(%q) = %q, want %q", in, got, want)
		}
	}
	if got := ShortcutDisplay("Alt+Shift+Cmd+U"); got != "⌥⇧⌘U" {
		t.Error(got)
	}
	if got := ShortcutDisplay("Ctrl+Enter"); got != "⌃↩" {
		t.Error(got)
	}
}

func TestMigrateHosts(t *testing.T) {
	host := NewHost("pics", S3)
	host.S3.Bucket = "pics"
	list, _ := json.Marshal([]HostConfig{host})
	withDefaults(t, mapDefaults{
		"linkFormat": "url", "clipboardHotKey": "32:1703936:U", "screenshotHotKey": "", "hosts": list,
		"selectedHost": host.ID, "welcomed": true, "quality": 0.6,
	})
	s := Load()
	if s.LinkFormat != URL || s.ClipboardShortcut != "Alt+Shift+Cmd+U" || s.ScreenshotShortcut != "" ||
		!s.Welcomed || s.Quality != 0.6 || !s.StripLocation || s.Conversion != "original" {
		t.Errorf("migrated prefs: %+v", s.Prefs)
	}
	if h, ok := s.SelectedHostConfig(); !ok || h.ID != host.ID || h.S3.Bucket != "pics" || h.S3.KeyTemplate == "" {
		t.Errorf("migrated host: %+v", h)
	}
	if _, err := os.Stat(paths.Settings()); err != nil {
		t.Error("settings.json written")
	}
	// Read again from the file, not the defaults.
	readDefaults = func() defaults { return mapDefaults{} }
	if Load().LinkFormat != URL {
		t.Error("reload")
	}
}

func TestMigrateSingleConfigs(t *testing.T) {
	s3 := hosts.DefaultS3()
	s3.Endpoint = "https://acc.r2.cloudflarestorage.com"
	custom := hosts.DefaultCustom()
	custom.URL = "https://up.example.com/{name}"
	moved := migrateSingle(&s3, "k", &custom, "")
	if len(moved) != 2 || moved[0].Name != "acc.r2.cloudflarestorage.com" || moved[1].Name != "up.example.com" ||
		moved[0].Provider != S3 || moved[1].Provider != Custom {
		t.Errorf("migrated names: %+v", moved)
	}
	s3.Bucket = "pics"
	if m := migrateSingle(&s3, "", nil, ""); len(m) != 1 || m[0].Name != "pics" {
		t.Error("migrated S3 named by bucket")
	}
	d3, dc := hosts.DefaultS3(), hosts.DefaultCustom()
	if len(migrateSingle(&d3, "", &dc, "")) != 0 {
		t.Error("untouched configs not migrated")
	}
	if len(migrateSingle(nil, "", &dc, "X: y")) != 1 {
		t.Error("custom with only headers migrated")
	}

	s3Data, _ := json.Marshal(s3)
	withDefaults(t, mapDefaults{"s3": s3Data, "host": "s3"})
	saveSecrets(map[string]string{"s3.secretAccessKey": "SECRET"})
	s := Load()
	h, ok := s.SelectedHostConfig()
	if !ok || s.Secret(h.SecretKey()) != "SECRET" || s.Secret("s3.secretAccessKey") != "" {
		t.Errorf("secret moved to the host: %+v", h)
	}
}

func TestHosts(t *testing.T) {
	withDefaults(t, mapDefaults{})
	s := Load()
	a := s.AddHost(S3)
	b := s.AddHost(S3)
	if a.Name != "S3-Compatible" || b.Name != "S3-Compatible 2" || s.SelectedHost != b.ID {
		t.Errorf("names %q %q", a.Name, b.Name)
	}
	if a.SecretKey() == b.SecretKey() {
		t.Error("secret keys per host")
	}
	s.SetSecret(b.SecretKey(), "x")
	s.RemoveHost(b.ID)
	if s.SelectedHost != a.ID || s.Secret(b.SecretKey()) != "" {
		t.Error("remove host")
	}
	if info, _ := os.Stat(paths.Secrets()); info.Mode().Perm() != 0o600 {
		t.Errorf("secrets mode %v", info.Mode())
	}
}

// TestRealDefaults reads this Mac's Pinup defaults, when there are any,
// without writing them.
func TestRealDefaults(t *testing.T) {
	d := cfDefaults(BundleID())
	if _, ok := d.String("linkFormat"); !ok {
		t.Skip("no Pinup defaults on this Mac")
	}
	paths.SetRoot(t.TempDir())
	p, ok := migrateDefaults(map[string]string{})
	if !ok {
		t.Fatal("defaults found but not migrated")
	}
	t.Logf("link %s, clipboard %q, screenshot %q, %d host(s)", p.LinkFormat, p.ClipboardShortcut, p.ScreenshotShortcut, len(p.Hosts))
	if raw, ok := d.Data("hosts"); ok && len(raw) > 2 && len(p.Hosts) == 0 {
		t.Errorf("hosts not read: %s", raw)
	}
}
