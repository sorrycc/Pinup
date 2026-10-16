package main

import (
	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"pinup/internal/settings"
)

// welcomeWindow is shown on first launch: what Pinup does, where it
// lives, and a way to set up a host.
type welcomeWindow struct {
	a   *app
	win *mygo.Window
}

func (w *welcomeWindow) window() *mygo.Window {
	if w == nil {
		return nil
	}
	return w.win
}

func (a *app) showWelcome() {
	mygo.App.Focus()
	if a.welcome != nil {
		a.welcome.win.Focus()
		return
	}
	w := &welcomeWindow{a: a}
	a.welcome = w
	w.win = mygo.NewWindow(mygo.WindowOptions{
		Title: "Welcome to Pinup", Width: 520, Height: 600, DisableResize: true, DisableMinimize: true,
		DisableMaximize: true, DisableFullScreen: true, TitleBarStyle: mygo.TitleBarHidden, Content: ui.View(w.view),
	})
	w.win.Center()
	w.win.OnClosed(func() {
		// However it closes, it has been seen.
		a.s.Welcomed = true
		a.s.Changed()
		a.welcome = nil
		a.windowClosed()
	})
}

func (w *welcomeWindow) shortcutsText() string {
	clip := settings.ShortcutDisplay(w.a.s.ClipboardShortcut)
	shot := settings.ShortcutDisplay(w.a.s.ScreenshotShortcut)
	switch {
	case clip != "" && shot != "":
		return clip + " uploads the clipboard, " + shot + " a screenshot."
	case clip != "":
		return clip + " uploads the clipboard. Add a screenshot shortcut in Settings."
	case shot != "":
		return shot + " captures part of the screen. Add a clipboard shortcut in Settings."
	}
	return "Set shortcuts in Settings to upload the clipboard or capture part of the screen."
}

func (w *welcomeWindow) view(c *ui.Context) {
	w.a.theme(c)
	t := c.Theme()
	needsHost := len(w.a.s.Hosts) == 0
	c.OnShortcut(ui.Cmd, ui.KeyW, w.win.Close)
	ui.Column(c).Fill().AlignItems(ui.Center).Padding(44, 48, 28).DragWindow().Children(func() {
		ui.Image(c, appIcon()).Size(96, 96).Margin(0, 0, 16, 0)
		ui.Text(c, "Welcome to Pinup").FontSize(26).Bold()
		ui.Text(c, "Upload images from the menu bar and paste the link anywhere.").TextColor(t.TextMuted).Margin(8, 0, 30, 0)
		ui.Column(c).Gap(18).AlignSelf(ui.Stretch).Children(func() {
			feature(c, iconPin, ui.Hex("#FF2D55"), "Lives in the menu bar", "Drop files on the pin, or click it for recent uploads.")
			feature(c, iconKeyboard, ui.Hex("#FF9500"), "Upload from any app", w.shortcutsText())
			feature(c, iconLink, ui.Hex("#AF52DE"), "Links ready to paste", "Copied as Markdown, a plain URL or an HTML tag.")
		})
		ui.Row(c).Gap(10).Margin(34, 0, 18, 0).Children(func() {
			if needsHost && ui.Button(c, "Later").Clicked() {
				w.win.Close()
			}
			label := "Get Started"
			if needsHost {
				label = "Set Up a Host…"
			}
			primary := ui.PrimaryButton(c, label).MinWidth(180)
			if primary.Clicked() || c.Shortcut(0, ui.KeyEnter) {
				if needsHost {
					w.a.showSettings(paneHosts)
				}
				w.win.Close()
			}
		})
		ui.Text(c, "Don't see the pin? A full menu bar hides icons behind the camera housing. Hold ⌘ and drag other icons away to make room.").
			FontSize(11).TextColor(t.TextMuted).TextAlign(ui.Center).MaxWidth(380)
	})
}

func feature(c *ui.Context, icon *ui.SVG, tint ui.Color, title, detail string) {
	ui.Row(c).Gap(14).AlignItems(ui.Center).Children(func() {
		ui.Box(c).Size(36, 36).Radius(9).Background(tint).Center().Children(func() {
			ui.Icon(c, icon).FontSize(19).TextColor(ui.RGB(255, 255, 255))
		})
		ui.Column(c).Grow(1).Shrink(1).Gap(2).Children(func() {
			ui.Text(c, title).FontSize(13).Bold()
			ui.Text(c, detail).FontSize(12).TextColor(c.Theme().TextMuted)
		})
	})
}
