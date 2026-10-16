package settings

import (
	"encoding/json"
	"os"
	"strconv"
	"strings"

	"pinup/internal/hosts"
	"pinup/internal/imageproc"
	"pinup/internal/macos"
)

// BundleID is the identifier the Swift version kept its user defaults
// under, which the app keeps.
func BundleID() string {
	if id := os.Getenv("PINUP_BUNDLE_ID"); id != "" {
		return id
	}
	return "dev.sorrycc.pinup.app"
}

// defaults reads the Swift version's user defaults.
type defaults interface {
	String(key string) (string, bool)
	Data(key string) ([]byte, bool)
	Float(key string) (float64, bool)
	Bool(key string) (bool, bool)
}

// readDefaults is the user defaults of BundleID; tests replace it.
var readDefaults = func() defaults {
	macos.SyncPrefs(BundleID())
	return cfDefaults(BundleID())
}

type cfDefaults string

func (d cfDefaults) value(key string, read func(macos.Ref)) {
	if r := macos.Pref(string(d), key); r != 0 {
		read(r)
		macos.Release(r)
	}
}

func (d cfDefaults) String(key string) (s string, ok bool) {
	d.value(key, func(r macos.Ref) {
		s, ok = macos.GoString(r), macos.IsString(r)
	})
	return
}

func (d cfDefaults) Data(key string) (b []byte, ok bool) {
	d.value(key, func(r macos.Ref) { b = macos.Bytes(r); ok = b != nil })
	return
}

func (d cfDefaults) Float(key string) (f float64, ok bool) {
	d.value(key, func(r macos.Ref) { f, ok = macos.FloatValue(r) })
	return
}

func (d cfDefaults) Bool(key string) (v bool, ok bool) {
	d.value(key, func(r macos.Ref) { v, ok = macos.BoolValue(r) })
	return
}

var knownKeys = []string{
	"linkFormat", "conversion", "quality", "stripLocation", "playSound", "clipboardHotKey", "screenshotHotKey",
	"hosts", "selectedHost", "welcomed", "s3", "custom", "host",
}

// migrateDefaults turns the Swift version's user defaults into
// preferences, once. False when it left none.
func migrateDefaults(secrets map[string]string) (Prefs, bool) {
	d := readDefaults()
	found := false
	for _, key := range knownKeys {
		if _, ok := d.String(key); ok {
			found = true
		} else if _, ok := d.Data(key); ok {
			found = true
		} else if _, ok := d.Float(key); ok {
			found = true
		}
	}
	if !found {
		return Prefs{}, false
	}
	p := Defaults()
	if s, ok := d.String("linkFormat"); ok {
		for _, f := range LinkFormats {
			if string(f) == s {
				p.LinkFormat = f
			}
		}
	}
	if s, ok := d.String("conversion"); ok && (s == "original" || s == "jpeg" || s == "heic") {
		p.Conversion = imageproc.Conversion(s)
	}
	if f, ok := d.Float("quality"); ok {
		p.Quality = min(1, max(0.1, f))
	}
	if b, ok := d.Bool("stripLocation"); ok {
		p.StripLocation = b
	}
	if b, ok := d.Bool("playSound"); ok {
		p.PlaySound = b
	}
	if b, ok := d.Bool("welcomed"); ok {
		p.Welcomed = b
	}
	if s, ok := d.String("clipboardHotKey"); ok {
		p.ClipboardShortcut = LegacyShortcut(s)
	}
	if s, ok := d.String("screenshotHotKey"); ok {
		p.ScreenshotShortcut = LegacyShortcut(s)
	}
	if data, ok := d.Data("hosts"); ok {
		var list []HostConfig
		if json.Unmarshal(data, &list) == nil {
			p.Hosts = list
		}
		p.SelectedHost, _ = d.String("selectedHost")
	} else {
		// The single S3 and custom configs of earlier versions. Their
		// secrets move to the new hosts' keys.
		var s3 *hosts.S3Config
		var custom *hosts.CustomConfig
		if data, ok := d.Data("s3"); ok {
			json.Unmarshal(data, &s3)
		}
		if data, ok := d.Data("custom"); ok {
			json.Unmarshal(data, &custom)
		}
		p.Hosts = migrateSingle(s3, secrets["s3.secretAccessKey"], custom, secrets["custom.headers"])
		for _, h := range p.Hosts {
			old := "custom.headers"
			if h.Provider == S3 {
				old = "s3.secretAccessKey"
			}
			if v := secrets[old]; v != "" {
				secrets[h.SecretKey()] = v
			}
		}
		delete(secrets, "s3.secretAccessKey")
		delete(secrets, "custom.headers")
		saveSecrets(secrets)
		old, _ := d.String("host")
		for _, h := range p.Hosts {
			if string(h.Provider) == old {
				p.SelectedHost = h.ID
			}
		}
		if p.SelectedHost == "" && len(p.Hosts) > 0 {
			p.SelectedHost = p.Hosts[0].ID
		}
	}
	if p.Hosts == nil {
		p.Hosts = []HostConfig{}
	}
	return p, true
}

