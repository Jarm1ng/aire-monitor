#!/usr/bin/env bash
# Builds Leeds HPC Monitor (release) into .runtime/AIREMonitorApp.app and
# opens it.
#
#   scripts/run_macos_app.sh [--debug]
#
# The desktop widget is repackaged from the same build, so its bundle never
# lags the app: the sidebar and menu-bar Widget buttons open
# .runtime/AIREDesktopWidget.app, and a widget left running on an older build
# would not follow the app's current files (it could show stale data, or
# collect for a cluster the app already feeds). A running widget is restarted
# only when its bundle actually changed, and so is the app; see
# scripts/build_bundle.sh for options, signing and environment variables.
set -euo pipefail

exec "${BASH:-/bin/bash}" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build_bundle.sh" \
    --open "$@" AIREMonitorApp AIREDesktopWidget
