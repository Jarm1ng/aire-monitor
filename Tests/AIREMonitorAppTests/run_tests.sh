#!/usr/bin/env bash
# Runs the unit tests (swift-testing). Extra arguments are passed through to
# `swift test`, e.g. `--filter PreferencesStore`.
#
# Why a wrapper: on a Command Line Tools-only Mac, SwiftPM puts the CLT's
# Library/Developer/Frameworks directory on the -I/-L paths, but Testing ships
# there as a *framework*, which only -F finds. Without -F the test target
# fails with "no such module 'Testing'", and SwiftPM's generated test runner
# compiles its swift-testing entry point out (`#if canImport(Testing)`), so a
# run would "pass" with zero tests. Target settings in Package.swift cannot
# reach that generated runner, so -F is passed here for every module. With
# Xcode selected SwiftPM already does this and the wrapper adds nothing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

# Build outside the project volume (see scripts/run_macos_app.sh: sync tools
# watching the project can break llbuild's database mid-build).
USER_TMP="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "$ROOT_DIR/.runtime/")"
SCRATCH_DIR="${HPC_TEST_BUILD_DIR:-${USER_TMP%/}/hpc-monitor-tests-build}"

ARGS=(--disable-sandbox --scratch-path "$SCRATCH_DIR")

CLT_DIR="/Library/Developer/CommandLineTools"
CLT_FRAMEWORKS="$CLT_DIR/Library/Developer/Frameworks"
DEVELOPER_DIR_ACTIVE="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
if [[ "$DEVELOPER_DIR_ACTIVE" == "$CLT_DIR"* && -d "$CLT_FRAMEWORKS/Testing.framework" ]]; then
    # -F to compile and link against Testing.framework; the rpath so the
    # test bundle can load it at run time (@rpath/Testing.framework/...).
    ARGS+=(-Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS" -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS")
fi

exec swift test "${ARGS[@]}" "$@"