// migrateSingle makes hosts of the single S3 and custom configs of
// earlier versions. Configs left at their defaults with no secret are
// dropped. Each is named after its bucket or address.
func migrateSingle(s3 *hosts.S3Config, s3Secret string, custom *hosts.CustomConfig, headers string) []HostConfig {
	var list []HostConfig
	if s3 != nil && (*s3 != hosts.DefaultS3() || s3Secret != "") {
		name := s3.Bucket
		if name == "" {
			name = hostName(s3.Endpoint, S3.DisplayName())
		}
		h := NewHost(name, S3)
		c := *s3
		h.S3 = &c
		list = append(list, h)
	}
	if custom != nil && (*custom != hosts.DefaultCustom() || headers != "") {
		h := NewHost(hostName(strings.ReplaceAll(custom.URL, "{name}", "x"), Custom.DisplayName()), Custom)
		c := *custom
		h.Custom = &c
		list = append(list, h)
	}
	return list
}

var legacyKeys = map[string]string{
	"Space": "Space", "↩": "Enter", "⇥": "Tab", "⌫": "Backspace", "⌦": "Delete", "⎋": "Escape",
	"←": "Left", "→": "Right", "↑": "Up", "↓": "Down", "+": "Plus",
}

// LegacyShortcut turns a shortcut as the Swift version stored it,
// "keyCode:modifiers:key" such as 32:1179648:U, into an accelerator. ""
// stays "", a shortcut the user cleared.
func LegacyShortcut(text string) string {
	parts := strings.SplitN(text, ":", 3)
	if len(parts) != 3 || parts[2] == "" {
		return ""
	}
	flags, err := strconv.ParseUint(parts[1], 10, 64)
	if err != nil {
		return ""
	}
	key := parts[2]
	if named, ok := legacyKeys[key]; ok {
		key = named
	} else if len([]rune(key)) == 1 {
		key = strings.ToUpper(key)
	} else if !(key[0] == 'F' && len(key) <= 3) {
		return ""
	}
	var mods []string
	for _, m := range []struct {
		bit  uint64
		name string
	}{{1 << 18, "Ctrl"}, {1 << 19, "Alt"}, {1 << 17, "Shift"}, {1 << 20, "Cmd"}} {
		if flags&m.bit != 0 {
			mods = append(mods, m.name)
		}
	}
	return strings.Join(append(mods, key), "+")
}

// ShortcutDisplay writes an accelerator as menus show it: ⌥⇧⌘U.
func ShortcutDisplay(acc string) string {
	if acc == "" {
		return ""
	}
	parts := strings.Split(acc, "+")
	key := parts[len(parts)-1]
	if key == "" && len(parts) > 1 { // "Cmd++"
		key = "+"
	}
	has := map[string]bool{}
	for _, p := range parts[:len(parts)-1] {
		switch strings.ToLower(p) {
		case "ctrl", "control":
			has["⌃"] = true
		case "alt", "option":
			has["⌥"] = true
		case "shift":
			has["⇧"] = true
		case "cmd", "command", "cmdorctrl", "commandorcontrol", "super", "meta":
			has["⌘"] = true
		}
	}
	var b strings.Builder
	for _, sym := range []string{"⌃", "⌥", "⇧", "⌘"} {
		if has[sym] {
			b.WriteString(sym)
		}
	}
	names := map[string]string{
		"Enter": "↩", "Return": "↩", "Tab": "⇥", "Backspace": "⌫", "Delete": "⌦", "Escape": "⎋", "Esc": "⎋",
		"Left": "←", "Right": "→", "Up": "↑", "Down": "↓", "Plus": "+", "Space": "Space",
	}
	if n, ok := names[key]; ok {
		key = n
	}
	b.WriteString(key)
	return b.String()
}
