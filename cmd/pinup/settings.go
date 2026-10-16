package main

import (
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/plugins/updater"
	"github.com/egoist/mygo/ui"

	"pinup/internal/hosts"
	"pinup/internal/imageproc"
	"pinup/internal/paths"
	"pinup/internal/settings"
)

const (
	paneGeneral = iota
	paneHosts
	paneShortcuts
)

func paneNamed(name string) int {
	switch name {
	case "hosts":
		return paneHosts
	case "shortcuts":
		return paneShortcuts
	}
	return paneGeneral
}

// settingsWindow is the Settings window (⌘,). Every change is saved as it
// is made.
type settingsWindow struct {
	a    *app
	win  *mygo.Window
	pane int

	// The Test Upload of the host shown: running, and what it gave back.
	testing    bool
	testResult string
	testFailed bool
	testHost   string
	// shortcutNote says why a combination was refused.
	shortcutNote string
	recorders    [2]recorder
	hostName     ui.Handle
	// sizedFor is the pane the window was last sized for.
	sizedFor int
}

// paneHeights are the window heights that show each pane's cards, as the
// Swift version sized them; Hosts scrolls beyond.
var paneHeights = map[int]int{paneGeneral: 640, paneHosts: 700, paneShortcuts: 300}

func (s *settingsWindow) window() *mygo.Window {
	if s == nil {
		return nil
	}
	return s.win
}

func (a *app) showSettings(pane int) {
	mygo.App.Focus()
	if a.settings != nil {
		a.settings.pane = pane
		a.settings.win.Show()
		a.settings.win.Focus()
		a.settings.win.Invalidate()
		return
	}
	s := &settingsWindow{a: a, pane: pane, sizedFor: pane}
	a.settings = s
	s.win = mygo.NewWindow(mygo.WindowOptions{
		Title: "Settings", Width: 600, Height: paneHeights[pane], UseContentSize: true, MinWidth: 520, MinHeight: 280, StateKey: "settings",
		DisableMaximize: true, DisableFullScreen: true, Content: ui.View(s.view),
	})
	s.win.OnClosed(func() {
		for i := range s.recorders {
			s.recorders[i].stop(a)
		}
		a.settings = nil
		a.windowClosed()
	})
}

func (s *settingsWindow) view(c *ui.Context) {
	s.a.theme(c)
	t := c.Theme()
	c.OnShortcut(ui.Cmd, ui.KeyW, s.win.Close)
	if s.pane != s.sizedFor && s.win != nil {
		s.sizedFor = s.pane
		w, _ := s.win.ContentSize()
		s.win.SetContentSize(w, paneHeights[s.pane])
	}
	ui.Column(c).Fill().Children(func() {
		ui.Row(c).Justify(ui.Center).Padding(12, 16).Children(func() {
			ui.Segmented(c, &s.pane, "General", "Hosts", "Shortcuts").Label("Settings pane")
		})
		ui.Divider(c)
		ui.Scroll(c).Grow(1).Background(t.Surface.Mix(t.Background, 0.5)).Children(func() {
			ui.Column(c).Padding(20, 24, 28).Gap(6).MaxWidth(620).Margin(0, ui.Auto).FillWidth().Children(func() {
				switch s.pane {
				case paneHosts:
					s.hostsPane(c)
				case paneShortcuts:
					s.shortcutsPane(c)
				default:
					s.generalPane(c)
				}
			})
		})
	})
}

// card is a rounded group of rows, like System Settings', with a note
// under it when footer is given.
func card(c *ui.Context, footer string, rows func()) {
	t := c.Theme()
	ui.Column(c).Radius(10).Background(t.Background).Border(1, t.Border.Alpha(0.7)).Dividers(1, t.Border.Alpha(0.6)).Children(rows)
	if footer != "" {
		ui.Text(c, footer).FontSize(11).TextColor(t.TextMuted).Padding(2, 12, 0, 12)
	}
	ui.Box(c).Height(12)
}

