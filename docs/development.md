# Development

## Build and test

```sh
go tool mygo build                 # build/darwin-arm64/Pinup.app and a disk image
scripts/dev.sh                     # run with live reload, with data of its own
go test ./...                      # logic, S3 signing, image processing and view tests, in temporary folders
go tool mygo vet                   # go vet, and MyGo's check of native UI build lifetimes
```

The view tests drive the History and Settings windows without a window, with MyGo's `ui.Tester`.

Pinup builds against MyGo's `tray-drop-rich-menu` branch, which adds files dropped on the menu bar icon and the icons, subtitles, section headers and alternates of its menu. `go.mod` points at it with a `replace`.

## Launch flags

```sh
build/darwin-arm64/Pinup.app/Contents/MacOS/Pinup -show hosts
build/darwin-arm64/Pinup.app/Contents/MacOS/Pinup -appearance light -show history
```

| Flag | Values |
|---|---|
| `-show` | `history`, `welcome`, `general`, `hosts` or `shortcuts` opens that window or Settings pane. `menu`, `hud` and `hud-failure` open the menu bar menu or a sample confirmation, for checking the design. |
| `-appearance` | `light` or `dark` |

## Environment variables

| Variable | Effect |
|---|---|
| `PINUP_HOME` | Folder for settings, history, thumbnails and secrets, in place of `~/Library/Application Support/Pinup` |
| `PINUP_BUNDLE_ID` | The user defaults the first launch moves settings over from. Default `dev.sorrycc.pinup.app`, the Swift version's |

```sh
PINUP_HOME=/tmp/pinup-test build/darwin-arm64/Pinup.app/Contents/MacOS/Pinup -show history
```

`scripts/dev.sh` sets `PINUP_HOME` to `~/Library/Application Support/Pinup-dev`, so a development build never touches your everyday Pinup's data.

## Project layout

| Path | Contents |
|---|---|
| `cmd/pinup/` | The app: menu bar icon and menu, HUD, History, Settings, Welcome, shortcut recorder |
| `internal/hosts/` | The S3-compatible and custom HTTP providers |
| `internal/upload/` | The upload queue: three at a time, progress, retries and the Failed folder |
| `internal/imageproc/` | Conversion, location removal and thumbnails, through ImageIO |
| `internal/macos/` | CoreFoundation, ImageIO and the preferences system, called through purego |
| `internal/history/` | `history.json` and its thumbnails |
| `internal/settings/` | `settings.json`, `secrets.json`, and the move from the Swift version's user defaults |
| `internal/capture/` | The clipboard and screenshots |
| `mygo.json` | The app's name, identifier, version, icon, URL scheme and `Info.plist` keys |
| `docs/` | User documentation, and [the architecture](ARCHITECTURE.md) |
