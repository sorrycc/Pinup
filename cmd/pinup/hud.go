package main

import (
	"os"
	"strings"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"pinup/internal/history"
	"pinup/internal/settings"
)

// hud is a small panel under the menu bar icon that confirms a copied
// link or shows why an upload failed. It never takes the keyboard, stays
// while the pointer rests on it, and a click on it opens History or does
// what its hint says.
type hud struct {
	a   *app
	win *mygo.Window

	thumb    *ui.Bitmap
	icon     *ui.SVG
	tint     ui.Color
	title    string
	subtitle string
	hint     string
	wraps    bool
	action   func()
	// gen counts what the panel showed, so a timer of an earlier one
	// never hides a later one.
	gen       int
	announced int
	hovered   bool
	hiding    bool
	height    int
}

const hudWidth = 320

func (h *hud) window() *mygo.Window { return h.win }

func (h *hud) success(e history.Entry, count int, format settings.LinkFormat) {
	h.thumb = nil
	if p := e.ThumbnailPath(); p != "" {
		if data, err := os.ReadFile(p); err == nil {
			h.thumb, _ = ui.DecodeBitmap(data)
		}
	}
	title := "Copied as " + format.DisplayName()
	if count > 1 {
		title = itoa(count) + " links copied as " + format.DisplayName()
	}
	h.show(iconCheck, ui.Hex("#34C759"), title, e.URL, "", false, 2400*time.Millisecond, nil)
}

// failure gets hint a line of its own, so a long message never pushes it
// out of sight; a click runs action.
func (h *hud) failure(message, hint string, action func()) {
	h.thumb = nil
	h.show(iconAlert, ui.Hex("#FF9500"), "Upload failed", message, hint, true, 6*time.Second, action)
}

func (h *hud) message(title, subtitle string, icon *ui.SVG) {
	h.thumb = nil
	h.show(icon, ui.Hex("#8E8E93"), title, subtitle, "", true, 2400*time.Millisecond, nil)
}

func (h *hud) show(icon *ui.SVG, tint ui.Color, title, subtitle, hint string, wraps bool, d time.Duration, action func()) {
	h.icon, h.tint, h.title, h.subtitle, h.hint, h.wraps, h.action = icon, tint, title, subtitle, hint, wraps, action
	h.gen++
	h.hiding = false
	height := 68
	if wraps {
		lines := min(3, 1+len(subtitle)/44)
		height = 50 + 15*lines
		if hint != "" {
			height += 16
		}
	}
	if h.win == nil {
		if tray(h.a) == nil {
			return
		}
		h.height = height
		h.win = mygo.NewFlyout(mygo.FlyoutOptions{
			Tray: tray(h.a), Placement: mygo.PlacementBottom, Gap: 6, Width: hudWidth, Height: height,
			Shadow: true, Content: ui.View(h.view),
		})
		h.win.OnClosed(func() { h.win = nil })
	} else if h.height != height {
		h.height = height
		h.win.SetSize(hudWidth, height)
	}
	// macOS keeps the icon out of a full menu bar, parked out of sight:
	// the panel then goes to the top right of the main display.
	if !trayShown(tray(h.a)) {
		d := mygo.Screen.PrimaryDisplay().WorkArea
		h.win.SetPosition(d.X+d.Width-hudWidth-12, d.Y+8)
	}
	h.win.Invalidate()
	h.hideAfter(d)
}

// hideAfter hides the panel when the time is up, or once the pointer has
// left: it stays as long as the pointer rests on it, so a long message
// can be read.
func (h *hud) hideAfter(d time.Duration) {
	gen := h.gen
	time.AfterFunc(d, func() {
		h.a.post(func() {
			if h.gen != gen || h.win == nil {
				return
			}
			if h.hovered {
				h.hideAfter(400 * time.Millisecond)
				return
			}
			h.hide()
		})
	})
}

