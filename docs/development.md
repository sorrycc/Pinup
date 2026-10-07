# Development

## Build and test

```sh
scripts/bundle.sh                  # release build of build/Pinup.app
scripts/bundle.sh debug            # debug build
scripts/selftest.sh                # logic, S3 signing and window smoke tests, in a temporary folder
swift scripts/make-icon.swift      # redraw Resources/Pinup.icns
```

## Launch flags

```sh
open build/Pinup.app --args -show hosts
open build/Pinup.app --args -appearance light -show history
```

| Flag | Values |
|---|---|
| `-show` | `history`, `welcome`, `general`, `hosts` or `shortcuts` opens that window or Settings pane. `menu`, `hud` and `hud-failure` open the menu bar menu or a sample confirmation, for checking the design. |
| `-appearance` | `light` or `dark` |

## Environment variables

| Variable | Effect |
|---|---|
| `PINUP_HOME` | Folder for history, thumbnails and secrets, in place of `~/Library/Application Support/Pinup` |
| `PINUP_BUNDLE_ID` | Bundle identifier `scripts/bundle.sh` writes. Default `dev.sorrycc.pinup.app` |
| `PINUP_OUT` | Output folder for `scripts/bundle.sh`. Default `build` |

```sh
PINUP_HOME=/tmp/pinup-test build/Pinup.app/Contents/MacOS/Pinup -show history
```

`PINUP_HOME` doesn't separate settings, which still come from the app's user defaults. For a fully separate copy, build with its own `PINUP_BUNDLE_ID` and `PINUP_OUT`.

## Project layout

| Path | Contents |
|---|---|
| `Sources/Pinup/` | The app: menu bar item, uploader, History, Settings, confirmation HUD |
| `Sources/Pinup/Hosts/` | pic.sorrycc.com, S3-compatible and custom HTTP hosts |
| `Tests/SelfTest.swift` | Checks run by `scripts/selftest.sh` |
| `scripts/bundle.sh` | Builds and assembles `build/Pinup.app` |
| `scripts/make-icon.swift` | Draws the app icon |
| `docs/` | User documentation |
