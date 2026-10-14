#!/usr/bin/env bash
# Builds the Leeds HPC desktop widget (release) into
# .runtime/AIREDesktopWidget.app and opens it. The app's Widget buttons run
# this script; when the bundle is already current it only opens (or brings
# forward) the widget, without rebuilding or restarting it.
#
#   scripts/run_desktop_widget.sh [--debug]
#
# The build log is .runtime/swift-widget-build.log. See
# scripts/build_bundle.sh for options, signing and environment variables.
set -euo pipefail

exec "${BASH:-/bin/bash}" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build_bundle.sh" \
    --open "$@" AIREDesktopWidget