// formRow is one row of a card: a title, an optional line of detail under
// it, and a control on the trailing edge.
func formRow(c *ui.Context, title, detail string, control func()) {
	t := c.Theme()
	ui.Row(c.Key(title)).Padding(10, 14).Gap(16).MinHeight(44).Children(func() {
		ui.Column(c).Grow(1).Shrink(1).Gap(2).Children(func() {
			ui.Text(c, title).FontSize(13)
			if detail != "" {
				ui.Text(c, detail).FontSize(11).TextColor(t.TextMuted)
			}
		})
		ui.Row(c).Shrink(0).Gap(8).Children(control)
	})
}

// field is a text field of the width the cards give their fields.
func field(c *ui.Context, key string, value *string, placeholder string) ui.Element {
	return ui.TextInput(c.Key(key), value).Placeholder(placeholder).Label(key).Width(270)
}

// choice is a pop-up of display names, bound to a value of its own type.
func choice[T comparable](c *ui.Context, key string, value *T, all []T, name func(T) string) bool {
	names := make([]string, len(all))
	chosen := ""
	for i, v := range all {
		names[i] = name(v)
		if v == *value {
			chosen = names[i]
		}
	}
	if ui.Select(c.Key(key), &chosen, names).Label(key).Width(200).Changed() {
		for i, n := range names {
			if n == chosen {
				*value = all[i]
				return true
			}
		}
	}
	return false
}

// MARK: General

func (s *settingsWindow) generalPane(c *ui.Context) {
	st := s.a.s
	card(c, "Markdown is ![name](url) and HTML is an <img> tag. The menu bar's Copy As menu changes this too.", func() {
		formRow(c, "Copy links as", "", func() {
			if choice(c, "Link format", &st.LinkFormat, settings.LinkFormats, settings.LinkFormat.DisplayName) {
				st.Changed()
			}
		})
	})
	card(c, "Transparent images stay out of JPEG, and animations are never converted.", func() {
		formRow(c, "Convert images to", "", func() {
			if choice(c, "Conversion", &st.Conversion, imageproc.Conversions, imageproc.Conversion.DisplayName) {
				st.Changed()
			}
		})
		formRow(c, "Quality", "For JPEG and HEIC.", func() {
			off := st.Conversion == imageproc.Original
			slider := ui.Slider(c.Key("quality"), &st.Quality, 0.3, 1).Label("Quality").Width(180).Disabled(off)
			// Saved as the drag goes: the file is small.
			if slider.Changed() {
				st.Changed()
			}
			ui.Text(c, fmt.Sprintf("%d%%", int(st.Quality*100+0.5))).Width(36).TextAlign(ui.End).
				FontSize(12).TextColor(c.Theme().TextMuted).FontFeatures("tnum")
		})
	})
	card(c, "", func() {
		formRow(c, "Remove location from photos",
			"Drops GPS data before upload. JPEG pixels stay untouched; other formats are rewritten at full quality.", func() {
				if ui.Switch(c.Key("strip"), &st.StripLocation).Label("Remove location from photos").Changed() {
					st.Changed()
				}
			})
		formRow(c, "Play a sound when links are copied", "", func() {
			if ui.Switch(c.Key("sound"), &st.PlaySound).Label("Play a sound when links are copied").Changed() {
				st.Changed()
			}
		})
		formRow(c, "Open Pinup at login", "", func() {
			on := mygo.App.IsReady() && mygo.App.OpenAtLogin()
			if ui.Switch(c.Key("login"), &on).Label("Open Pinup at login").Changed() {
				if err := mygo.App.SetOpenAtLogin(on); mygo.App.IsReady() && err != nil {
					c.Toast("Couldn't change: " + err.Error())
				}
			}
		})
	})
	s.updatesCard(c)
	entries := s.a.hist.Entries()
	detail := "No uploads yet."
	if len(entries) > 0 {
		var total int64
		for _, e := range entries {
			total += e.Size
		}
		detail = fmt.Sprintf("%d %s, %s in all.", len(entries), plural(len(entries), "upload", "uploads"), byteCount(total))
	}
	card(c, "Clearing removes the list and its thumbnails. The uploaded files stay on their host.", func() {
		formRow(c, "Upload history", detail, func() {
			if ui.Button(c, "Clear History…").Disabled(len(entries) == 0).Clicked() {
				s.confirm("Clear the upload history?", "This removes the list and its thumbnails. The uploaded files stay on their host.",
					"Clear History", s.a.hist.Clear)
			}
		})
	})
}

