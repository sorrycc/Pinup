package main

import (
	"strings"

	"github.com/egoist/mygo/ui"

	"pinup/internal/settings"
)

// recorder is a field that records a shortcut: click it, then press the
// combination. Escape cancels; Delete or the clear button removes it.
// Pinup's shortcuts are off while it records, so they can be recorded
// again.
type recorder struct {
	recording bool
	focus     ui.Handle
	// recorded is a combination pressed, or "" cleared, since the last
	// build: keys come between builds.
	recorded *string
}

func (r *recorder) record(a *app, acc string) {
	r.stop(a)
	r.recorded = &acc
}

func (r *recorder) start(a *app) {
	if !r.recording {
		r.recording = true
		a.pauseShortcuts(true)
	}
}

func (r *recorder) stop(a *app) {
	if r.recording {
		r.recording = false
		a.pauseShortcuts(false)
	}
}

// view shows the field with the shortcut current. It returns a new
// accelerator, "" when cleared, and true when the user changed it.
func (r *recorder) view(c *ui.Context, a *app, key, current string) (string, bool) {
	t := c.Theme()
	result, changed := "", false
	if r.recorded != nil {
		result, changed = *r.recorded, true
		r.recorded = nil
	}
	box := ui.Row(c.Key(key)).Width(168).Height(28).Radius(7).Background(t.Surface).PaddingX(8).
		Focusable().FocusRing(false).Bind(&r.focus).Cursor(ui.CursorPointer).
		Label("Keyboard shortcut").Value(orNone(settings.ShortcutDisplay(current)))
	// Recording ends as the field loses the keyboard: the window closes,
	// or another app comes forward, so the shortcuts are never left off.
	if r.recording && !box.Focused() {
		r.stop(a)
	}
	if box.Clicked() {
		if r.recording {
			r.stop(a)
		} else {
			r.start(a)
			r.focus.Focus()
		}
	}
	box.HandleInput(func(ev ui.InputEvent) bool {
		if !r.recording || ev.Kind != ui.InputKeyDown {
			return false
		}
		switch {
		case ev.Mods == 0 && ev.Key == ui.KeyEscape:
			r.stop(a)
		case ev.Mods == 0 && (ev.Key == ui.KeyBackspace || ev.Key == ui.KeyDelete):
			r.record(a, "")
		default:
			acc := accelerator(ev)
			if acc == "" {
				beep()
				return true
			}
			r.record(a, acc)
		}
		return true
	})
	if r.recording {
		box.Border(2, t.Accent)
	} else if box.Focused() {
		box.Border(2, t.Focus)
	} else {
		box.Border(1, t.Border)
	}
	box.Children(func() {
		var label ui.Element
		switch {
		case r.recording:
			label = ui.Text(c, "Type shortcut…").TextColor(t.Accent)
		case current != "":
			label = ui.Text(c, settings.ShortcutDisplay(current)).FontWeight(500)
		default:
			label = ui.Text(c, "Click to record").TextColor(t.TextMuted)
		}
		label.FontSize(13).Grow(1).TextAlign(ui.Center).SingleLine()
		if current != "" && !r.recording {
			clearBtn := ui.Box(c).Size(18, 18).Center().Label("Clear shortcut").Tooltip("Clear shortcut").Role(ui.RoleButton)
			if clearBtn.Clicked() {
				r.stop(a)
				result, changed = "", true
			}
			clearBtn.Children(func() { ui.Icon(c, iconClear).FontSize(14).TextColor(t.TextMuted) })
		}
	})
	return result, changed
}

func orNone(s string) string {
	if s == "" {
		return "None"
	}
	return s
}

var keyNames = map[ui.Key]string{
	ui.KeySpace: "Space", ui.KeyEnter: "Enter", ui.KeyTab: "Tab", ui.KeyLeft: "Left", ui.KeyRight: "Right",
	ui.KeyUp: "Up", ui.KeyDown: "Down", ui.KeyHome: "Home", ui.KeyEnd: "End", ui.KeyPageUp: "PageUp",
	ui.KeyPageDown: "PageDown", ui.KeyMinus: "-", ui.KeyEqual: "=", ui.KeyComma: ",", ui.KeyPeriod: ".",
	ui.KeySlash: "/", ui.KeySemicolon: ";", ui.KeyQuote: "'", ui.KeyBracketLeft: "[", ui.KeyBracketRight: "]",
	ui.KeyBackslash: "\\", ui.KeyBackquote: "`",
}

// accelerator is the combination a key press makes, or "" without Cmd,
// Ctrl or Option, which every global shortcut needs so it doesn't swallow
// typing.
func accelerator(ev ui.InputEvent) string {
	if ev.Mods&(ui.Super|ui.Ctrl|ui.Alt) == 0 {
		return ""
	}
	key := ev.Key
	if key == ui.KeyUnknown {
		key = ev.PhysicalKey
	}
	name := keyNames[key]
	switch {
	case name != "":
	case key >= ui.KeyA && key <= ui.KeyZ:
		name = string(rune('A' + int(key-ui.KeyA)))
	case key >= ui.Key0 && key <= ui.Key9:
		name = string(rune('0' + int(key-ui.Key0)))
	case key >= ui.KeyF1 && key <= ui.KeyF12:
		name = "F" + itoa(int(key-ui.KeyF1)+1)
	default:
		return ""
	}
	var mods []string
	for _, m := range []struct {
		mod  ui.Modifiers
		name string
	}{{ui.Ctrl, "Ctrl"}, {ui.Alt, "Alt"}, {ui.Shift, "Shift"}, {ui.Super, "Cmd"}} {
		if ev.Mods&m.mod != 0 {
			mods = append(mods, m.name)
		}
	}
	return strings.Join(append(mods, name), "+")
}
