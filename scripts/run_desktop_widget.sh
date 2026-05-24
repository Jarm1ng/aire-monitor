#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/.runtime/AIREDesktopWidget.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"

SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}"
BUILD_LOG="$ROOT_DIR/.runtime/swift-widget-build.log"
mkdir -p "$ROOT_DIR/.runtime"

set +e
SDKROOT="$SDKROOT" swift build --disable-sandbox --jobs 1 --product AIREDesktopWidget >"$BUILD_LOG" 2>&1
BUILD_STATUS=$?
set -e

if [[ $BUILD_STATUS -ne 0 ]]; then
    if [[ -x "$ROOT_DIR/.build/debug/AIREDesktopWidget" ]] && grep -Eq "Build complete|Build of product 'AIREDesktopWidget' complete" "$BUILD_LOG"; then
        echo "swift build returned $BUILD_STATUS after producing the executable; continuing."
        echo "Build log: $BUILD_LOG"
    else
        cat "$BUILD_LOG" >&2
        exit "$BUILD_STATUS"
    fi
fi

pkill -f "$MACOS_DIR/AIREDesktopWidget" 2>/dev/null || true

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$ROOT_DIR/.build/debug/AIREDesktopWidget" "$MACOS_DIR/AIREDesktopWidget"
if [[ -f "$ROOT_DIR/assets/AIRELogo.png" ]]; then
    cp "$ROOT_DIR/assets/AIRELogo.png" "$RESOURCES_DIR/AIRELogo.png"
fi
if [[ -f "$ROOT_DIR/assets/AIREMonitor.icns" ]]; then
    cp "$ROOT_DIR/assets/AIREMonitor.icns" "$RESOURCES_DIR/AIREMonitor.icns"
fi

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AIREDesktopWidget</string>
    <key>CFBundleIdentifier</key>
    <string>local.aire.desktop-widget</string>
    <key>CFBundleName</key>
    <string>AIRE Desktop Widget</string>
    <key>CFBundleDisplayName</key>
    <string>AIRE Desktop Widget</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AIREMonitor</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

open "$APP_DIR"