func (h *hud) hide() {
	if h.win == nil || h.hiding {
		return
	}
	h.hiding = true
	gen := h.gen
	time.AfterFunc(250*time.Millisecond, func() {
		h.a.post(func() {
			if h.gen == gen && h.win != nil {
				h.win.Close()
			}
		})
	})
}

func tray(a *app) *mygo.Tray {
	if a.tray == nil {
		return nil
	}
	return a.tray.t
}

// trayShown reports whether the icon is in the menu bar of a display. A
// menu bar that hides itself only lifts the icon above the display's top
// edge, which still says where the panel belongs.
func trayShown(t *mygo.Tray) bool {
	if t == nil {
		return false
	}
	b := t.Bounds()
	if b.Width == 0 || b.Height == 0 {
		return false
	}
	mid := b.X + b.Width/2
	for _, d := range mygo.Screen.Displays() {
		r := d.Bounds
		if mid < r.X || mid >= r.X+r.Width {
			continue
		}
		if b.Y >= r.Y-b.Height && b.Y < r.Y+40 {
			return true
		}
	}
	return false
}

func (h *hud) clicked() {
	action := h.action
	h.hide()
	if action != nil {
		action()
	} else {
		h.a.showHistory()
	}
}

func (h *hud) view(c *ui.Context) {
	h.a.theme(c)
	t := c.Theme()
	c.Root().Background(ui.Transparent)
	if h.announced != h.gen {
		h.announced = h.gen
		// VoiceOver users hear what sighted users see.
		parts := []string{h.title, h.subtitle}
		if h.hint != "" {
			parts = append(parts, h.hint)
		}
		c.Announce(strings.Join(parts, ". "))
	}
	panel := ui.Row(c).Fill().Gap(12).Padding(12, 16, 12, 14).Radius(18).Cursor(ui.CursorPointer).
		Background(t.Background.Alpha(0.96)).Border(1, t.Border.Alpha(0.5))
	// Comes in from a little above and fades, as it goes.
	shown := float32(1)
	if h.hiding {
		shown = 0
	}
	fade := panel.Animate("fade", shown, 220*time.Millisecond)
	panel.Opacity(fade)
	if !c.Preferences().ReduceMotion {
		panel.Translate(0, (fade-1)*8)
	}
	h.hovered = panel.Hovered()
	if panel.Clicked() {
		h.a.post(h.clicked)
	}
	panel.Children(func() {
		if h.thumb != nil {
			ui.Box(c).Size(44, 44).Children(func() {
				ui.Image(c, h.thumb).Size(40, 40).Fit(ui.Cover).Radius(9)
				badge(c, h.icon, h.tint, 18).Absolute().Right(0).Bottom(0)
			})
		} else {
			badge(c, h.icon, h.tint, 32).Margin(0, 6)
		}
		ui.Column(c).Grow(1).Gap(2).Justify(ui.Center).Children(func() {
			ui.Text(c, h.title).FontSize(13).Bold().SingleLine()
			sub := ui.Text(c, h.subtitle).FontSize(11).TextColor(t.TextMuted)
			if h.wraps {
				sub.MaxLines(3)
			} else {
				sub.SingleLine().Ellipsis("…")
			}
			if h.hint != "" {
				ui.Text(c, h.hint).FontSize(11).FontWeight(500).SingleLine()
			}
		})
	})
}

// badge is a symbol in white on a disc of tint, as the system's filled
// symbols are.
func badge(c *ui.Context, icon *ui.SVG, tint ui.Color, size float32) ui.Element {
	return ui.Box(c).Size(size, size).Radius(size/2).Background(tint).Center().Border(1.5, ui.RGB(255, 255, 255)).Children(func() {
		ui.Icon(c, icon).FontSize(size * 0.58).TextColor(ui.RGB(255, 255, 255))
	})
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b []byte
	for ; n > 0; n /= 10 {
		b = append([]byte{byte('0' + n%10)}, b...)
	}
	if neg {
		b = append([]byte{'-'}, b...)
	}
	return string(b)
}