// updatesCard shows Pinup's version and, in a copy that updates itself,
// whether it checks for new ones.
func (s *settingsWindow) updatesCard(c *ui.Context) {
	version := "Development build"
	if v := mygo.App.Version(); v != "" {
		version = "Version " + v
	}
	if !s.a.canUpdate {
		card(c, "", func() {
			formRow(c, "Pinup "+strings.TrimPrefix(version, "Version "), "This copy doesn't update itself.", func() {})
		})
		return
	}
	checked := "Not checked yet."
	if t := updater.LastCheck(); !t.IsZero() {
		checked = "Last checked " + strings.ToLower(relativeTime(t, time.Now())) + "."
	}
	card(c, "Pinup checks GitHub for a new release once a day, and asks before installing it.", func() {
		formRow(c, "Check for updates automatically", "", func() {
			on := updater.AutomaticChecks()
			if ui.Switch(c.Key("updates"), &on).Label("Check for updates automatically").Changed() {
				updater.SetAutomaticChecks(on)
			}
		})
		formRow(c, version, checked, func() {
			if ui.Button(c, "Check Now").Clicked() {
				updater.CheckForUpdates()
			}
		})
	})
}

// confirm asks a question in a sheet and runs yes when the first button is
// chosen.
func (s *settingsWindow) confirm(message, detail, button string, yes func()) {
	go func() {
		res, err := mygo.Dialog.Message(mygo.MessageOptions{
			Parent: s.win, Type: mygo.MessageWarning, Message: message, Detail: detail, Buttons: []string{button, "Cancel"},
		})
		if err == nil && res.Button == 0 {
			s.a.post(yes)
		}
	}()
}

// MARK: Hosts

func secretsNote() string {
	dir := paths.Root()
	if home, err := os.UserHomeDir(); err == nil && strings.HasPrefix(dir, home) {
		dir = "~" + strings.TrimPrefix(dir, home)
	}
	return "Saved in secrets.json in " + dir + ", readable only by you."
}

const testHint = "Uploads a small image to check the host."

