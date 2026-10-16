# Changelog

## 0.2.0

- Pinup is rewritten in Go with MyGo's native UI. It runs on macOS 14 and
  later, where it needed macOS 26, and builds with `go tool mygo build`.
- The first launch moves your settings, hosts and shortcuts over from the
  Swift version. History, thumbnails, secrets and failed uploads stay where
  they were and keep working.
- Settings are kept in `settings.json` in Pinup's folder, so `PINUP_HOME`
  now gives a copy of Pinup settings of its own too.
- Plain `http://` addresses work for any host, not only `localhost` and IP
  addresses.
- History's day headers stay at the top as their uploads scroll under them.
- Pinup is signed and notarized, and updates itself: it checks for a new
  version once a day and installs it when you agree. Check for Updates… in
  the menu checks now, and Settings > General turns the daily check off.
