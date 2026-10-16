package main

import (
	"fmt"
	"log"
	"time"
	"unicode/utf8"

	"github.com/egoist/mygo"

	"pinup/internal/capture"
	"pinup/internal/history"
	"pinup/internal/settings"
)

// trayIcon is the menu bar icon. Files dropped on it upload; while uploads
// run it shows their combined progress as a ring; its menu is built each
// time it opens.
type trayIcon struct {
	a        *app
	t        *mygo.Tray
	look     look
	progress float64
	// gen counts the looks, so a check or a warning going back to idle
	// never takes over a later look.
	gen int
}

func newTrayIcon(a *app) *trayIcon {
	ti := &trayIcon{a: a}
	t, err := mygo.NewTray(mygo.TrayOptions{Icon: menuBarPNG, IconIsTemplate: true, ToolTip: "Pinup: drop files to upload"})
	if err != nil {
		log.Println("tray:", err)
		return ti
	}
	ti.t = t
	t.OnClick(ti.openMenu)
	t.OnRightClick(ti.openMenu)
	t.OnDragEnter(func([]string) {
		if !a.up.Busy() {
			ti.set(lookDropTarget, 0)
		}
	})
	t.OnDragLeave(func() {
		if ti.look == lookDropTarget {
			ti.set(lookIdle, 0)
		}
	})
	t.OnDrop(func(paths []string) { a.upload(capture.Files(paths)) })
	return ti
}

func (ti *trayIcon) set(l look, progress float64) {
	if l == ti.look && (l != lookProgress || int(progress*50) == int(ti.progress*50)) {
		return
	}
	ti.look, ti.progress = l, progress
	ti.gen++
	if ti.t != nil {
		_ = ti.t.SetIcon(trayImage(l, progress), true)
		tips := map[look]string{
			lookIdle: "Pinup: drop files to upload", lookDropTarget: "Drop to upload", lookDone: "Upload finished",
			lookFailed: "Upload failed", lookProgress: fmt.Sprintf("Uploading, %d percent", int(progress*100)),
		}
		ti.t.SetToolTip(tips[l])
	}
}

// showProgress keeps the ring up until the batch reports how it went.
func (ti *trayIcon) showProgress(p float64) { ti.set(lookProgress, p) }

// showOutcome shows a check or a warning for a moment, unless another
// batch is still going.
func (ti *trayIcon) showOutcome(success bool) {
	if ti.a.up.Busy() {
		return
	}
	l, d := lookDone, 1400*time.Millisecond
	if !success {
		l, d = lookFailed, 3*time.Second
	}
	ti.set(l, 0)
	gen := ti.gen
	time.AfterFunc(d, func() {
		ti.a.post(func() {
			if ti.gen == gen {
				ti.set(lookIdle, 0)
			}
		})
	})
}

// openMenu builds the menu as it is now and shows it under the icon.
func (ti *trayIcon) openMenu() {
	if ti.t == nil {
		return
	}
	ti.t.SetMenu(mygo.NewMenu(ti.a.trayMenu()))
	ti.t.PopUpMenu()
	ti.t.SetMenu(nil)
}

func click(fn func()) func(*mygo.MenuItem, *mygo.Window) {
	return func(*mygo.MenuItem, *mygo.Window) { fn() }
}

