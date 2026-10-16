package main

import (
	"fmt"
	"log"
	"os/exec"
	"strings"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"pinup/internal/capture"
	"pinup/internal/history"
	"pinup/internal/hosts"
	"pinup/internal/imageproc"
	"pinup/internal/settings"
	"pinup/internal/upload"
)

// app is Pinup's state. It is read and changed on the main thread only:
// work done off it comes back through post.
type app struct {
	s    *settings.Settings
	hist *history.Store
	up   *upload.Uploader

	tray     *trayIcon
	hud      *hud
	history  *historyWindow
	settings *settingsWindow
	welcome  *welcomeWindow

	// failedShortcuts are the shortcuts another app holds, as menus show
	// them, for Settings to explain.
	failedShortcuts []string
	// recording counts the shortcut recorders recording: Pinup's shortcuts
	// stay unregistered while any is, so they can be recorded again.
	recording int
	// registered are the shortcuts registered, so a change of another
	// setting leaves them be.
	registered *[2]string
	// quitting lets a quit through that the uploads have already been
	// asked about.
	quitting bool
	// appearance is "light" or "dark" from -appearance, for checking the
	// design in both.
	appearance string

	posts chan func()
	// writeClipboard and open put text on the clipboard and open a link;
	// tests replace them.
	writeClipboard func(string)
	open           func(string)
}

func newApp() *app {
	a := &app{posts: make(chan func(), 256), writeClipboard: mygo.Clipboard.WriteText, open: openLink}
	a.s = settings.Load()
	a.hist = &history.Store{}
	a.up = upload.New(a.post)
	a.hud = &hud{a: a}
	// One goroutine brings work back to the main thread, in order.
	go func() {
		for fn := range a.posts {
			mygo.RunOnMain(func() {
				fn()
				a.redraw()
			})
		}
	}()
	return a
}

// post runs fn on the main thread, later, then redraws the windows.
func (a *app) post(fn func()) { a.posts <- fn }

// redraw draws the windows again after a change of the state they show.
func (a *app) redraw() {
	for _, w := range []interface{ window() *mygo.Window }{a.history, a.settings, a.welcome, a.hud} {
		if w != nil {
			if win := w.window(); win != nil {
				win.Invalidate()
			}
		}
	}
}

// theme applies -appearance to a view.
func (a *app) theme(c *ui.Context) {
	switch a.appearance {
	case "light":
		c.SetTheme(ui.LightTheme())
	case "dark":
		c.SetTheme(ui.DarkTheme())
	}
}

// MARK: Actions

func (a *app) uploadFiles() {
	mygo.App.Focus()
	go func() {
		paths, err := mygo.Dialog.Open(mygo.OpenDialogOptions{Title: "Upload Files", ButtonLabel: "Upload", Multiple: true})
		if err != nil || len(paths) == 0 {
			return
		}
		a.post(func() { a.upload(capture.Files(paths)) })
	}()
}

func (a *app) uploadClipboard() {
	go func() {
		sources := capture.Clipboard()
		a.post(func() {
			if len(sources) == 0 {
				a.hud.message("Nothing to upload", "Copy an image or a file first.", iconClipboard)
				return
			}
			a.upload(sources)
		})
	}()
}

func (a *app) captureScreenshot() {
	go func() {
		source, ok := capture.Screenshot()
		if ok {
			a.post(func() { a.upload([]upload.Source{source}) })
		}
	}()
}

// uploadPaths uploads files opened with Pinup or named by a pinup:// link.
func (a *app) uploadPaths(paths []string) {
	var sources []upload.Source
	for _, p := range paths {
		sources = append(sources, upload.NewSource(p))
	}
	a.upload(sources)
}

func (a *app) upload(sources []upload.Source) {
	if len(sources) == 0 {
		return
	}
	opts := imageproc.Options{Conversion: a.s.Conversion, Quality: a.s.Quality, StripLocation: a.s.StripLocation}
	format := a.s.LinkFormat
	if !a.up.Upload(sources, a.s.Host(), opts, func(r upload.Result) { a.batchDone(r, format) }) {
		a.hud.message("Folders can't be uploaded", "Choose the files inside instead.", iconFolder)
	}
}

// batchDone puts a batch's links on the clipboard together, and says how
// it went.
func (a *app) batchDone(r upload.Result, format settings.LinkFormat) {
	a.hist.Add(r.Entries)
	if len(r.Entries) > 0 {
		var links []string
		for _, e := range r.Entries {
			links = append(links, format.Format(e.URL, e.Name))
		}
		a.writeClipboard(strings.Join(links, "\n"))
		if a.s.PlaySound {
			playSound()
		}
	}
	if len(r.Failures) > 0 {
		message := upload.FailureMessage(r.Failures)
		if len(r.Entries) > 0 {
			message = fmt.Sprintf("%d of %d uploaded, links copied. ", len(r.Entries), r.Total) + message
		}
		if hosts.NeedsSettings(r.Failures[0].Err) {
			a.hud.failure(message, "Click to open Settings.", func() { a.showSettings(paneHosts) })
		} else {
			a.hud.failure(message, "Click to try again.", a.retryFailed)
		}
	} else if len(r.Entries) > 0 {
		a.hud.success(r.Entries[len(r.Entries)-1], len(r.Entries), format)
	}
	a.tray.showOutcome(len(r.Failures) == 0)
}

