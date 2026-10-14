#!/usr/bin/env bash
# Runs every test suite in the repository and prints one summary:
#
#   swift      Swift unit and layout tests (swift-testing), through
#              Tests/AIREMonitorAppTests/run_tests.sh, plus a build of the
#              desktop widget (which the tests do not link). The layout suite
#              hosts real views, so it runs only where a window server exists
#              (a logged-in macOS session or a CI macOS runner) and is
#              skipped, not failed, elsewhere.
#   collector  The collector's unit tests, scripts/tests/test_snapshot.py
#              (local stubs only; `hpc_snapshot.py --self-test` runs the same
#              suite).
#   login      The login-flow harness (scripts/tests/test_login_flow.py): the
#              real login scripts against a fake ssh first on PATH. No
#              network, no ~/.ssh, no real sessions.
#
#   scripts/test_all.sh                 # everything
#   scripts/test_all.sh swift login     # a subset, in this order
#
# Every suite runs even when an earlier one fails; the exit status is
# non-zero if any failed. Each suite has a hard time limit so a hung helper
# can never stall CI. HPC_TEST_BUILD_DIR is passed through to run_tests.sh
# (build scratch directory).
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ALL_SUITES=(swift collector login)
if [[ $# -gt 0 ]]; then
    SUITES=("$@")
else
    SUITES=("${ALL_SUITES[@]}")
fi

PYTHON="${PYTHON:-python3}"
RESULTS=()
FAILED=0

# run_limited <seconds> <command...>: runs the command with SIGALRM after
# <seconds> (macOS has no `timeout`; perl's alarm survives exec).
run_limited() {
    local seconds="$1"
    shift
    perl -e 'alarm shift; exec @ARGV or die "exec failed: $!\n"' "$seconds" "$@"
}

# record <suite> <step> <status>
record() {
    local status="$3"
    if [[ "$status" -eq 0 ]]; then
        RESULTS+=("PASS  $1: $2")
    else
        if [[ "$status" -eq 142 ]]; then
            RESULTS+=("FAIL  $1: $2 (timed out)")
        else
            RESULTS+=("FAIL  $1: $2 (exit $status)")
        fi
        FAILED=1
    fi
}

banner() {
    printf '\n==> %s\n' "$1"
}

run_swift() {
    banner "Swift tests"
    # A cold build (SwiftTerm, the app, the test bundle) takes a few minutes
    # on a CI runner; the tests themselves take seconds.
    run_limited 1800 "$ROOT_DIR/Tests/AIREMonitorAppTests/run_tests.sh"
    record swift "swift test" $?

    # The tests link the app but not the desktop widget, so build the widget
    # product too. Its own scratch directory: run_tests.sh may add
    # Command Line Tools flags that would otherwise force full rebuilds.
    banner "Desktop widget build"
    local user_tmp scratch
    user_tmp="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "$ROOT_DIR/.runtime/")"
    scratch="${HPC_TEST_BUILD_DIR:-${user_tmp%/}/hpc-monitor-tests-build}-widget"
    run_limited 1200 swift build --disable-sandbox --scratch-path "$scratch" --product AIREDesktopWidget
    record swift "swift build --product AIREDesktopWidget" $?
}

run_collector() {
    banner "Collector self-tests"
    # `hpc_snapshot.py --self-test` is only a wrapper around this suite, so
    # running both would run every collector test twice.
    if [[ -f "$ROOT_DIR/scripts/tests/test_snapshot.py" ]]; then
        run_limited 300 "$PYTHON" "$ROOT_DIR/scripts/tests/test_snapshot.py"
        record collector "scripts/tests/test_snapshot.py" $?
    else
        # The collector always had tests; finding none means they were lost.
        RESULTS+=("FAIL  collector: scripts/tests/test_snapshot.py is missing")
        FAILED=1
    fi
}

run_login() {
    banner "Login-flow harness"
    if ! command -v expect >/dev/null 2>&1 || ! command -v zsh >/dev/null 2>&1; then
        RESULTS+=("FAIL  login: expect and zsh are required")
        FAILED=1
        return
    fi
    # The harness bounds every script leg itself (30 s); its 16 scenarios
    # take about 70 s.
    run_limited 600 "$PYTHON" "$ROOT_DIR/scripts/tests/test_login_flow.py"
    record login "scripts/tests/test_login_flow.py" $?
}

for suite in "${SUITES[@]}"; do
    case "$suite" in
        swift) run_swift ;;
        collector) run_collector ;;
        login) run_login ;;
        *)
            echo "Unknown suite '$suite' (expected: ${ALL_SUITES[*]})" >&2
            exit 2
            ;;
    esac
done

banner "Summary"
if [[ ${#RESULTS[@]} -eq 0 ]]; then
    echo "No suites ran."
    exit 1
fi
printf '%s\n' "${RESULTS[@]}"
exit "$FAILED"
