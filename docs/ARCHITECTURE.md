# Architecture

Pinup is one Go package (`main`, in `cmd/pinup`) and a few internal packages, drawn by [MyGo](https://github.com/egoist/mygo). Its windows are native UI: views that are Go functions of the app's state, built for every frame. It uses no cgo: the parts of macOS Go has no word for, ImageIO and the preferences system, are called through purego. This page walks through the source by area.

## The main thread

**`app.go`.** The `app` holds every piece of state the windows and the menu show: the settings, the history, the uploader, the windows and the menu bar icon. It is read and changed on the main thread only. Work done elsewhere, an upload, a decoded thumbnail, a file dialog's answer, comes back through `post`, which one goroutine hands to the main thread with `mygo.RunOnMain`, in the order posted, and then redraws the windows. So nothing needs a lock, and a view never sees a half-made change.

**`main.go`.** An accessory app, with no Dock icon, that keeps running with no window. Files opened with Pinup and `pinup://` links wait until the app is ready. Opening Pinup again shows History. A quit while files upload asks first, from `OnBeforeQuit`: Quit When Finished sets the uploader's `OnIdle`, and Quit Now puts the links that already arrived in History and moves screenshots still on their way to the Failed folder.

## The menu bar

**`tray.go`.** The menu is built each time the icon is clicked, as it is at that moment, and shown with `Tray.PopUpMenu`: recent uploads with their thumbnails and age, an Option-alternate that opens each one, the hosts and the link formats. Files dropped on the icon upload. While uploads run, the icon is a ring of their combined progress, then a check or a warning for a moment.

**`icons.go`.** The icon's looks and the menu's thumbnails are drawn with MyGo's painter, offscreen, by `ui.Render`, at twice their size in points, and kept: the ring in steps of 2%. Tiles of files without a thumbnail show the system's icon for their type, asked of an empty file of that extension.

**`hud.go`.** The confirmation under the icon is a flyout of the tray that never takes the keyboard. It stays while the pointer rests on it, and a click opens History or does what its hint says. Where macOS keeps the icon out of a full menu bar, it goes to the top right of the main display.

The menu's icons, subtitles, section headers and alternates, and drops on the icon, come from MyGo's `tray-drop-rich-menu` branch.

## Uploading

**`internal/upload`.** Up to three files upload at once across every batch. Each takes its slot in order, before anything is read, then is prepared, signed and sent on a goroutine of its own. The request body streams from a file, and a reader counts what is sent, for progress at most 30 times a second, and holds off a watchdog that ends an upload after a minute of silence; there is no limit on the whole transfer. A dropped connection, a timeout or a server error is tried once more after a second. A batch's outcome is noted file by file as each finishes, so a quit in the middle loses nothing. A screenshot or a pasted image that fails moves to the Failed folder, where a retry, or the next launch, finds it.

**`internal/hosts`.** A host turns a prepared file into a request and the reply into a link. The S3 provider signs a single `PUT` with AWS Signature Version 4, hashing the file in chunks. The custom provider writes a multipart form, or a JSON object with the file in base64, to a file in the upload's scratch folder, the base64 streamed in so a large file never sits in memory, or sends the file itself.

**`internal/imageproc`, `internal/macos`.** Conversion goes through ImageIO, as the Swift version's did, so its results are the same: JPEG and HEIC at the chosen quality, transparent images kept out of JPEG, animations left alone. Removing the location rewrites a JPEG's metadata without touching its pixels, writes other formats again at full quality, and converts WebP and camera RAW, which ImageIO can't write. The thumbnail comes from ImageIO's thumbnail of the source, so nothing larger is decoded. `internal/macos` registers the C functions of CoreFoundation and ImageIO with purego and reads their constants with `Dlsym`.

**`internal/capture`.** The clipboard gives files copied in Finder, or else an image, kept in its own format when it is PNG, JPEG, GIF, HEIC or WebP, and read as PNG when it is TIFF. A screenshot is `screencapture -i`.

## History and settings

**`internal/history`.** `history.json` is read the first time something asks, and written 300 ms after a change, off the main thread. A generation number keeps an older write from landing on a newer one, as when a delayed save is still encoding as the quit flushes. A file that can't be read is moved aside, never overwritten. A removed upload's thumbnail stays until undo is over, when History closes or Pinup quits. Dates are written to the second in UTC, as the Swift version wrote them, so the file reads in either.

**`internal/settings`.** `settings.json` holds the preferences and the hosts, and `secrets.json`, created with mode 0600, the S3 secret keys and the custom headers, by host. The first launch reads the Swift version's user defaults with `CFPreferencesCopyAppValue`, turns its shortcuts, kept as key codes and modifier flags, into accelerators, and leaves the defaults as they were.

**`history.go`.** History's sections are rows of a virtual list, a day's header and then rows of as many tiles as fit, worked out again only when the entries, the search or the column count change. The headers stay at the top as their days scroll under them. The grid takes the Edit menu's commands and the keys itself: ⌘C, Delete, ⌘A, Return, ⌘Z. Removals are undone from a stack that ends with the window. Thumbnails are decoded on goroutines as tiles show.

**`settings.go`, `recorder.go`.** Every change is saved as it is made. The form edits a copy of the host shown, which is saved when a field changes. The recorder takes the keys while it records, and Pinup's shortcuts are unregistered meanwhile, so they can be recorded again; it stops as it loses the keyboard. Keys come between builds, so a combination pressed is kept for the next build to return.
