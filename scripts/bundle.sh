#!/usr/bin/env bash
# Builds the Swift app, then assembles and ad-hoc signs build/Pinup.app.
# Usage: scripts/bundle.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${PINUP_OUT:-$ROOT/build}"
APP="$OUT/Pinup.app"
BUNDLE_ID="${PINUP_BUNDLE_ID:-dev.sorrycc.pinup}"
VERSION="0.1.0"

echo "==> swift build ($CONFIG)"
swift build --package-path "$ROOT" -c "$CONFIG" -Xlinker -dead_strip
SWIFT_OUT="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SWIFT_OUT/Pinup" "$APP/Contents/MacOS/Pinup"
# Debug builds keep their symbols for the debugger.
[ "$CONFIG" = "release" ] && strip -x "$APP/Contents/MacOS/Pinup"
cp "$ROOT/Resources/Pinup.icns" "$APP/Contents/Resources/Pinup.icns"

# LSUIElement keeps Pinup out of the Dock. The document types let images
# be dropped on the app or opened with it, which uploads them, and the
# pinup:// scheme runs actions from Shortcuts, Raycast or scripts.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Pinup</string>
    <key>CFBundleDisplayName</key><string>Pinup</string>
    <key>CFBundleExecutable</key><string>Pinup</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleIconFile</key><string>Pinup</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
    <key>CFBundleURLTypes</key><array><dict>
        <key>CFBundleURLName</key><string>Pinup actions</string>
        <key>CFBundleURLSchemes</key><array><string>pinup</string></array>
    </dict></array>
    <key>CFBundleDocumentTypes</key><array><dict>
        <key>CFBundleTypeName</key><string>Image</string>
        <key>CFBundleTypeRole</key><string>Viewer</string>
        <key>LSHandlerRank</key><string>Alternate</string>
        <key>LSItemContentTypes</key><array><string>public.image</string></array>
    </dict></array>
</dict>
</plist>
PLIST

echo "==> ad-hoc signing"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "==> done: $APP ($(du -sh "$APP" | cut -f1))"
