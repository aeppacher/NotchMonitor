#!/bin/bash
# Build ClaudeNotch.app — an unsigned macOS .app bundle ready to share.
#
# Output: dist/ClaudeNotch.app  and  dist/ClaudeNotch.zip
#
# Recipients: right-click the .app → Open (Gatekeeper will warn the first time
# because the bundle is ad-hoc signed, not notarized). Subsequent launches
# work normally.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ClaudeNotch"
BUNDLE_ID="com.eppacher.claudenotch"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

DIST="dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "==> Generating app icon"
swiftc -O scripts/make-icon.swift -o /tmp/claude-notch-make-icon
mkdir -p resources
/tmp/claude-notch-make-icon

echo "==> Building release binary"
swift build -c release

BIN_PATH=$(swift build -c release --show-bin-path)
EXEC="$BIN_PATH/$APP_NAME"
if [ ! -x "$EXEC" ]; then
  echo "Binary not found at $EXEC" >&2
  exit 1
fi

echo "==> Assembling .app bundle"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$EXEC" "$MACOS/$APP_NAME"
cp resources/AppIcon.icns "$RES/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>Claude Notch</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <!-- LSUIElement=true: no Dock icon, no menu bar app menu — pure HUD. -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Eppacher</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc codesign (so Gatekeeper doesn't flag the binary as damaged)"
# `-s -` is ad-hoc signing — no Developer ID, but it satisfies the
# "code signature required" check. Recipients still see the "unverified
# developer" warning on first launch (right-click → Open).
codesign --force --deep --sign - "$APP"

echo "==> Stripping quarantine attributes"
# Clear any com.apple.quarantine attributes on the bundle before zipping.
# (Browsers re-apply this on download regardless, so this mostly cleans up
# attributes that may have been inherited from previous builds.)
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo "==> Zipping for distribution"
ZIP="$DIST/$APP_NAME.zip"
rm -f "$ZIP"
# `ditto -c -k --keepParent` produces a Finder-friendly zip.
ditto -c -k --keepParent "$APP" "$ZIP"

SIZE=$(du -h "$ZIP" | cut -f1)
echo
echo "Done."
echo "  App:  $APP"
echo "  Zip:  $ZIP  ($SIZE)"
echo
echo "To share: send the zip. After download, recipients should run:"
echo "    xattr -dr com.apple.quarantine /Applications/ClaudeNotch.app"
echo "    open /Applications/ClaudeNotch.app"
echo "(One-time setup — clears the browser-added quarantine flag so macOS"
echo "doesn't refuse to launch the unsigned bundle.)"
