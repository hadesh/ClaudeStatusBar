#!/usr/bin/env bash
# Build ClaudeStatusBar.app and a distributable zip into ./dist/.
# Override version with: VERSION=0.3.0 ./scripts/package.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.3.0}"
BUNDLE_ID="com.hadesh.ClaudeStatusBar"
APP_NAME="ClaudeStatusBar"
DISPLAY_NAME="Claude Status Bar"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "==> Cleaning previous release build (avoids stale .o files for deleted sources)"
swift package clean

echo "==> Building universal release binaries (arm64 + x86_64)"
# Note: do NOT pass --product flags here. After `swift package clean`, scoping
# the build to specific products silently skipped the main `ClaudeStatusBar`
# target on this Swift version (5.9, Xcode 26). Building all products works.
swift build -c release --arch arm64 --arch x86_64

BIN="$ROOT/.build/apple/Products/Release/$APP_NAME"
HOOK_BIN="$ROOT/.build/apple/Products/Release/${APP_NAME}Hook"
for f in "$BIN" "$HOOK_BIN"; do
  if [[ ! -x "$f" ]]; then
    echo "Binary not found at $f" >&2
    exit 1
  fi
done

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$HOOK_BIN" "$APP/Contents/MacOS/${APP_NAME}Hook"
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Hades. MIT License.</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP"

echo "==> Zipping"
cd "$DIST"
ZIP="$APP_NAME-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP_NAME.app" "$ZIP"

cat <<EOF

Done.
  App:  $APP
  Zip:  $DIST/$ZIP
EOF
