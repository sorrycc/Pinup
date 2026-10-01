<p align="center">
  <img src="Resources/Pinup-1024.png" width="128" height="128" alt="Pinup icon">
</p>

# Pinup

A small macOS menu bar app that uploads images and puts the link on your clipboard. Native Swift and AppKit with no dependencies, in a 600 KB binary.

## Features

- **Menu bar pin.** Drop files on it, or click it for recent uploads, history and settings. While files upload it shows their progress as a ring.
- **Upload from anywhere.** ⌥⇧⌘U uploads the image or files on the clipboard. ⌥⇧⌘S captures part of the screen and uploads it. Both are changeable.
- **Links ready to paste.** Copied as Markdown, a plain URL or an HTML `<img>` tag, with a glass confirmation under the pin.
- **Three kinds of host.** pic.sorrycc.com, any S3-compatible bucket (AWS S3, Cloudflare R2, Aliyun OSS, Tencent COS, MinIO), or any HTTP upload API you describe.
- **Image handling.** Optional conversion to JPEG or HEIC at a chosen quality, and location data removed from photos before they leave the Mac.
- **History.** Every upload with its thumbnail, grouped by day and searchable. Click a tile to copy its link, double-click to open it, drag it into another app. Removing one can be undone.
- **Automation.** `pinup://` links run uploads from Shortcuts, Raycast or scripts.

## Requirements

- macOS 26 or later
- Xcode Command Line Tools with Swift 6.2 or later

## Build and run

```sh
scripts/bundle.sh                         # release build; pass `debug` for a debug build
open build/Pinup.app
open build/Pinup.app --args -show hosts   # open Settings > Hosts at launch
```

The script builds with SwiftPM, writes the Info.plist, and ad-hoc signs `build/Pinup.app`. Move it to /Applications to keep it.

On first launch Pinup shows a welcome window. Choose a host in Settings > Hosts and press Test Upload to check it.

## Uploading

| How | What uploads |
|---|---|
| Drop on the menu bar pin | The dropped files |
| Drop on the History window | The dropped files |
| ⌥⇧⌘U | Files copied in Finder, or else the image on the clipboard |
| ⌥⇧⌘S | An area or window you pick, like ⇧⌘4 |
| Menu > Upload Files… (⌘O) | Files you choose |
| `open -a Pinup file.png` | The file |

Up to three files upload at once. When a batch finishes, all its links go to the clipboard, one per line, and the pin shows a check. A failed upload is retried once after a dropped connection, a timeout or a server error.

When an upload still fails, the pin shows a warning and the confirmation explains why. Clicking it tries again, or opens Settings when the host needs fixing. Screenshots and pasted images that failed are kept, even across restarts, until the menu's Retry or Discard.

Screenshots need the Screen Recording permission, which macOS asks for the first time.

## History

Menu > Show History (⌘Y) opens every past upload, newest first.

| Action | Does |
|---|---|
| Click a tile | Copies its link in the current format |
| Double-click, or Return | Opens the link in your browser |
| Drag a tile out | Drops the link into another app |
| ⌘C | Copies the selected links, one per line |
| Delete | Removes the selection from History; ⌘Z puts it back |
| ⌘F | Searches names and links |
| Right-click | Copy as any format, open, or remove |

Removing an upload only removes it from the list. The file stays on its host.

## Hosts

See [Hosts](docs/hosts.md) for every field, with setups for R2, AWS S3 and common upload APIs.

## Automation

```sh
open "pinup://upload-clipboard"
open "pinup://screenshot"
open "pinup://upload?path=~/Desktop/shot.png"   # repeat path= for more files
open "pinup://retry"                             # retry failed uploads
open "pinup://history"
open "pinup://settings/hosts"                    # or general, shortcuts
```

## Data

Everything lives in `~/Library/Application Support/Pinup`:

| File | Holds |
|---|---|
| `history.json` | Up to 2,000 past uploads |
| `Thumbnails/` | One small JPEG or PNG per upload |
| `secrets.json` | Tokens, S3 secret key and custom headers, readable only by you |
| `Failed/` | Screenshots and pasted images whose upload failed, until retried or discarded |

Settings are in the `dev.sorrycc.pinup` user defaults. Secrets are kept in a file rather than the keychain. An ad-hoc signed app loses keychain access every time it is rebuilt, and macOS then asks for your login password.

## Development

```sh
scripts/selftest.sh                # logic, S3 signing and window smoke tests
swift scripts/make-icon.swift      # redraw Resources/Pinup.icns
open build/Pinup.app --args -appearance light -show history
PINUP_HOME=/tmp/pinup-test build/Pinup.app/Contents/MacOS/Pinup -show history
```

`-show` takes `history`, `welcome`, `general`, `hosts` or `shortcuts`. `-appearance` takes `light` or `dark`. `PINUP_HOME` points the app at another folder for history, thumbnails and secrets. Settings still come from the app's user defaults, so for a fully separate copy build one with its own bundle identifier, which `scripts/bundle.sh` takes from `PINUP_BUNDLE_ID`, and its own output folder from `PINUP_OUT`.

## Project layout

| Path | Description |
|---|---|
| `Sources/Pinup/` | The app: menu bar item, uploader, History, Settings, HUD |
| `Sources/Pinup/Hosts/` | pic.sorrycc.com, S3-compatible and custom HTTP hosts |
| `Tests/SelfTest.swift` | Checks run by `scripts/selftest.sh` |
| `scripts/bundle.sh` | Builds and assembles `build/Pinup.app` |
| `scripts/make-icon.swift` | Draws the app icon |

## License

[MIT](LICENSE)
