# Changelog

## 0.3.0

- **Settings → General → Compress images** shrinks JPEG and HEIC uploads at the Quality you set.
- Compressed PNGs drop to 256 colors and keep their transparency and color profile.
- A file that compressing wouldn't make smaller uploads as it is.

## 0.2.0

- Pinup runs on macOS 14 and later, where it needed macOS 26.
- The first launch brings over your settings, hosts and shortcuts from the previous version.
- History, thumbnails, secrets and failed uploads from the previous version keep working.
- Settings live in `settings.json`, so `PINUP_HOME` gives a separate copy of them too.
- Plain `http://` addresses work for any host, not only `localhost` and IP addresses.
- History's day headers stay at the top as their uploads scroll under them.
- Pinup is signed and notarized, so macOS opens it without a warning.
- Pinup checks for a new version once a day and installs it when you agree.
- **Check for Updates…** in the menu checks for a new version now.
- **Settings → General** turns the daily update check off.
