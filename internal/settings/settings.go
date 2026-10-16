// Package settings keeps Pinup's preferences in settings.json and the
// hosts' tokens and keys in secrets.json, readable by the user only. Not
// the keychain: an ad-hoc signed app loses keychain access each time it is
// rebuilt, and macOS then asks for the login password.
package settings

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"strings"

	"pinup/internal/hosts"
	"pinup/internal/imageproc"
	"pinup/internal/paths"
)

// LinkFormat is how a link is written to the clipboard after an upload.
type LinkFormat string

const (
	URL      LinkFormat = "url"
	Markdown LinkFormat = "markdown"
	HTML     LinkFormat = "html"
)

// LinkFormats lists them in the order menus show them.
var LinkFormats = []LinkFormat{URL, Markdown, HTML}

// DisplayName is the format's name in menus.
func (f LinkFormat) DisplayName() string {
	switch f {
	case Markdown:
		return "Markdown"
	case HTML:
		return "HTML"
	}
	return "URL"
}

// Format writes url as the format, with name as the alternative text.
func (f LinkFormat) Format(url, name string) string {
	switch f {
	case Markdown:
		return "![" + alt(name) + "](" + url + ")"
	case HTML:
		return `<img src="` + url + `" alt="` + alt(name) + `">`
	}
	return url
}

// alt is the file name without its extension, with the characters that
// would break the markup removed.
func alt(name string) string {
	if i := strings.LastIndexByte(name, '.'); i > 0 {
		name = name[:i]
	}
	return strings.Map(func(r rune) rune {
		if strings.ContainsRune(`[]<>"`, r) {
			return -1
		}
		return r
	}, name)
}

// Provider is a kind of host: how files are sent.
type Provider string

const (
	S3     Provider = "s3"
	Custom Provider = "custom"
)

// DisplayName is the provider's name in Settings.
func (p Provider) DisplayName() string {
	if p == Custom {
		return "Custom HTTP"
	}
	return "S3-Compatible"
}

// HostConfig is a host the user added: a name, its provider and that
// provider's settings. Its secret, the S3 secret key or the custom
// headers, is in the secrets under SecretKey.
type HostConfig struct {
	ID       string              `json:"id"`
	Name     string              `json:"name"`
	Provider Provider            `json:"provider"`
	S3       *hosts.S3Config     `json:"s3,omitempty"`
	Custom   *hosts.CustomConfig `json:"custom,omitempty"`
}

// NewHost makes a host of a provider with its default settings.
func NewHost(name string, p Provider) HostConfig {
	h := HostConfig{ID: paths.NewID(), Name: name, Provider: p}
	if p == S3 {
		c := hosts.DefaultS3()
		h.S3 = &c
	} else {
		c := hosts.DefaultCustom()
		h.Custom = &c
	}
	return h
}

// SecretKey is where the host's secret is kept.
func (h HostConfig) SecretKey() string {
	if h.Provider == S3 {
		return h.ID + ".secretAccessKey"
	}
	return h.ID + ".headers"
}

// Clone copies the host, its configs too.
func (h HostConfig) Clone() HostConfig {
	if h.S3 != nil {
		c := *h.S3
		h.S3 = &c
	}
	if h.Custom != nil {
		c := *h.Custom
		h.Custom = &c
	}
	return h
}

// Prefs are every preference.
type Prefs struct {
	LinkFormat    LinkFormat           `json:"linkFormat"`
	Conversion    imageproc.Conversion `json:"conversion"`
	Quality       float64              `json:"quality"`
	StripLocation bool                 `json:"stripLocation"`
	PlaySound     bool                 `json:"playSound"`
	// The shortcuts are accelerators, such as Alt+Shift+Cmd+U; "" is one
	// the user cleared.
	ClipboardShortcut  string       `json:"clipboardShortcut"`
	ScreenshotShortcut string       `json:"screenshotShortcut"`
	Hosts              []HostConfig `json:"hosts"`
	SelectedHost       string       `json:"selectedHost"`
	Welcomed           bool         `json:"welcomed"`
}

// Defaults are the preferences of a new user.
func Defaults() Prefs {
	return Prefs{
		LinkFormat: Markdown, Conversion: imageproc.Original, Quality: 0.85, StripLocation: true, PlaySound: true,
		ClipboardShortcut: "Alt+Shift+Cmd+U", ScreenshotShortcut: "Alt+Shift+Cmd+S", Hosts: []HostConfig{},
	}
}

// Settings are the preferences and secrets, read once and written on
// every change. Its methods are called on the main thread.
type Settings struct {
	Prefs
	secrets map[string]string
	// OnChange is called after every change.
	OnChange func()
}

