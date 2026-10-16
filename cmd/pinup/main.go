// Pinup is a menu bar app that uploads images and copies the link to the
// clipboard, drawn by MyGo's native UI.
package main

import (
	"log"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/plugins/updater"
	"github.com/egoist/mygo/plugins/updater/native"

	"pinup/internal/paths"
)

func main() {
	if !mygo.App.RequestSingleInstanceLock() {
		return // the running Pinup takes over
	}
	a := newApp()
	// Checks GitHub for a new release once a day, and installs it when the
	// user agrees.
	mygo.Use(native.Plugin)
	show := flag("-show")
	a.appearance = flag("-appearance")

	// A menu bar app: no Dock icon, and running with no window.
	mygo.App.SetActivationPolicy(mygo.ActivationPolicyAccessory)
	mygo.App.OnWindowAllClosed(func() {})

	// Files and links that come before the app is ready wait for it.
	var ready bool
	var pending []func()
	whenReady := func(fn func()) {
		if ready {
			fn()
		} else {
			pending = append(pending, fn)
		}
	}
	mygo.App.OnOpenFile(func(path string) { whenReady(func() { a.uploadPaths([]string{path}) }) })
	mygo.App.OnOpenURL(func(raw string) { whenReady(func() { a.handleURL(raw) }) })
	mygo.App.OnSecondInstance(func([]string, string) { whenReady(a.showHistory) })
	// Opening Pinup again while it runs shows History.
	mygo.App.OnActivate(func(hasVisibleWindows bool) {
		if !hasVisibleWindows && ready {
			a.showHistory()
		}
	})
	mygo.App.OnBeforeQuit(a.beforeQuit)
	mygo.App.OnWillQuit(func(*mygo.QuitEvent) { a.hist.Flush() })

	mygo.App.WhenReady(func() {
		a.canUpdate = mygo.Updater.Enabled()
		if a.canUpdate {
			updater.OnChange(a.redraw)
		}
		mygo.App.SetMenu(a.mainMenu())
		a.tray = newTrayIcon(a)
		a.up.OnProgress = func(p float64) {
			if a.up.ActiveCount() > 0 {
				a.tray.showProgress(p)
			}
		}
		a.hist.OnChange = a.redraw
		a.s.OnChange = func() {
			a.registerShortcuts()
			a.redraw()
		}
		a.up.RestoreFailed()
		a.registerShortcuts()
		ready = true
		for _, fn := range pending {
			fn()
		}
		pending = nil
		a.showAtLaunch(show)
	})
	if err := mygo.App.Run(); err != nil {
		log.Fatal(err)
	}
}

// flag is the value after name on the command line, as `-show history`.
func flag(name string) string {
	for i, arg := range os.Args[1:] {
		if arg == name && i+2 < len(os.Args) {
			return strings.ToLower(os.Args[i+2])
		}
	}
	return ""
}

// showAtLaunch opens what -show names, or the welcome window the first
// time.
func (a *app) showAtLaunch(show string) {
	switch show {
	case "history":
		a.showHistory()
	case "welcome":
		a.showWelcome()
	case "general", "hosts", "shortcuts":
		a.showSettings(paneNamed(show))
	case "menu", "hud", "hud-failure":
		// Once the icon has its place in the menu bar.
		time.AfterFunc(600*time.Millisecond, func() { a.post(func() { a.showForDesign(show) }) })
	default:
		if !a.s.Welcomed {
			a.showWelcome()
		}
	}
}

// showForDesign opens the surfaces no window holds, for checking the
// design.
func (a *app) showForDesign(what string) {
	switch what {
	case "menu":
		if !trayShown(tray(a)) {
			log.Printf("the menu bar icon is out of sight, at %+v", tray(a).Bounds())
		}
		a.tray.openMenu()
	case "hud":
		if entries := a.hist.Entries(); len(entries) > 0 {
			a.hud.success(entries[0], 1, a.s.LinkFormat)
		} else {
			a.hud.message("Nothing to upload", "Copy an image or a file first.", iconClipboard)
		}
	default:
		a.hud.failure("Screenshot.png: The server answered 401 Unauthorized.", "Click to open Settings.", nil)
	}
}

// handleURL runs pinup://upload-clipboard, pinup://screenshot,
// pinup://upload?path=<file>, pinup://retry, pinup://history and
// pinup://settings[/pane], for Shortcuts, Raycast and scripts.
func (a *app) handleURL(raw string) {
	u, err := url.Parse(raw)
	if err != nil || !strings.EqualFold(u.Scheme, "pinup") {
		return
	}
	switch strings.ToLower(u.Host) {
	case "upload-clipboard":
		a.uploadClipboard()
	case "screenshot":
		a.captureScreenshot()
	case "history":
		a.showHistory()
	case "retry":
		a.retryFailed()
	case "upload":
		var files []string
		for _, p := range u.Query()["path"] {
			files = append(files, paths.ExpandTilde(p))
		}
		a.uploadPaths(files)
	case "settings":
		a.showSettings(paneNamed(strings.ToLower(strings.Trim(u.Path, "/"))))
	default:
		mygo.Shell.Beep()
	}
}

// mainMenu is the menu bar shown while a Pinup window is in front. Edit
// is there so copy and paste work in Settings fields.
func (a *app) mainMenu() *mygo.Menu {
	appItems := []*mygo.MenuItem{{Label: "About Pinup", Click: click(a.showAbout)}}
	if a.canUpdate {
		appItems = append(appItems, updater.MenuItem())
	}
	appItems = append(appItems,
		mygo.Separator(),
		&mygo.MenuItem{Label: "Settings…", Accelerator: "Cmd+,", Click: click(func() { a.showSettings(paneGeneral) })},
		mygo.Separator(),
		&mygo.MenuItem{Role: mygo.RoleHide},
		&mygo.MenuItem{Label: "Quit Pinup", Accelerator: "Cmd+Q", Click: click(mygo.App.Quit)},
	)
	return mygo.NewMenu([]*mygo.MenuItem{
		{Label: "Pinup", Submenu: appItems},
		{Label: "File", Submenu: []*mygo.MenuItem{
			{Label: "Upload Files…", Accelerator: "Cmd+O", Click: click(a.uploadFiles)},
			{Label: "Upload from Clipboard", Click: click(a.uploadClipboard)},
			{Label: "Capture Screenshot", Click: click(a.captureScreenshot)},
			mygo.Separator(),
			{Label: "Show History", Accelerator: "Cmd+Y", Click: click(a.showHistory)},
			{Role: mygo.RoleClose},
		}},
		{Label: "Edit", Submenu: []*mygo.MenuItem{
			{Role: mygo.RoleUndo},
			{Role: mygo.RoleRedo},
			mygo.Separator(),
			{Role: mygo.RoleCut},
			{Role: mygo.RoleCopy},
			{Role: mygo.RolePaste},
			{Role: mygo.RoleDelete},
			{Role: mygo.RoleSelectAll},
			mygo.Separator(),
			{Label: "Find", Accelerator: "Cmd+F", Click: click(a.find)},
		}},
		{Role: mygo.RoleWindowMenu},
	})
}

func (a *app) showAbout() {
	mygo.App.Focus()
	mygo.App.ShowAboutPanel(mygo.AboutPanelOptions{
		ApplicationName: "Pinup",
		Credits:         "Upload images from the menu bar and paste the link anywhere.\nNative UI drawn by MyGo.",
	})
}
