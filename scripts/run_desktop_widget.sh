#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/.runtime/AIREDesktopWidget.app"
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
BUILD_LOG="$ROOT_DIR/.runtime/swift-widget-build.log"
# Shared per-user scratch dir; matches run_macos_app.sh so both scripts
# reuse the same build products (mode-700 Darwin per-user temp, never a
# shared world-writable path).
USER_TMP="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "$ROOT_DIR/.runtime/")"
# HPC_SWIFTPM_BUILD_DIR overrides; the pre-rename AIRE_SWIFTPM_BUILD_DIR is
# still honoured. Keep this line identical to run_macos_app.sh.
BUILD_DIR="${HPC_SWIFTPM_BUILD_DIR:-${AIRE_SWIFTPM_BUILD_DIR:-${USER_TMP%/}/aire-monitor-build}}"
WIDGET_EXECUTABLE="$BUILD_DIR/debug/AIREDesktopWidget"
mkdir -p "$ROOT_DIR/.runtime"

BUILD_START_TS="$(date +%s)"
set +e
SDKROOT="$SDKROOT" swift build --disable-sandbox --scratch-path "$BUILD_DIR" --jobs 1 --product AIREDesktopWidget >"$BUILD_LOG" 2>&1
BUILD_STATUS=$?
set -e

if [[ $BUILD_STATUS -ne 0 ]]; then
    # Some toolchain/macOS combinations fail the final build.db write-back
    # ("disk I/O error") after a fully successful compile. Accept the build
    # only when the log confirms completion AND the binary is fresh.
    EXEC_MTIME="$(stat -f %m "$WIDGET_EXECUTABLE" 2>/dev/null || echo 0)"
    if grep -q "Build complete!" "$BUILD_LOG" && (( EXEC_MTIME >= BUILD_START_TS - 5 )); then
        echo "warning: swift build exited $BUILD_STATUS but the build completed; continuing with the fresh binary." >&2
    else
        cat "$BUILD_LOG" >&2
        exit "$BUILD_STATUS"
    fi
fi

pkill -f "$MACOS_DIR/AIREDesktopWidget" 2>/dev/null || true

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$WIDGET_EXECUTABLE" "$MACOS_DIR/AIREDesktopWidget"
# The widget covers every cluster, so it carries the neutral Leeds HPC mark
# (header logo) and app icon rather than one cluster's branding.
for asset in LeedsHPCMark.png LeedsHPCMonitor.icns; do
    if [[ -f "$ROOT_DIR/assets/$asset" ]]; then
        cp "$ROOT_DIR/assets/$asset" "$RESOURCES_DIR/$asset"
    fi
done

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
    <string>Leeds HPC Widget</string>
    <key>CFBundleDisplayName</key>
    <string>Leeds HPC Widget</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>LeedsHPCMonitor</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
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
