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
#   desktop    The Windows and Linux app's pytest suite (desktop/tests). With
#              PySide6 and Paramiko installed it runs in full; without them
#              (a Mac, usually) only the standard-library tests run, and the
#              Qt and SSH modules are reported as SKIP, never as PASS. The
#              full suite always runs in .github/workflows/windows.yml and
#              linux.yml. HPC_DESKTOP_PYTHON picks the interpreter (a path
#              from the repository root, or a command on PATH), e.g. a venv
#              with desktop/requirements-dev.txt; otherwise the first of
#              .venv/bin/python and python3 that is Python 3.11+ with pytest.
#
#   scripts/test_all.sh                 # everything
#   scripts/test_all.sh swift login     # a subset, in this order
#
# Every suite runs even when an earlier one fails; the exit status is
# non-zero if any failed (a SKIP is not a failure). Each suite has a hard
# time limit so a hung helper can never stall CI. HPC_TEST_BUILD_DIR is
# passed through to run_tests.sh (build scratch directory).
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ALL_SUITES=(swift collector login desktop)
if [[ $# -gt 0 ]]; then
    SUITES=("$@")
else
    SUITES=("${ALL_SUITES[@]}")
fi

# Apple's /usr/bin/python3 when there is one: the interpreter the app itself
# runs the collector with, and one that keeps argv[0] across exec. Homebrew's
# framework Python relaunches through Python.app and replaces argv[0], so the
# login harness's fake ssh would no longer look like ssh in ps.
if [[ -z "${PYTHON:-}" ]]; then
    if [[ -x /usr/bin/python3 ]]; then
        PYTHON=/usr/bin/python3
    else
        PYTHON=python3
    fi
fi
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
    # HPC_SWIFT_TEST_ARGS goes to swift test, e.g. --no-parallel on a CI
    # runner with few cores, where tests that wait on child processes would
    # otherwise starve the shared thread pool and make time-limited tests
    # fail for no reason of their own.
    # shellcheck disable=SC2086
    run_limited 1800 "$ROOT_DIR/Tests/AIREMonitorAppTests/run_tests.sh" ${HPC_SWIFT_TEST_ARGS:-}
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

# desktop_python_ok <python>: whether it can run the desktop suite: the
# app's floor (Python 3.11, desktop/pyproject.toml) and pytest.
desktop_python_ok() {
    "$1" -c 'import sys, pytest; sys.exit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1
}

run_desktop() {
    banner "Desktop app tests"
    local py="" candidate
    if [[ -n "${HPC_DESKTOP_PYTHON:-}" ]]; then
        # Asked for by name, so an unusable one is a failure, not a skip.
        if ! desktop_python_ok "$HPC_DESKTOP_PYTHON"; then
            RESULTS+=("FAIL  desktop: HPC_DESKTOP_PYTHON ($HPC_DESKTOP_PYTHON) is not Python 3.11+ with pytest")
            FAILED=1
            return
        fi
        py="$HPC_DESKTOP_PYTHON"
    else
        for candidate in "$ROOT_DIR/.venv/bin/python" python3; do
            if desktop_python_ok "$candidate"; then
                py="$candidate"
                break
            fi
        done
    fi
    if [[ -z "$py" ]]; then
        RESULTS+=("SKIP  desktop: no Python 3.11+ with pytest (set HPC_DESKTOP_PYTHON to a venv with desktop/requirements-dev.txt)")
        return
    fi

    # desktop/tests/conftest.py decides which modules need PySide6 or
    # Paramiko and leaves them out when those are missing; ask it, so this
    # report and the run cannot disagree. LEEDS_HPC_FULL_TESTS (CI's switch
    # that turns a missing package into an error) is unset for the question.
    local info missing left_out
    if ! info="$(env -u LEEDS_HPC_FULL_TESTS "$py" -B -c 'import sys; sys.path.insert(0, "desktop/tests")
import conftest
print(" ".join(conftest.MISSING))
print(" ".join(conftest.collect_ignore))')"; then
        RESULTS+=("FAIL  desktop: could not read desktop/tests/conftest.py with $py")
        FAILED=1
        return
    fi
    { read -r missing; read -r left_out; } <<<"$info"

    # -p no:cacheprovider and -B: nothing written into the checkout.
    local pytest_args=(-B -m pytest -q -p no:cacheprovider -c "$ROOT_DIR/desktop/pyproject.toml" "$ROOT_DIR/desktop/tests")
    if [[ -z "$left_out" ]]; then
        # Everything installed: the full suite, as strict as CI.
        run_limited 900 env LEEDS_HPC_FULL_TESTS=1 "$py" "${pytest_args[@]}"
        record desktop "pytest desktop/tests ($py)" $?
    else
        run_limited 900 env -u LEEDS_HPC_FULL_TESTS "$py" "${pytest_args[@]}"
        record desktop "pytest desktop/tests, standard-library tests only ($py)" $?
        RESULTS+=("SKIP  desktop: ${left_out// /, } (needs ${missing// /, }; set HPC_DESKTOP_PYTHON to a venv with desktop/requirements-dev.txt)")
    fi
}

for suite in "${SUITES[@]}"; do
    case "$suite" in
        swift) run_swift ;;
        collector) run_collector ;;
        login) run_login ;;
        desktop) run_desktop ;;
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