func (s *settingsWindow) hostsPane(c *ui.Context) {
	st := s.a.s
	shown, ok := st.SelectedHostConfig()
	card(c, "Add a host for each place you upload to: an S3-compatible bucket, or any HTTP upload API.", func() {
		formRow(c, "Upload to", "", func() {
			if ok {
				names := make([]string, len(st.Hosts))
				chosen := shown.Name
				for i, h := range st.Hosts {
					names[i] = h.Name
				}
				if ui.Select(c.Key("host"), &chosen, names).Label("Upload to").Width(200).Changed() {
					for _, h := range st.Hosts {
						if h.Name == chosen {
							st.SelectedHost = h.ID
							st.Changed()
							s.testResult = ""
							break
						}
					}
				}
			}
			ui.MenuButton(c, "Add Host", func(m *ui.Menu) {
				for _, p := range []settings.Provider{settings.S3, settings.Custom} {
					if m.Item("Add " + p.DisplayName() + "…").Chosen() {
						st.AddHost(p)
						s.testResult = ""
						s.hostName.Focus()
					}
				}
			})
			if ok && ui.Button(c, "Remove…").Clicked() {
				id, name := shown.ID, shown.Name
				s.confirm(fmt.Sprintf("Remove “%s”?", name),
					"Its settings and keys are deleted. Files already uploaded stay on the host and in History.", "Remove",
					func() { st.RemoveHost(id); s.testResult = "" })
			}
		})
	})
	if !ok {
		ui.Text(c, "No hosts yet. Choose Add S3-Compatible or Add Custom HTTP above.").FontSize(12).TextColor(c.Theme().TextMuted).Padding(4, 12)
		return
	}
	// Edits go into a copy, saved as they are typed.
	h := shown.Clone()
	changed := false
	secret := st.Secret(h.SecretKey())
	secretChanged := false
	edit := func(e ui.Element) {
		if e.Changed() {
			changed = true
		}
	}
	card(c, "", func() {
		formRow(c, "Name", "Shown in the Upload To menu and History.", func() {
			edit(field(c, "Name", &h.Name, "My Images").Bind(&s.hostName))
		})
	})
	if h.Provider == settings.S3 {
		if h.S3 == nil {
			d := hosts.DefaultS3()
			h.S3 = &d
		}
		cfg := h.S3
		card(c, "Works with AWS S3, Cloudflare R2, Aliyun OSS, Tencent COS, MinIO and other S3-compatible services.", func() {
			formRow(c, "Endpoint", "", func() { edit(field(c, "Endpoint", &cfg.Endpoint, "https://<account>.r2.cloudflarestorage.com")) })
			formRow(c, "Region", "", func() { edit(field(c, "Region", &cfg.Region, "us-east-1, or auto for R2")) })
			formRow(c, "Bucket", "", func() { edit(field(c, "Bucket", &cfg.Bucket, "my-images")) })
			formRow(c, "Path-style addressing", "endpoint/bucket/key. R2 and MinIO need it.", func() {
				edit(ui.Switch(c.Key("pathStyle"), &cfg.PathStyle).Label("Path-style addressing"))
			})
		})
		card(c, secretsNote(), func() {
			formRow(c, "Access key ID", "", func() { edit(field(c, "Access key ID", &cfg.AccessKeyID, "Access key ID")) })
			formRow(c, "Secret access key", "", func() {
				if field(c, "Secret access key", &secret, "Secret access key").Password().Changed() {
					secretChanged = true
				}
			})
		})
		card(c, "The file path can use {year}, {month}, {day}, {timestamp}, {random}, {name} and {ext}. "+
			"The public URL is your CDN or public bucket domain: use {key} to place the path, or leave it empty for the object's own address.", func() {
			formRow(c, "File path", "", func() { edit(field(c, "File path", &cfg.KeyTemplate, "{year}/{month}/{timestamp}-{random}.{ext}")) })
			formRow(c, "Public URL", "", func() { edit(field(c, "Public URL", &cfg.PublicURL, "https://img.example.com")) })
		})
	} else {
		if h.Custom == nil {
			d := hosts.DefaultCustom()
			h.Custom = &d
		}
		cfg := h.Custom
		card(c, "Multipart sends a form; JSON sends the file in base64; Raw File sends it as the body.", func() {
			formRow(c, "URL", "{name} becomes the file's name.", func() { edit(field(c, "URL", &cfg.URL, "https://example.com/api/upload")) })
			formRow(c, "Request", "", func() {
				method := strings.ToUpper(cfg.Method)
				if method == "" {
					method = "POST"
				}
				if ui.Select(c.Key("method"), &method, []string{"POST", "PUT"}).Label("Method").Width(90).Changed() {
					cfg.Method = method
					changed = true
				}
				if choice(c, "Body", &cfg.Body, hosts.Bodies, hosts.Body.DisplayName) {
					changed = true
				}
			})
		})
		card(c, "Headers usually carry the token. "+secretsNote(), func() {
			formRow(c, "File field", "The form field or JSON key.", func() { edit(field(c, "File field", &cfg.FileField, "file")) })
			formRow(c, "Extra fields", "One key=value per line.", func() {
				edit(ui.TextArea(c.Key("fields"), &cfg.Fields).Placeholder("key=value").Label("Extra fields").
					Font("monospace").FontSize(12).Width(270).Height(52))
			})
			formRow(c, "Headers", "One Name: value per line.", func() {
				if ui.TextArea(c.Key("headers"), &secret).Placeholder("Authorization: Bearer …").Label("Headers").
					Font("monospace").FontSize(12).Width(270).Height(52).Changed() {
					secretChanged = true
				}
			})
		})
		card(c, "A path into the JSON reply, like data.url or data.0.src. Empty takes the whole reply. "+
			"The prefix goes before the value, for APIs that return a path.", func() {
			formRow(c, "Link at", "", func() { edit(field(c, "Link at", &cfg.URLPath, "data.url")) })
			formRow(c, "Link prefix", "", func() { edit(field(c, "Link prefix", &cfg.URLPrefix, "Optional, put before the value")) })
		})
	}
	if changed {
		st.UpdateHost(h)
	}
	if secretChanged {
		st.SetSecret(h.SecretKey(), secret)
	}
	if s.testHost != h.ID {
		s.testHost, s.testResult = h.ID, ""
	}
	card(c, "", func() {
		detail, color := testHint, c.Theme().TextMuted
		if s.testResult != "" {
			detail = s.testResult
			if s.testFailed {
				color = c.Theme().Danger
			}
		}
		ui.Row(c).Padding(10, 14).Gap(16).MinHeight(44).Children(func() {
			ui.Column(c).Grow(1).Shrink(1).Gap(2).Children(func() {
				ui.Text(c, "Test the connection").FontSize(13)
				ui.Text(c, detail).FontSize(11).TextColor(color).Selectable()
			})
			if s.testing {
				ui.Spinner(c)
			}
			if ui.Button(c, "Test Upload").Disabled(s.testing).Clicked() {
				s.testing, s.testResult = true, ""
				id := h.ID
				s.a.up.Test(st.HostFor(h), func(link string, err error) {
					s.testing = false
					if s.testHost != id {
						return
					}
					if err != nil {
						s.testResult, s.testFailed = err.Error(), true
					} else {
						s.testResult, s.testFailed = "Uploaded: "+link, false
					}
				})
			}
		})
	})
}

