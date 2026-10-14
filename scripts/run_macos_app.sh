#!/usr/bin/env bash
# Builds Leeds HPC Monitor (release) and opens it: for development.
#
#   scripts/run_macos_app.sh [--debug]
#
# Without an install, the app is built into .runtime/AIREMonitorApp.app and
# opened from there. Once scripts/install_app.sh has installed it (in
# /Applications, say), this updates that copy instead, through
# install_app.sh, and opens it: the installed app is the only one that is
# launched, so LaunchServices never has two copies to choose from.
#
# The desktop widget is repackaged from the same build, so its bundle never
# lags the app: the sidebar and menu-bar Widget buttons open
# .runtime/AIREDesktopWidget.app, and a widget left running on an older build
# would not follow the app's current files (it could show stale data, or
# collect for a cluster the app already feeds). A running widget is restarted
# only when its bundle actually changed. A running app is replaced only when
# its bundle changed: from .runtime/ it is restarted on the new build; an
# installed one is asked to quit first (see install_app.sh). See
# scripts/build_bundle.sh for options, signing and environment variables.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if "${BASH:-/bin/bash}" "$SCRIPT_DIR/install_app.sh" --installed-path >/dev/null 2>&1; then
    exec "${BASH:-/bin/bash}" "$SCRIPT_DIR/install_app.sh" "$@"
fi
exec "${BASH:-/bin/bash}" "$SCRIPT_DIR/build_bundle.sh" --open "$@" AIREMonitorApp AIREDesktopWidget
