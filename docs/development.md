# Development

## Build and test

```sh
go tool mygo build                 # build/darwin-arm64/Pinup.app and a disk image
scripts/dev.sh                     # run with live reload, with data of its own
go test ./...                      # logic, S3 signing, image processing and view tests, in temporary folders
go tool mygo vet                   # go vet, and MyGo's check of native UI build lifetimes
```

The view tests drive the History and Settings windows without a window, with MyGo's `ui.Tester`.

Pinup builds against MyGo's `tray-drop-rich-menu` branch, which adds files dropped on the menu bar icon and the icons, subtitles, section headers and alternates of its menu. `go.mod` points at that branch's commit on the [sorrycc/mygo](https://github.com/sorrycc/mygo) fork with a `replace`, so the Release workflow can build it. To build against a local checkout instead, use a workspace, which `.gitignore` keeps out of the repository:

```sh
go work init . ../mygo-tray
```

After pushing a new commit of the branch to the fork, move `go.mod` to it with `go mod edit -replace github.com/egoist/mygo=github.com/sorrycc/mygo@<commit> && go mod tidy`.

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

`scripts/dev.sh` builds Pinup as a bare binary in `.mygo/dev`, runs it, and builds and restarts it when a Go file, an asset or `mygo.json` changes; a build that fails keeps the last one running. It passes its arguments to the app, as `scripts/dev.sh -show hosts`, and sets `PINUP_HOME` to `~/Library/Application Support/Pinup-dev`, so a development build never touches your everyday Pinup's data. It runs a bare binary rather than `go tool mygo dev`'s "Pinup Dev" bundle because macOS 26 keeps that bundle's menu bar icon hidden, even with "Allow in the Menu Bar" on. Without a bundle, opening files and `pinup://` links and Open at Login don't reach the development build.

## Releases

```sh
scripts/bump.sh patch      # or minor, major, or a version such as 1.2.0
```

`scripts/bump.sh` sets the version in `mygo.json`, renames `## Unreleased` in `CHANGELOG.md` to the version, commits both as `v<version>` with a tag of the same name, and after asking pushes `main` and the tag. It stops first when `main` isn't clean and in step with `origin/main`, when the tag or release exists, when the changelog has no notes for the version, or when a secret the Release workflow needs isn't set.

The tag starts [the Release workflow](../.github/workflows/release.yml), on a macOS runner. It checks that the tag matches `mygo.json` and the changelog, runs the tests, signs Pinup with the Developer ID, notarizes it, builds it for Apple silicon and Intel, uploads the disk images, update archives, delta updates and update manifests to a draft release whose notes are the version's changelog section, and publishes it. Installed copies read the manifests of the latest release, show the same notes in their update window, and install the update when the user agrees.

The workflow uses these repository secrets:

| Secret | Contents |
|---|---|
| `MACOS_CERTIFICATE` | The Developer ID Application certificate and its key, as a base64 `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | The password of the `.p12` |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | The Apple account, team and app-specific password that notarize |
| `MYGO_UPDATER_PRIVATE_KEY` | The secret key that signs updates, from `go tool mygo keygen` |

Installed copies accept only updates signed with the key whose public half is `updates.publicKey` in `mygo.json`: losing the secret key strands them, so keep a copy outside GitHub.

A failed workflow leaves a draft release. Fix the cause, delete the draft and the tag (`gh release delete v<version> --cleanup-tag`), and tag again, or re-run the workflow when nothing in the repository needs to change.

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
| `mygo.json` | The app's name, identifier, version, icon, URL scheme, update feed and `Info.plist` keys |
| `scripts/` | `dev.sh`, and `bump.sh` and `release-notes.sh` for releases |
| `.github/workflows/` | Tests on pushes and pull requests, and the release of each `v*` tag |
| `docs/` | User documentation, and [the architecture](ARCHITECTURE.md) |