// MARK: Shortcuts

func (s *settingsWindow) shortcutsPane(c *ui.Context) {
	st := s.a.s
	note := s.shortcutNote
	if note == "" && len(s.a.failedShortcuts) > 0 {
		note = strings.Join(s.a.failedShortcuts, " and ") + " is taken by another app. Pick another combination."
	}
	card(c, "Both work from any app. Click a shortcut, then press a combination with ⌘, ⌃ or ⌥. Press Delete to clear it.", func() {
		formRow(c, "Upload clipboard", "Copied files, or the image on the clipboard.", func() {
			if acc, ok := s.recorders[0].view(c, s.a, "clipboard", st.ClipboardShortcut); ok {
				s.setShortcut(&st.ClipboardShortcut, acc, st.ScreenshotShortcut, "capturing a screenshot")
			}
		})
		formRow(c, "Capture screenshot", "Pick an area or a window, like ⇧⌘4.", func() {
			if acc, ok := s.recorders[1].view(c, s.a, "screenshot", st.ScreenshotShortcut); ok {
				s.setShortcut(&st.ScreenshotShortcut, acc, st.ClipboardShortcut, "uploading the clipboard")
			}
		})
	})
	if note != "" {
		ui.Text(c, note).FontSize(12).TextColor(c.Theme().Warning).Padding(0, 12)
	}
}

// setShortcut refuses a combination the other action already uses.
func (s *settingsWindow) setShortcut(target *string, acc, other, otherName string) {
	if acc != "" && acc == other {
		beep()
		s.shortcutNote = settings.ShortcutDisplay(acc) + " is already used for " + otherName + "."
		return
	}
	s.shortcutNote = ""
	*target = acc
	s.a.s.Changed()
}
