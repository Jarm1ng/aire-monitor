#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/.runtime/AIREMonitorApp.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"

# Prefer the pinned CLT SDK when present; otherwise ask xcrun so the script
# works on machines with a different SDK version installed.
PINNED_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ -z "${SDKROOT:-}" ]]; then
    if [[ -d "$PINNED_SDK" ]]; then
        SDKROOT="$PINNED_SDK"
    else
        SDKROOT="$(xcrun --show-sdk-path --sdk macosx)"
    fi
fi
BUILD_LOG="$ROOT_DIR/.runtime/swift-build.log"
# Build into the per-user Darwin temp dir (mode 700, never shared or
# world-writable). Some backup/sync tools watching the project volume break
# llbuild's SQLite database mid-build; the per-user temp volume is immune.
USER_TMP="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "$ROOT_DIR/.runtime/")"
BUILD_DIR="${AIRE_SWIFTPM_BUILD_DIR:-${USER_TMP%/}/aire-monitor-build}"
APP_EXECUTABLE="$BUILD_DIR/debug/AIREMonitorApp"
mkdir -p "$ROOT_DIR/.runtime"

BUILD_START_TS="$(date +%s)"
set +e
SDKROOT="$SDKROOT" swift build --disable-sandbox --scratch-path "$BUILD_DIR" --jobs 1 >"$BUILD_LOG" 2>&1
BUILD_STATUS=$?
set -e

if [[ $BUILD_STATUS -ne 0 ]]; then
    # Some toolchain/macOS combinations fail the final build.db write-back
    # ("disk I/O error") after a fully successful compile. Accept the build
    # only when the log confirms completion AND the binary is fresh.
    EXEC_MTIME="$(stat -f %m "$APP_EXECUTABLE" 2>/dev/null || echo 0)"
    if grep -q "Build complete!" "$BUILD_LOG" && (( EXEC_MTIME >= BUILD_START_TS - 5 )); then
        echo "warning: swift build exited $BUILD_STATUS but the build completed; continuing with the fresh binary." >&2
    else
        cat "$BUILD_LOG" >&2
        exit "$BUILD_STATUS"
    fi
fi

pkill -f "$MACOS_DIR/AIREMonitorApp" 2>/dev/null || true

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$APP_EXECUTABLE" "$MACOS_DIR/AIREMonitorApp"
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
    <string>AIREMonitorApp</string>
    <key>CFBundleIdentifier</key>
    <string>local.aire.monitor</string>
    <key>CFBundleName</key>
    <string>AIRE Monitor</string>
    <key>CFBundleDisplayName</key>
    <string>AIRE Monitor</string>
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
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

if ! open "$APP_DIR"; then
    echo "macOS open failed; launching the app executable directly."
    "$MACOS_DIR/AIREMonitorApp" >/dev/null 2>&1 &
fi