func (a *app) retryFailed() { a.upload(a.up.TakeFailed()) }

func (a *app) discardFailed() { a.up.DiscardFailed() }

// copyEntries copies links in a format, one per line.
func (a *app) copyEntries(entries []history.Entry, format settings.LinkFormat) {
	var links []string
	for _, e := range entries {
		links = append(links, format.Format(e.URL, e.Name))
	}
	if len(links) > 0 {
		a.writeClipboard(strings.Join(links, "\n"))
	}
}

func openLink(url string) {
	if err := mygo.Shell.OpenExternal(url); err != nil {
		log.Println("open:", err)
	}
}

// playSound plays the sound of links copied. MyGo's audio reads no AIFF,
// which the system's sounds are.
func playSound() {
	go exec.Command("/usr/bin/afplay", "/System/Library/Sounds/Pop.aiff").Run()
}

// beep sounds the alert of a refused input.
func beep() {
	if mygo.App.IsReady() {
		mygo.Shell.Beep()
	}
}

// MARK: Shortcuts

// registerShortcuts registers the clipboard and screenshot shortcuts
// again, after a change or once recording ends.
func (a *app) registerShortcuts() {
	if !mygo.App.IsReady() {
		return
	}
	wanted := [2]string{a.s.ClipboardShortcut, a.s.ScreenshotShortcut}
	if a.recording == 0 && a.registered != nil && *a.registered == wanted {
		return
	}
	mygo.GlobalShortcut.UnregisterAll()
	a.failedShortcuts, a.registered = nil, nil
	if a.recording > 0 {
		return
	}
	a.registered = &wanted
	for _, sc := range []struct {
		acc string
		fn  func()
	}{{a.s.ClipboardShortcut, a.uploadClipboard}, {a.s.ScreenshotShortcut, a.captureScreenshot}} {
		if sc.acc == "" {
			continue
		}
		if err := mygo.GlobalShortcut.Register(sc.acc, sc.fn); err != nil {
			log.Printf("shortcut %s: %v", sc.acc, err)
			a.failedShortcuts = append(a.failedShortcuts, settings.ShortcutDisplay(sc.acc))
		}
	}
}

// pauseShortcuts lets a recorder see the combinations Pinup itself holds.
func (a *app) pauseShortcuts(on bool) {
	if on {
		a.recording++
	} else if a.recording > 0 {
		a.recording--
	}
	a.registerShortcuts()
}

// MARK: Quitting

// beforeQuit asks first when files are uploading, so no screenshot or
// finished link is lost without a word.
func (a *app) beforeQuit(e *mygo.QuitEvent) {
	if a.quitting || !a.up.Busy() {
		return
	}
	e.PreventDefault()
	// Asked again while already waiting for the uploads: still waiting.
	if a.up.OnIdle != nil {
		return
	}
	count := max(1, a.up.ActiveCount())
	message := fmt.Sprintf("%d uploads are still in progress.", count)
	detail := "Pinup can quit as soon as they finish. Quitting now stops them, and keeps screenshots and pasted images to try again next time."
	if count == 1 {
		message = "An upload is still in progress."
		detail = "Pinup can quit as soon as it finishes. Quitting now stops it, and keeps screenshots and pasted images to try again next time."
	}
	mygo.App.Focus()
	go func() {
		res, err := mygo.Dialog.Message(mygo.MessageOptions{
			Type: mygo.MessageInfo, Message: message, Detail: detail,
			Buttons: []string{"Quit When Finished", "Quit Now", "Cancel"}, CancelButton: 2,
		})
		if err != nil {
			return
		}
		a.post(func() {
			switch res.Button {
			case 0:
				// They may have finished while the question was up.
				if !a.up.Busy() {
					a.quit()
					return
				}
				a.up.OnIdle = a.quit
			case 1:
				a.hist.Add(a.up.Abandon())
				a.quit()
			}
		})
	}()
}

func (a *app) quit() {
	a.quitting = true
	mygo.App.Quit()
}

// MARK: Windows

// windowClosed hands the menu bar back to the previous app once the last
// window closes. Otherwise an accessory app stays active with nothing on
// screen, and its menus linger over the desktop.
func (a *app) windowClosed() {
	time.AfterFunc(50*time.Millisecond, func() {
		a.post(func() {
			if a.history == nil && a.settings == nil && a.welcome == nil {
				mygo.App.Hide()
			}
		})
	})
}