// Load reads the settings, moving them over from the Swift version's
// user defaults the first time.
func Load() *Settings {
	s := &Settings{Prefs: Defaults()}
	data, err := os.ReadFile(paths.Settings())
	switch {
	case err == nil:
		_ = json.Unmarshal(data, &s.Prefs)
		s.secrets = loadSecrets()
	case errors.Is(err, fs.ErrNotExist):
		s.secrets = loadSecrets()
		if migrated, ok := migrateDefaults(s.secrets); ok {
			s.Prefs = migrated
		}
		s.write()
	default:
		s.secrets = loadSecrets()
	}
	if s.Hosts == nil {
		s.Hosts = []HostConfig{}
	}
	return s
}

// Changed saves the settings after a change made to Prefs.
func (s *Settings) Changed() {
	s.Quality = min(1, max(0.1, s.Quality))
	s.write()
	if s.OnChange != nil {
		s.OnChange()
	}
}

func (s *Settings) write() {
	data, err := json.MarshalIndent(s.Prefs, "", "  ")
	if err != nil {
		return
	}
	_ = paths.WriteAtomic(paths.Settings(), data, 0o644)
}

// SelectedHostConfig is where uploads go: the chosen host, or the first if
// that one is gone.
func (s *Settings) SelectedHostConfig() (HostConfig, bool) {
	for _, h := range s.Hosts {
		if h.ID == s.SelectedHost {
			return h, true
		}
	}
	if len(s.Hosts) > 0 {
		return s.Hosts[0], true
	}
	return HostConfig{}, false
}

// Host makes the uploader of the selected host, with its secret.
func (s *Settings) Host() hosts.Host {
	h, ok := s.SelectedHostConfig()
	if !ok {
		return hosts.NoHost{}
	}
	return s.HostFor(h)
}

// HostFor makes the uploader of a host, with its secret.
func (s *Settings) HostFor(h HostConfig) hosts.Host {
	secret := s.Secret(h.SecretKey())
	if h.Provider == S3 {
		c := hosts.DefaultS3()
		if h.S3 != nil {
			c = *h.S3
		}
		return hosts.S3{HostName: h.Name, Config: c, Secret: secret}
	}
	c := hosts.DefaultCustom()
	if h.Custom != nil {
		c = *h.Custom
	}
	return hosts.Custom{HostName: h.Name, Config: c, Headers: secret}
}

// UpdateHost saves changes to a host already in the list.
func (s *Settings) UpdateHost(h HostConfig) {
	for i := range s.Hosts {
		if s.Hosts[i].ID == h.ID {
			s.Hosts[i] = h.Clone()
			s.Changed()
			return
		}
	}
}

// AddHost adds a host named after its provider, numbered when the name is
// taken, and selects it.
func (s *Settings) AddHost(p Provider) HostConfig {
	names := map[string]bool{}
	for _, h := range s.Hosts {
		names[h.Name] = true
	}
	name := p.DisplayName()
	for n := 2; names[name]; n++ {
		name = fmt.Sprintf("%s %d", p.DisplayName(), n)
	}
	h := NewHost(name, p)
	s.Hosts = append(s.Hosts, h)
	s.SelectedHost = h.ID
	s.Changed()
	return h
}

// RemoveHost removes a host and its secret.
func (s *Settings) RemoveHost(id string) {
	for i, h := range s.Hosts {
		if h.ID != id {
			continue
		}
		s.SetSecret(h.SecretKey(), "")
		s.Hosts = append(s.Hosts[:i:i], s.Hosts[i+1:]...)
		if s.SelectedHost == id {
			s.SelectedHost = ""
			if len(s.Hosts) > 0 {
				s.SelectedHost = s.Hosts[0].ID
			}
		}
		s.Changed()
		return
	}
}

// Secret is the secret under key, or "".
func (s *Settings) Secret(key string) string { return s.secrets[key] }

// SetSecret keeps a secret; "" removes it.
func (s *Settings) SetSecret(key, value string) {
	if s.secrets[key] == value {
		return
	}
	if value == "" {
		delete(s.secrets, key)
	} else {
		s.secrets[key] = value
	}
	saveSecrets(s.secrets)
}

func loadSecrets() map[string]string {
	m := map[string]string{}
	if data, err := os.ReadFile(paths.Secrets()); err == nil {
		_ = json.Unmarshal(data, &m)
	}
	return m
}

// saveSecrets writes the file with 0600 before any secret is in it.
func saveSecrets(m map[string]string) {
	data, err := json.Marshal(m)
	if err != nil {
		return
	}
	_ = paths.WriteAtomic(paths.Secrets(), data, 0o600)
}

// hostName is a migrated host's name: its bucket, or the host of its
// address.
func hostName(raw, fallback string) string {
	if u, err := url.Parse(raw); err == nil && u.Hostname() != "" {
		return u.Hostname()
	}
	return fallback
}
