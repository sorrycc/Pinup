# Usage

## Uploading

| How | What uploads |
|---|---|
| Drop on the menu bar icon | The dropped files |
| Drop on the History window | The dropped files |
| ⌥⇧⌘U | Files copied in Finder, or the image on the clipboard |
| ⌥⇧⌘S | An area or window you select, as with ⇧⌘4 |
| Menu > Upload Files… (⌘O) | Files you choose |
| `open -a Pinup file.png` | The file |

Pinup uploads up to three files at once, in the order you gave them. When a batch finishes, all its links go to the clipboard, one per line, and the menu bar icon shows a check. A confirmation under the icon shows the link and stays open while the pointer is over it.

Links are copied as Markdown, a plain URL or an HTML `<img>` tag. Choose the format in Settings > General.

Screenshots need the Screen Recording permission. macOS asks for it the first time.

## Failed uploads

Pinup retries an upload once after a dropped connection, a timeout or a server error. If it still fails, the icon shows a warning and the confirmation gives the reason. Click the confirmation to try again, or to open Settings when the host needs fixing.

Pinup keeps screenshots and pasted images that failed, even across restarts, until you choose Retry or Discard in the menu.

If you quit while files are uploading, Pinup asks whether to wait. Quitting right away keeps the links that already arrived. Pinup offers any unfinished screenshot or pasted image again at the next launch.

## History

Menu > Show History (⌘Y) lists every past upload, newest first, grouped by day.

| Action | Result |
|---|---|
| Click a tile | Copies its link in the current format |
| Double-click, or Return | Opens the link in your browser |
| Drag a tile out | Drops the link into another app |
| ⌘C | Copies the selected links, one per line |
| Delete | Removes the selection from History; ⌘Z restores it |
| ⌘F | Searches names and links, ignoring case and accents |
| Right-click | Copies as any format, opens, or removes |

Removing an upload only removes it from History. The file stays on its host.

## Data

Pinup stores its data in `~/Library/Application Support/Pinup`:

| File | Contents |
|---|---|
| `history.json` | Up to 2,000 past uploads |
| `Thumbnails/` | One small JPEG or PNG per upload |
| `secrets.json` | Tokens, the S3 secret key and custom headers, readable only by your user |
| `Failed/` | Screenshots and pasted images whose upload failed, until you retry or discard them |

Settings live in the `dev.sorrycc.pinup.app` user defaults.

Secrets are in a file rather than the keychain. macOS revokes an ad-hoc signed app's keychain access on every rebuild and then asks for your login password.