func (a *app) trayMenu() []*mygo.MenuItem {
	var items []*mygo.MenuItem
	up := a.up
	if up.Busy() {
		// The last file may be done a moment before its batch is.
		count := max(1, up.ActiveCount())
		items = append(items,
			&mygo.MenuItem{Label: fmt.Sprintf("Uploading %d %s… %d%%", count, plural(count, "file", "files"), int(up.Progress()*100)),
				Symbol: "arrow.up.circle", Disabled: true},
			mygo.Separator())
	} else if msg := up.LastError(); msg != "" {
		items = append(items, &mygo.MenuItem{Label: "Last upload failed", Sublabel: msg, ToolTip: msg,
			Symbol: "exclamationmark.triangle", Disabled: true})
	}
	// Failed files stay reachable even after later uploads succeed.
	if !up.Busy() && len(up.Failed()) > 0 {
		n := len(up.Failed())
		items = append(items,
			&mygo.MenuItem{Label: fmt.Sprintf("Retry %d Failed %s", n, plural(n, "Upload", "Uploads")), Symbol: "arrow.clockwise", Click: click(a.retryFailed)},
			&mygo.MenuItem{Label: "Discard Failed Uploads", Symbol: "trash", Click: click(a.discardFailed)})
	}
	if !up.Busy() && (up.LastError() != "" || len(up.Failed()) > 0) {
		items = append(items, mygo.Separator())
	}

	items = append(items,
		&mygo.MenuItem{Label: "Upload Files…", Symbol: "folder", Accelerator: "Cmd+O", Click: click(a.uploadFiles)},
		&mygo.MenuItem{Label: "Upload from Clipboard", Symbol: "doc.on.clipboard", Accelerator: a.s.ClipboardShortcut, Click: click(a.uploadClipboard)},
		&mygo.MenuItem{Label: "Capture Screenshot", Symbol: "camera.viewfinder", Accelerator: a.s.ScreenshotShortcut, Click: click(a.captureScreenshot)},
	)

	entries := a.hist.Entries()
	if len(entries) > 0 {
		items = append(items, mygo.Separator(), &mygo.MenuItem{Label: "Recent", Type: mygo.MenuItemHeader})
		format := a.s.LinkFormat
		now := time.Now()
		for _, e := range entries[:min(5, len(entries))] {
			icon := menuThumbnail(e.ID, e.ThumbnailPath(), e.Name)
			title := menuTitle(e.Name, 34)
			items = append(items,
				&mygo.MenuItem{Label: title, Sublabel: menuSubtitle(e, now), Icon: icon,
					ToolTip: e.URL + "\nClick to copy as " + format.DisplayName() + ". Option-click to open.",
					Click: click(func() {
						a.copyEntries([]history.Entry{e}, a.s.LinkFormat)
						a.hud.success(e, 1, a.s.LinkFormat)
					})},
				&mygo.MenuItem{Label: title, Sublabel: "Open in Browser", Icon: icon, Alternate: true,
					Click: click(func() { a.open(e.URL) })})
		}
	}
	items = append(items, mygo.Separator(),
		&mygo.MenuItem{Label: "Show History", Symbol: "clock.arrow.circlepath", Accelerator: "Cmd+Y", Click: click(a.showHistory)},
		mygo.Separator())

	var hostItems []*mygo.MenuItem
	selected, _ := a.s.SelectedHostConfig()
	for _, h := range a.s.Hosts {
		id := h.ID
		hostItems = append(hostItems, &mygo.MenuItem{Label: h.Name, Type: mygo.MenuItemCheckbox, Checked: h.ID == selected.ID,
			Click: click(func() { a.s.SelectedHost = id; a.s.Changed() })})
	}
	if len(hostItems) == 0 {
		hostItems = append(hostItems, &mygo.MenuItem{Label: "No Hosts", Disabled: true})
	}
	hostItems = append(hostItems, mygo.Separator(), &mygo.MenuItem{Label: "Add Host…", Click: click(func() { a.showSettings(paneHosts) })})
	var formatItems []*mygo.MenuItem
	for _, f := range settings.LinkFormats {
		f := f
		formatItems = append(formatItems, &mygo.MenuItem{Label: f.DisplayName(), Type: mygo.MenuItemCheckbox, Checked: f == a.s.LinkFormat,
			Click: click(func() { a.s.LinkFormat = f; a.s.Changed() })})
	}
	items = append(items,
		&mygo.MenuItem{Label: "Upload To", Symbol: "server.rack", Submenu: hostItems},
		&mygo.MenuItem{Label: "Copy As", Symbol: "link", Submenu: formatItems},
		mygo.Separator(),
		&mygo.MenuItem{Label: "Settings…", Symbol: "gearshape", Accelerator: "Cmd+,", Click: click(func() { a.showSettings(paneGeneral) })},
		&mygo.MenuItem{Label: "Quit Pinup", Accelerator: "Cmd+Q", Click: click(mygo.App.Quit)},
	)
	return items
}

func plural(n int, one, many string) string {
	if n == 1 {
		return one
	}
	return many
}

// menuTitle cuts a name short enough to keep the menu narrow, in the
// middle so the extension stays.
func menuTitle(name string, limit int) string {
	if utf8.RuneCountInString(name) <= limit {
		return name
	}
	r := []rune(name)
	tail := (limit - 1) / 2
	return string(r[:limit-1-tail]) + "…" + string(r[len(r)-tail:])
}

// menuSubtitle says when and how big, on one line: "5 minutes ago · 48 KB".
func menuSubtitle(e history.Entry, now time.Time) string {
	return relativeTime(e.Date.Time, now) + " · " + byteCount(e.Size)
}

// relativeTime is how long ago t was, as the system says it.
func relativeTime(t, now time.Time) string {
	d := now.Sub(t)
	switch {
	case d < time.Minute:
		return "Just now"
	case d < time.Hour:
		n := int(d / time.Minute)
		return fmt.Sprintf("%d %s ago", n, plural(n, "minute", "minutes"))
	case d < 24*time.Hour:
		n := int(d / time.Hour)
		return fmt.Sprintf("%d %s ago", n, plural(n, "hour", "hours"))
	}
	days := int(startOfDay(now).Sub(startOfDay(t)).Hours()/24 + 0.5)
	switch {
	case days <= 1:
		return "Yesterday"
	case days < 7:
		return fmt.Sprintf("%d days ago", days)
	case days < 30:
		n := days / 7
		return fmt.Sprintf("%d %s ago", n, plural(n, "week", "weeks"))
	case days < 365:
		n := days / 30
		return fmt.Sprintf("%d %s ago", n, plural(n, "month", "months"))
	}
	n := days / 365
	return fmt.Sprintf("%d %s ago", n, plural(n, "year", "years"))
}

func startOfDay(t time.Time) time.Time {
	y, m, d := t.Local().Date()
	return time.Date(y, m, d, 0, 0, 0, 0, time.Local)
}

// byteCount writes a size as Finder does, in decimal units.
func byteCount(n int64) string {
	switch {
	case n < 1000:
		if n == 1 {
			return "1 byte"
		}
		return fmt.Sprintf("%d bytes", n)
	case n < 1000*1000:
		return fmt.Sprintf("%d KB", (n+500)/1000)
	case n < 1000*1000*1000:
		return trimZero(fmt.Sprintf("%.1f", float64(n)/1e6)) + " MB"
	}
	return trimZero(fmt.Sprintf("%.2f", float64(n)/1e9)) + " GB"
}

func trimZero(s string) string {
	for len(s) > 1 && s[len(s)-1] == '0' && containsDot(s) {
		s = s[:len(s)-1]
	}
	if s[len(s)-1] == '.' {
		s = s[:len(s)-1]
	}
	return s
}

func containsDot(s string) bool {
	for i := range s {
		if s[i] == '.' {
			return true
		}
	}
	return false
}
