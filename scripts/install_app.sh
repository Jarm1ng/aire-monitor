#!/usr/bin/env bash
# Installs Leeds HPC Monitor like a normal Mac app: builds the release
# bundles with scripts/build_bundle.sh, copies the app to
# "/Applications/Leeds HPC Monitor.app", registers it with LaunchServices and
# opens it. Launchpad, Spotlight, the Dock and notification clicks then all
# start that copy. The app still works out of this checkout (the helpers in
# scripts/ and the state in .runtime/), which its Info.plist names, so keep
# the checkout where it is; the desktop widget stays in .runtime/.
#
#   scripts/install_app.sh [--debug] [--skip-build] [--no-open] [--force]
#   scripts/install_app.sh --uninstall [--force]
#   scripts/install_app.sh --installed-path
#
#   --debug           Build and install the debug configuration.
#   --skip-build      Install the bundle already in .runtime/ (no swift build).
#   --no-open         Do not open the app afterwards, nor reopen one this run
#                     quit when a later step fails (HPC_INSTALL_NO_OPEN=1 does
#                     the same).
#   --force           Stop a copy that does not quit when asked with SIGTERM.
#                     That skips the app's quit confirmation, so its terminal
#                     sessions and file transfers end.
#   --uninstall       Remove the installed app (after the same quit rule),
#                     unregister it from LaunchServices and forget it. One
#                     this account cannot delete (locked, an ACL, a folder
#                     inside that is read-only) is left as it is.
#   --installed-path  Print the installed app's path and exit 0, or exit 1
#                     when it is not installed. The other scripts use this.
#
# Where it goes: HPC_INSTALL_DIR when set; otherwise the folder of the
# existing install; otherwise /Applications, or ~/Applications (created) when
# /Applications is not writable for this account. Nothing runs with sudo. The
# folder is resolved to its real path (symbolic links followed, names spelled
# as stored), so "/applications" or a link to the folder is the same install,
# never a second one. The location is recorded in .runtime/installed_app_path;
# from then on scripts/run_macos_app.sh updates and opens the installed copy
# instead of .runtime/AIREMonitorApp.app, and LaunchServices forgets the
# .runtime copy so the two never compete.
#
# The bundle identifier stays local.aire.monitor, so the notification
# permission, the saved Keychain password and the preferences carry over.
# The copy is staged next to its destination, its signature verified, and
# only then swapped in. An unchanged install is left alone (and only brought
# forward). A copy that is running and has to be replaced, or one running
# from .runtime/, is asked to quit the normal way, so its own confirmation
# protects running terminals and transfers; if it is still running after
# HPC_INSTALL_QUIT_TIMEOUT seconds, the script stops (exit 3) unless --force
# was given. A running copy is recognised by the executable the kernel runs
# it from (device and inode, or the path word for word for a bundle replaced
# since), so one started through a symbolic link (to the bundle, a folder or
# the executable itself) or under another spelling of the path counts too,
# while a process that only reads or maps the file does not. A copy running
# from .runtime/ is asked before the build, which replaces that bundle, so a
# refusal leaves it running on its own, still-registered bundle. Write
# access is checked before anything is asked to quit. When a later step
# fails, the previous install is put back (or, if that fails too, kept in
# the staging folder, never deleted) and the app that was quit is opened
# again. --uninstall likewise moves the install into a staging folder
# before it unregisters or deletes anything. Staging folders a killed run
# left behind are removed at the start (and by --uninstall); one whose run
# is still going, say from another checkout installing into the same
# folder, is left alone. Every bundle the script deletes is unregistered
# first, and the .runtime copy is unregistered last, once nothing runs from
# it, so LaunchServices ends up knowing only the installed copy. Processes
# and file permissions are checked by /usr/bin/python3, which the app's
# collector runs on as well.
#
# Environment:
#   HPC_INSTALL_DIR           Install folder (created when missing).
#   HPC_INSTALL_NO_OPEN       1: do not open the app afterwards.
#   HPC_INSTALL_QUIT_TIMEOUT  Seconds a running copy gets to quit (default 120).
#   HPC_INSTALL_LOCK_TIMEOUT  Seconds to wait for another install of this
#                             checkout (default 1500).
#   HPC_INSTALL_DEFAULT_DIR   The default folder in place of /Applications
#                             (tests use a temp folder).
#   HPC_LSREGISTER            The lsregister tool to call (tests use a stub).
#   Building honours scripts/build_bundle.sh's variables (signing identity,
#   build directory, jobs, log).
#
# Exit status: 0 success; 1 error; 2 bad usage; 3 a running copy did not
# quit; 75 another install of this checkout held the lock for too long (or,
# from build_bundle.sh, another build of it did); build_bundle.sh's status
# when the build fails.
set -euo pipefail

# A path's real spelling: symbolic links resolved and every name as it is
# stored, so on a case-insensitive volume "/applications" reads
# "/Applications". /bin/realpath (macOS 13 and later) does both; the fallback
# `cd -P` resolves only the links. Status 1 when the path does not exist.
canonical_path() {
    if [[ -x /bin/realpath ]] && /bin/realpath "$1" 2>/dev/null; then
        return 0
    fi
    (CDPATH='' cd -P "$1" 2>/dev/null && pwd -P)
}

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
ROOT_DIR="$(canonical_path "$SCRIPT_DIR/..")"
RUNTIME_DIR="$ROOT_DIR/.runtime"
RECORD="$RUNTIME_DIR/installed_app_path"

# Must match scripts/build_bundle.sh (load_product) and HPCCore
# (WidgetAppLauncher.appBundleIdentifier, AppInstallRecord).
BUNDLE_ID="local.aire.monitor"
EXECUTABLE="AIREMonitorApp"
APP_NAME="Leeds HPC Monitor"
SOURCE_BUNDLE="$RUNTIME_DIR/$EXECUTABLE.app"
DEFAULT_INSTALL_DIR="${HPC_INSTALL_DEFAULT_DIR:-/Applications}"
LSREGISTER="${HPC_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
# Longer than build_bundle.sh's own lock timeout, since the build runs
# inside this lock.
LOCK_TIMEOUT_SECONDS="${HPC_INSTALL_LOCK_TIMEOUT:-1500}"
# The marker the waiting script hands the locked one (see Main).
LOCK_MARKER_PREFIX="$RUNTIME_DIR/.install_app.waiting."
# Staging folders: "<prefix><pid>.<random>", next to the install.
STAGING_PREFIX=".$APP_NAME.install."
EXIT_STILL_RUNNING=3
# After --force's SIGTERM.
TERM_GRACE_SECONDS=10
# How long the .runtime copy may take to finish exiting before it is
# unregistered at the end.
SOURCE_EXIT_SECONDS=5

usage() {
    sed -n '2,/^set -euo pipefail$/p' "$SCRIPT_PATH" | sed -e '$d' -e 's/^# \{0,1\}//'
}

die() {
    echo "error: $*" >&2
    exit 1
}

usage_error() {
    echo "error: $* (see --help)" >&2
    exit 2
}

# --- Bundles --------------------------------------------------------------

plist_value() {
    plutil -extract "$2" raw -o - "$1/Contents/Info.plist" 2>/dev/null || true
}

# True when the path is a bundle directory with the app's identifier.
is_app_bundle() {
    [[ -d "$1" && -f "$1/Contents/Info.plist" && "$(plist_value "$1" CFBundleIdentifier)" == "$BUNDLE_ID" ]]
}

# The path the record names, printed when it is an absolute "<...>.app"
# path, whether or not it still holds the app; status 1 otherwise.
recorded_path() {
    local path=""
    [[ -f "$RECORD" ]] || return 1
    IFS= read -r path <"$RECORD" || [[ -n "$path" ]] || return 1
    [[ "$path" == /*.app ]] || return 1
    printf '%s\n' "$path"
}

# The recorded install, printed when the record names an absolute
# "<...>.app" path that still holds the app; status 1 otherwise. HPCCore's
# AppInstallRecord applies the same rule for the widget.
recorded_install() {
    local path
    path="$(recorded_path)" || return 1
    is_app_bundle "$path" || return 1
    printf '%s\n' "$path"
}

write_record() {
    local temporary
    temporary="$(mktemp "$RUNTIME_DIR/.installed_app_path.XXXXXX")"
    printf '%s\n' "$1" >"$temporary"
    mv -f "$temporary" "$RECORD"
}

# Equal stamps (scripts/build_bundle.sh's content hash) and byte-identical
# executable and Info.plist: the installed copy is this bundle already. A
# bundle signed ad hoc after its certificate failed carries no real stamp,
# so it never counts as current.
install_is_current() {
    local target="$1" stamp
    is_app_bundle "$target" || return 1
    stamp="$(plist_value "$SOURCE_BUNDLE" HPCBuildStamp)"
    [[ -n "$stamp" && "$stamp" != "ad-hoc-fallback" ]] || return 1
    [[ "$(plist_value "$target" HPCBuildStamp)" == "$stamp" ]] || return 1
    cmp -s "$SOURCE_BUNDLE/Contents/MacOS/$EXECUTABLE" "$target/Contents/MacOS/$EXECUTABLE" || return 1
    cmp -s "$SOURCE_BUNDLE/Contents/Info.plist" "$target/Contents/Info.plist" || return 1
    codesign --verify --strict "$target" >/dev/null 2>&1
}

lsregister() {
    "$LSREGISTER" "$@" >/dev/null 2>&1 || true
}

absolute_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s\n' "$PWD/$1" ;;
    esac
}

# "<device>:<inode>" of a path, symbolic links followed; status 1 when it
# does not exist.
file_id() {
    stat -L -f '%d:%i' "$1" 2>/dev/null
}

# True when both paths exist and are the same file (device and inode), however
# each is spelled: "/tmp/x" and "/private/tmp/x", or two letter cases.
same_file() {
    local first second
    first="$(file_id "$1")" || return 1
    second="$(file_id "$2")" || return 1
    [[ "$first" == "$second" ]]
}

# rename(2), which unlike mv never moves a folder into a folder that already
# exists at the destination.
rename_path() {
    perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' "$1" "$2" 2>/dev/null
}

# --- Processes and permissions ---------------------------------------------

# What bash cannot ask exactly, answered by /usr/bin/python3 in isolated mode
# (-I: nothing is imported from the environment or the working directory).
# Paths stay bytes throughout, so no locale can escape or garble them.
#
#   running PATH...      The processes of this account (real user id) whose
#                        executable, as the kernel has it (proc_pidpath), is
#                        one of the PATHs: the same file (device and inode),
#                        or the same path word for word, which still finds a
#                        copy whose bundle was replaced on disk after it
#                        started. One process id per line.
#   blockers 0|1 BUNDLE  What keeps this account from moving BUNDLE into
#                        another folder (deleting it from its folder, and
#                        writing its ".." entry) and, with 1, from then
#                        deleting everything in it, entry by entry as
#                        access(2) with _DELETE_OK answers: lines "<kind>
#                        <path>", the kind being "locked" (an immutable or
#                        append-only flag on the entry or its folder),
#                        "protected" (refused by macOS itself where the mode
#                        bits allow it, as App Management may do for a
#                        running app's bundle) or "denied" (permissions, an
#                        ACL, a read-only volume).
#                        Nothing when nothing does.
IFS= read -r -d '' PROCESS_HELPER <<'PY' || true
import ctypes, errno, os, sys

def running(paths):
    names = set(paths)
    # The kernel reports a copy's executable by its real file name, even when
    # it was started through a link, so only processes with that name are
    # looked at: no stat of every other process's executable (one on a hung
    # network mount could block the whole check).
    basenames = {os.path.basename(path) for path in paths}
    files = set()
    for path in paths:
        try:
            info = os.stat(path)
        except OSError:
            continue
        files.add((info.st_dev, info.st_ino))
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    libproc.proc_listpids.argtypes = (ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int)
    libproc.proc_pidpath.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32)
    PROC_RUID_ONLY = 5
    size = libproc.proc_listpids(PROC_RUID_ONLY, os.getuid(), None, 0)
    if size <= 0:
        raise OSError(ctypes.get_errno(), "proc_listpids")
    # Room for processes started since the size was asked.
    pids = (ctypes.c_int * (size // ctypes.sizeof(ctypes.c_int) + 256))()
    size = libproc.proc_listpids(PROC_RUID_ONLY, os.getuid(), pids, ctypes.sizeof(pids))
    if size <= 0:
        raise OSError(ctypes.get_errno(), "proc_listpids")
    buffer = ctypes.create_string_buffer(4096)  # PROC_PIDPATHINFO_MAXSIZE
    for pid in pids[:size // ctypes.sizeof(ctypes.c_int)]:
        if pid <= 0:
            continue
        length = libproc.proc_pidpath(pid, buffer, ctypes.sizeof(buffer))
        if length <= 0:
            continue  # exited, or its executable was deleted
        executable = buffer.raw[:length]
        if executable not in names:
            if os.path.basename(executable) not in basenames:
                continue
            try:
                info = os.stat(executable)
            except OSError:
                continue
            if (info.st_dev, info.st_ino) not in files:
                continue
        print(pid)

LOCKED = 0x2 | 0x4 | 0x20000 | 0x40000 | 0x100000  # UF_IMMUTABLE UF_APPEND SF_IMMUTABLE SF_APPEND SF_NOUNLINK
DELETE_OK = 1 << 12  # _DELETE_OK
LIST_OK = -1  # not access(2)'s: reading a folder's entries
AT_FDCWD = -2
AT_SYMLINK_NOFOLLOW = 0x20

def blockers(deep, bundle):
    libc = ctypes.CDLL(None, use_errno=True)
    libc.faccessat.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_int)
    out = sys.stdout.buffer
    uid = os.getuid()
    groups = set(os.getgroups()) | {os.getgid()}

    def allows(info, bits):  # 4 read, 2 write, 1 search, by the mode alone
        shift = 6 if info.st_uid == uid else 3 if info.st_gid in groups else 0
        return (info.st_mode >> shift) & bits == bits

    # Whether the mode bits alone (ACLs aside) allow it: for telling a
    # refusal by macOS itself, which may come first, from plain permissions.
    def mode_allows(path, folder, mode):
        try:
            if mode == os.W_OK:
                return allows(os.lstat(path), 2)
            if mode == LIST_OK:
                return allows(os.lstat(path), 5)
            info, parent = os.lstat(path), os.lstat(folder)
            sticky = parent.st_mode & 0o1000 and uid not in (info.st_uid, parent.st_uid)
            return allows(parent, 3) and not sticky
        except OSError:
            return False

    def report(path, folder, mode, code):
        flags = 0
        for item in (path, folder):
            try:
                flags |= os.lstat(item).st_flags
            except OSError:
                pass
        if flags & LOCKED:
            kind = b"locked"
        elif code == errno.EPERM and mode_allows(path, folder, mode):
            kind = b"protected"
        else:
            kind = b"denied"
        out.write(kind + b" " + path + b"\n")

    def check(path, folder, mode):
        if libc.faccessat(AT_FDCWD, path, mode, AT_SYMLINK_NOFOLLOW) != 0:
            report(path, folder, mode, ctypes.get_errno())

    check(bundle, os.path.dirname(bundle), DELETE_OK)
    check(bundle, os.path.dirname(bundle), os.W_OK)
    folders = [bundle] if deep else []
    while folders:
        folder = folders.pop()
        try:
            entries = list(os.scandir(folder))
        except OSError as error:
            report(folder, os.path.dirname(folder), LIST_OK, error.errno)
            continue
        for entry in entries:
            check(entry.path, folder, DELETE_OK)
            if entry.is_dir(follow_symlinks=False):
                folders.append(entry.path)

command, arguments = sys.argv[1], [os.fsencode(argument) for argument in sys.argv[2:]]
if command == "running":
    running(arguments)
elif command == "blockers":
    blockers(arguments[0] == b"1", arguments[1])
else:
    sys.exit("unknown command " + command)
PY

helper() {
    perl -e 'alarm shift; exec @ARGV' 60 /usr/bin/python3 -I -c "$PROCESS_HELPER" "$@"
}

# --- Running copies -------------------------------------------------------

# Spellings of each bundle that the kernel's path of a running copy may use
# word for word: as passed and its real path. Comparing text still finds a
# copy whose bundle was replaced under it, which comparing files cannot.
bundle_spellings() {
    local bundle real
    for bundle in "$@"; do
        printf '%s\n' "$bundle"
        if real="$(canonical_path "$bundle")"; then
            printf '%s\n' "$real"
        fi
    done
}

# Sets RUNNING_PIDS (space separated; empty when there are none) to the
# copies of the app running from any of the given bundles: the processes
# whose executable, as the kernel has it, is a bundle's executable, as the
# same file or word for word (see the helper's "running"). So a copy started
# through a symbolic link (to the bundle, a folder above it or the
# executable itself), in another letter case or by any other spelling is
# found, while a process that only names, reads or maps the file (`tail -f`,
# an editor, a viewer) is not. Status 1, with a message, when the processes
# could not be listed.
list_running() {
    local spelling paths=() output
    while IFS= read -r spelling; do
        paths+=("$spelling/Contents/MacOS/$EXECUTABLE")
    done < <(bundle_spellings "$@")
    if ! output="$(helper running "${paths[@]}")"; then
        echo "error: could not list this account's processes (with /usr/bin/python3) to see whether $APP_NAME is running." >&2
        return 1
    fi
    RUNNING_PIDS="${output//$'\n'/ }"
}

# list_running, stopping the script when it fails: a copy that cannot be
# seen must never have its bundle replaced or removed under it.
find_running() {
    list_running "$@" || exit 1
}

# Sends the app the standard quit request (NSRunningApplication.terminate,
# what the Dock's Quit does), so applicationShouldTerminate runs and can
# show the app's quit confirmation. Status 1 when the request could not be
# sent (not an app process, or no window-server session).
request_quit() {
    local answer
    answer="$(perl -e 'alarm shift; exec @ARGV' 20 /usr/bin/osascript -l JavaScript -e '
function run(argv) {
    ObjC.import("AppKit");
    var app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(parseInt(argv[0], 10));
    if (app.isNil()) {
        return "absent";
    }
    return app.terminate ? "sent" : "refused";
}' "$1" 2>/dev/null)" || answer="failed"
    [[ "$answer" == "sent" ]]
}

# Waits until no process runs from the given bundles, for at most $1 seconds
# (0: just look). Status 1 when some still do, with RUNNING_PIDS naming them.
wait_until_gone() {
    local seconds="$1" tenths=0
    shift
    while true; do
        find_running "$@"
        [[ -n "$RUNNING_PIDS" ]] || return 0
        (( tenths < seconds * 10 )) || return 1
        sleep 0.5
        tenths=$((tenths + 5))
    done
}

# Makes sure no copy of the app runs from the given bundles: each is asked
# to quit and given HPC_INSTALL_QUIT_TIMEOUT seconds. One that is still
# running then gets SIGTERM with --force; without it the script stops with
# EXIT_STILL_RUNNING, before anything was installed or removed.
quit_running_copies() {
    local pids pid
    find_running "$@"
    pids="$RUNNING_PIDS"
    [[ -n "$pids" ]] || return 0
    for pid in $pids; do
        echo "Asking $APP_NAME (pid $pid) to quit. If terminals, transfers or a sign-in are running, it asks you first."
        request_quit "$pid" ||
            echo "warning: could not send pid $pid the quit request; quit $APP_NAME yourself (waiting up to $QUIT_TIMEOUT s)." >&2
    done
    if wait_until_gone "$QUIT_TIMEOUT" "$@"; then
        return 0
    fi
    pids="$RUNNING_PIDS"
    if [[ "$FORCE" == true ]]; then
        echo "warning: $APP_NAME (pid $pids) did not quit; stopping it with SIGTERM (--force)." >&2
        for pid in $pids; do
            kill -TERM "$pid" 2>/dev/null || true
        done
        if wait_until_gone "$TERM_GRACE_SECONDS" "$@"; then
            return 0
        fi
        echo "error: $APP_NAME (pid $RUNNING_PIDS) is still running even after SIGTERM; nothing was changed." >&2
        exit "$EXIT_STILL_RUNNING"
    fi
    echo "error: $APP_NAME (pid $pids) is still running, so nothing was changed. It may be asking whether to quit (running terminals or transfers): quit it, then run this again${RERUN_HINT:+ ($RERUN_HINT)}, or add --force to stop it without asking." >&2
    exit "$EXIT_STILL_RUNNING"
}

# quit_running_copies, remembering which of the given bundles had a copy
# running, so the app can be opened again when a later step fails.
stop_copies() {
    local bundle had=()
    for bundle in "$@"; do
        find_running "$bundle"
        [[ -z "$RUNNING_PIDS" ]] || had+=("$bundle")
    done
    (( ${#had[@]} > 0 )) || return 0
    quit_running_copies "$@"
    STOPPED_BUNDLES+=("${had[@]}")
}

was_stopped() {
    local bundle
    for bundle in ${STOPPED_BUNDLES[@]+"${STOPPED_BUNDLES[@]}"}; do
        [[ "$bundle" != "$1" ]] || return 0
    done
    return 1
}

# After a failure: opens the app this run quit again, from the first of the
# install, the old install and the .runtime copy that it was quit from and
# that still holds the app. Nothing is opened while some copy still runs,
# or when that cannot be told.
reopen_stopped_app() {
    local bundle
    (( ${#STOPPED_BUNDLES[@]} > 0 )) || return 0
    list_running "$SOURCE_BUNDLE" ${PREVIOUS:+"$PREVIOUS"} ${TARGET:+"$TARGET"} 2>/dev/null || return 0
    [[ -z "$RUNNING_PIDS" ]] || return 0
    for bundle in ${TARGET:+"$TARGET"} ${PREVIOUS:+"$PREVIOUS"} "$SOURCE_BUNDLE"; do
        was_stopped "$bundle" && is_app_bundle "$bundle" || continue
        if [[ "$NO_OPEN" == true ]]; then
            echo "$APP_NAME was quit for the update and is not reopened (--no-open); open it from '$bundle'." >&2
        else
            echo "Opening $APP_NAME from '$bundle' again." >&2
            open_app "$bundle" || true
        fi
        return 0
    done
}

# --- Install --------------------------------------------------------------

# HPC_INSTALL_DIR; otherwise the folder of the existing install (so updates
# never leave a second copy behind); otherwise /Applications or, without
# write access there, ~/Applications. Always the folder's real path.
resolve_install_dir() {
    local existing
    if [[ -n "${HPC_INSTALL_DIR:-}" ]]; then
        INSTALL_DIR="$(absolute_path "$HPC_INSTALL_DIR")"
        mkdir -p "$INSTALL_DIR" 2>/dev/null || die "cannot create HPC_INSTALL_DIR '$INSTALL_DIR'."
        [[ -w "$INSTALL_DIR" ]] || die "HPC_INSTALL_DIR '$INSTALL_DIR' is not writable."
    elif existing="$(recorded_install)" && [[ "$(basename "$existing")" == "$APP_NAME.app" && -w "$(dirname "$existing")" ]]; then
        INSTALL_DIR="$(dirname "$existing")"
    elif [[ -d "$DEFAULT_INSTALL_DIR" && -w "$DEFAULT_INSTALL_DIR" ]]; then
        INSTALL_DIR="$DEFAULT_INSTALL_DIR"
    else
        INSTALL_DIR="$HOME/Applications"
        mkdir -p "$INSTALL_DIR" || die "cannot create $INSTALL_DIR."
        echo "note: $DEFAULT_INSTALL_DIR is not writable for this account, so the app goes to $INSTALL_DIR instead (Spotlight and Launchpad find it there too). HPC_INSTALL_DIR picks another folder."
    fi
    INSTALL_DIR="$(canonical_path "$INSTALL_DIR")" || die "cannot resolve the install folder '$INSTALL_DIR'."
}

# A helper "blockers" line in words.
describe_blocker() {
    local path="${1#* }"
    case "${1%% *}" in
        locked) printf "'%s' is locked" "$path" ;;
        protected) printf "macOS does not let this account change '%s'" "$path" ;;
        *) printf "this account may not delete '%s'" "$path" ;;
    esac
}

# Stops the script with what keeps this account from changing the bundle
# ($3), from a helper "blockers" line ($1 kind, $2 path); $4 says what was
# to happen ("replaced", "removed").
bundle_blocked() {
    local kind="$1" path="$2" bundle="$3" action="$4" what="'$2'"
    [[ "$path" != "$bundle" ]] || what="it"
    case "$kind" in
        locked)
            die "'$bundle' cannot be $action, because $what is locked (it or its folder has an immutable or append-only flag, which ls -lO shows); nothing was changed. Clear the flag (chflags), then run this again." ;;
        protected)
            die "'$bundle' cannot be $action, because macOS does not let this account change $what; nothing was changed. Allow your terminal under App Management (System Settings > Privacy & Security), or remove the app in the Finder, then run this again." ;;
        *)
            if [[ "$path" == "$bundle" ]]; then
                die "'$bundle' is not writable for this account (its permissions or an ACL; an install made with sudo belongs to root), so it cannot be $action; nothing was changed. Remove it yourself, then run this again."
            fi
            die "'$bundle' cannot be $action, because this account may not delete '$path' (permissions or an ACL on it or its folder); nothing was changed. Remove it yourself, then run this again." ;;
    esac
}

# Stops the script, before anything is asked to quit, when this account
# cannot take the bundle ($2) out of its folder by rename(2) into a staging
# folder or, with $1 = 1, cannot then delete all of it (see the helper's
# "blockers"); $3 says what was to happen. A refusal by macOS itself
# ("protected") is let through while a copy of the app runs from the bundle:
# macOS may deny a process without the App Management permission write
# access to a running app's bundle until the app has quit, and the move
# after the quit is the real test.
check_movable() {
    local deep="$1" bundle="$2" action="$3" report line running=false
    report="$(helper blockers "$deep" "$bundle")" ||
        die "could not check whether '$bundle' can be $action; nothing was changed."
    [[ -n "$report" ]] || return 0
    find_running "$bundle"
    [[ -z "$RUNNING_PIDS" ]] || running=true
    while IFS= read -r line; do
        if [[ "$line" == "protected "* && "$running" == true ]]; then
            continue
        fi
        bundle_blocked "${line%% *}" "${line#* }" "$bundle" "$action"
    done <<<"$report"
}

# Everything the swap changes, checked before anything is asked to quit:
# the folder, .runtime/ (the record) and, when it is replaced, the existing
# bundle (see check_movable).
check_write_access() {
    [[ -w "$INSTALL_DIR" ]] || die "cannot write to '$INSTALL_DIR'; nothing was changed."
    [[ -w "$RUNTIME_DIR" ]] || die "cannot write to '$RUNTIME_DIR' (the install record); nothing was changed."
    if [[ "$1" == true && -e "$TARGET" ]]; then
        # Deep: the replaced install is deleted after the swap, and an entry
        # inside it this account cannot delete would leave a half-deleted
        # copy in a hidden staging folder.
        check_movable 1 "$TARGET" replaced
    fi
}

# When a process started, as ps reports it; empty when it is not running.
process_start() {
    LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//' || true
}

# Creates a staging folder of this run in the folder $1 and prints its path;
# status 1 when it cannot. Its name carries this process's id from the
# moment it exists, and its owner file the id and start time, so that
# another run (from this checkout or another one) can tell it is in use.
new_staging_dir() {
    local folder
    folder="$(mktemp -d "$1/$STAGING_PREFIX$$.XXXXXX" 2>/dev/null)" || return 1
    if ! printf '%s\n%s\n' "$$" "$(process_start "$$")" >"$folder/owner" 2>/dev/null; then
        rm -rf "$folder"
        return 1
    fi
    printf '%s\n' "$folder"
}

# This run's staging folder in the install folder (STAGING_DIR).
make_staging_dir() {
    STAGING_DIR="$(new_staging_dir "$INSTALL_DIR")" ||
        die "could not create a staging folder in '$INSTALL_DIR'; nothing was changed."
}

# True while the run that made a staging folder is still going: the process
# its owner file names is running and started when the file says (so a
# reused process id does not count). Without an owner file (that run is
# between creating the folder and writing it) the process id in the
# folder's name decides; a folder with neither is dead.
staging_in_use() {
    local folder="$1" pid="" start="" name
    if [[ -f "$folder/owner" ]]; then
        { IFS= read -r pid && IFS= read -r start; } <"$folder/owner" 2>/dev/null || true
        [[ "$pid" =~ ^[0-9]+$ && "$pid" != "$$" && -n "$start" ]] || return 1
        [[ "$(process_start "$pid")" == "$start" ]]
        return
    fi
    name="${folder##*/"$STAGING_PREFIX"}"
    pid="${name%%.*}"
    [[ "$pid" =~ ^[0-9]+$ && "$pid" != "$$" ]] || return 1
    [[ -n "$(process_start "$pid")" ]]
}

# Unregisters the bundles in a staging folder, which is about to be
# deleted: LaunchServices keeps the record of a bundle deleted while
# registered (an install moved aside, say) under its old path.
unregister_staged_bundles() {
    local bundle
    for bundle in "$1"/*.app; do
        [[ ! -e "$bundle" ]] || lsregister -u "$bundle"
    done
}

# Staging folders a run killed before its exit trap (SIGKILL) left behind:
# they hold real bundles with the app's identifier, so they are unregistered
# and removed. A previous install found in one (previous.app) is the only
# copy of it when the run died between its two moves, or while --uninstall
# had it moved out of the way and had not yet decided to delete it: with
# nothing in its place it is put back first, and while something else is
# in its place it is kept. A bundle being removed (removed.app) just goes.
# A folder whose run is still going is left alone. Each folder is looked at
# once, however many spellings of it are given.
clean_leftover_staging() {
    local folder leftover saved target real seen=$'\n'
    for folder in "$@"; do
        real="$(canonical_path "$folder")" || continue
        [[ "$seen" != *$'\n'"$real"$'\n'* ]] || continue
        seen+="$real"$'\n'
        target="$folder/$APP_NAME.app"
        for leftover in "$folder/$STAGING_PREFIX"*; do
            [[ -d "$leftover" && ! -L "$leftover" ]] || continue
            if staging_in_use "$leftover"; then
                echo "Left the staging folder '$leftover' alone: the install that made it is still running."
                continue
            fi
            saved="$leftover/previous.app"
            if is_app_bundle "$saved"; then
                if [[ ! -e "$target" && ! -L "$target" ]] && rename_path "$saved" "$target"; then
                    echo "Put back the install an interrupted run left in '$leftover'."
                elif ! is_app_bundle "$target" || [[ -L "$target" ]]; then
                    echo "warning: kept '$saved', an earlier install an interrupted run left behind, because '$target' is not $APP_NAME; move it back yourself." >&2
                    continue
                fi
            fi
            unregister_staged_bundles "$leftover"
            if rm -rf "$leftover"; then
                echo "Removed the staging folder '$leftover' an interrupted run left behind."
            else
                echo "warning: could not remove '$leftover'; delete it yourself." >&2
            fi
        done
    done
}

build_bundles() {
    local arguments=(--for-install)
    if [[ "$CONFIGURATION" == "debug" ]]; then
        arguments+=(--debug)
    fi
    "${BASH:-/bin/bash}" "$SCRIPT_DIR/build_bundle.sh" "${arguments[@]}" AIREMonitorApp AIREDesktopWidget
}

check_source_bundle() {
    [[ -d "$SOURCE_BUNDLE" ]] ||
        die "there is no .runtime/$EXECUTABLE.app to install; run this without --skip-build."
    is_app_bundle "$SOURCE_BUNDLE" ||
        die ".runtime/$EXECUTABLE.app is not the $APP_NAME bundle (expected identifier $BUNDLE_ID)."
    [[ -x "$SOURCE_BUNDLE/Contents/MacOS/$EXECUTABLE" ]] ||
        die ".runtime/$EXECUTABLE.app has no executable; rebuild it (run this without --skip-build)."
    codesign --verify --strict "$SOURCE_BUNDLE" >/dev/null 2>&1 ||
        die ".runtime/$EXECUTABLE.app does not pass codesign --verify; rebuild it (run this without --skip-build)."
}

# Opens the installed app through LaunchServices; without it (error -600
# from a session with no window server) starts the executable directly,
# detached. Either way the app finds this checkout through its
# HPCProjectRoot Info.plist key.
open_app() {
    if open "$1"; then
        return 0
    fi
    echo "macOS open failed; starting $APP_NAME directly." >&2
    nohup "$1/Contents/MacOS/$EXECUTABLE" </dev/null >/dev/null 2>&1 &
}

# Moves the install that was set aside back to TARGET, only into an empty
# place. When that fails the staging folder is kept (never deleted) and the
# error says where the previous install is; status 1.
put_back_previous() {
    local saved="$STAGING_DIR/previous.app"
    [[ -e "$saved" ]] || return 0
    if [[ ! -e "$TARGET" && ! -L "$TARGET" ]] && rename_path "$saved" "$TARGET"; then
        return 0
    fi
    echo "error: could not put the previous install back at '$TARGET'. It is kept, unchanged, at '$saved'; move it back yourself." >&2
    STAGING_DIR=""
    return 1
}

# Removes the staging folder. Before the swap completed it may hold the
# previous install (the run failed or was interrupted between the two
# moves, or --uninstall stopped before deciding to delete it), which is put
# back first and kept if it cannot be. After the swap it holds the replaced
# install, which is unregistered before it goes.
cleanup_staging() {
    [[ -n "${STAGING_DIR:-}" && -d "$STAGING_DIR" ]] || return 0
    if [[ "$SWAPPED" != true ]]; then
        put_back_previous || return 0
    fi
    unregister_staged_bundles "$STAGING_DIR"
    rm -rf "$STAGING_DIR" || echo "warning: could not remove '$STAGING_DIR'; delete it yourself." >&2
}

on_exit() {
    local status=$?
    cleanup_staging || true
    if (( status != 0 )); then
        reopen_stopped_app || true
    fi
    exit "$status"
}

# The last step of an install: LaunchServices forgets the .runtime copy,
# which is only the build output from now on. Done once no process runs
# from it any more, and after everything else, so the copy that just quit
# from there (asked before the build, or with --skip-build only moments
# ago) has finished exiting and LaunchServices has noticed.
forget_build_output() {
    wait_until_gone "$SOURCE_EXIT_SECONDS" "$SOURCE_BUNDLE" ||
        echo "warning: $APP_NAME is running from .runtime/$EXECUTABLE.app again; LaunchServices may go on listing that copy until it quits." >&2
    lsregister -u "$SOURCE_BUNDLE"
}

# After a move, the install in the old folder ($1) goes: unregistered while
# it still exists (afterwards LaunchServices would keep its record under
# that path), then moved into a staging folder next to it and deleted there.
# One this account cannot delete completely (locked, an ACL, a read-only
# folder inside) stays whole where it is, never half deleted.
remove_old_install() {
    local old="$1" report folder
    lsregister -u "$old"
    if ! report="$(helper blockers 1 "$old")"; then
        echo "warning: left the old install at '$old' alone: could not check whether this account may delete all of it; delete it yourself." >&2
        return 0
    fi
    if [[ -n "$report" ]]; then
        echo "warning: left the old install at '$old' alone, since $(describe_blocker "${report%%$'\n'*}"); delete it yourself." >&2
        return 0
    fi
    if ! folder="$(new_staging_dir "$(dirname "$old")")"; then
        echo "warning: could not remove the old install at '$old'; delete it yourself." >&2
        return 0
    fi
    if ! rename_path "$old" "$folder/removed.app"; then
        rm -rf "$folder"
        echo "warning: could not move the old install at '$old' out of the way to remove it; delete it yourself." >&2
        return 0
    fi
    # Started again since the quit: it runs from the moved bundle, so that
    # goes back where it was (registered again) instead of being deleted.
    find_running "$folder/removed.app" "$old"
    if [[ -n "$RUNNING_PIDS" ]]; then
        if rename_path "$folder/removed.app" "$old"; then
            rm -rf "$folder"
            lsregister -f "$old"
            echo "warning: the old install at '$old' was started again (pid $RUNNING_PIDS), so it was left there; quit it and delete it yourself." >&2
        else
            echo "warning: the old install was started again (pid $RUNNING_PIDS) and could not be moved back; it is at '$folder/removed.app'. Quit it, then delete that folder yourself." >&2
        fi
        return 0
    fi
    if rm -rf "$folder"; then
        echo "Removed the old install at '$old'."
    else
        echo "warning: moved the old install at '$old' to '$folder' but could not delete all of it there; delete that folder yourself." >&2
    fi
}

install_app() {
    local target staged replace=true stopped=false recorded folders=()
    resolve_install_dir
    target="$INSTALL_DIR/$APP_NAME.app"
    TARGET="$target"
    # The recorded folder too, even when the record no longer names the app
    # (a run killed between its two moves left the install in a staging
    # folder there).
    folders=("$INSTALL_DIR")
    if recorded="$(recorded_path)"; then
        folders+=("$(dirname "$recorded")")
    fi
    clean_leftover_staging "${folders[@]}"

    if [[ -L "$target" ]]; then
        die "'$target' is a symbolic link; remove it, then run this again."
    fi
    if [[ -e "$target" ]] && ! is_app_bundle "$target"; then
        die "'$target' exists but is not $APP_NAME (identifier $BUNDLE_ID); move it away, then run this again."
    fi
    # An install somewhere else (HPC_INSTALL_DIR changed): replaced by this
    # one, so only one copy stays registered. The same folder spelled
    # another way is not somewhere else (and a copy started by that spelling
    # is found all the same: the kernel knows its executable by its file).
    if PREVIOUS="$(recorded_install)" && [[ "$PREVIOUS" != "$target" ]] && ! same_file "$PREVIOUS" "$target"; then
        echo "Moving the install from '$PREVIOUS' to '$target'."
    else
        PREVIOUS=""
    fi

    if [[ "$SKIP_BUILD" == false ]]; then
        # The build replaces .runtime/AIREMonitorApp.app. A copy running from
        # it would go on running the old code against the new bundle (and
        # Keychain and signature checks read the bundle), so it is asked to
        # quit first; if it does not, nothing is built or changed.
        find_running "$SOURCE_BUNDLE"
        if [[ -n "$RUNNING_PIDS" ]]; then
            check_write_access true
            RERUN_HINT=""
            stop_copies "$SOURCE_BUNDLE"
        fi
        build_bundles
    fi
    check_source_bundle

    if install_is_current "$target"; then
        replace=false
        echo "$target is up to date."
    fi
    check_write_access "$replace"
    if [[ "$replace" == true ]]; then
        # Staged and verified before anything running is asked to quit, so
        # a failed copy leaves the running app alone.
        make_staging_dir
        staged="$STAGING_DIR/$APP_NAME.app"
        ditto "$SOURCE_BUNDLE" "$staged" || die "could not copy the bundle to $INSTALL_DIR."
        codesign --verify --strict "$staged" >/dev/null 2>&1 ||
            die "the copied bundle does not pass codesign --verify; nothing was installed."
    fi

    # Running copies that must go: the .runtime one and an older install
    # always (from now on only the installed copy is launched), the
    # installed one only when it is replaced.
    local quit_from=("$SOURCE_BUNDLE")
    [[ -z "$PREVIOUS" ]] || quit_from+=("$PREVIOUS")
    [[ "$replace" == false ]] || quit_from+=("$target")
    RERUN_HINT="scripts/install_app.sh --skip-build installs the build that is ready"
    stop_copies "${quit_from[@]}"
    (( ${#STOPPED_BUNDLES[@]} == 0 )) || stopped=true

    if [[ "$replace" == true ]]; then
        # rename(2), not mv: a folder that appeared at the destination in
        # the meantime makes it fail instead of receiving the bundle.
        if [[ -e "$target" ]]; then
            rename_path "$target" "$STAGING_DIR/previous.app" ||
                die "could not move the old '$target' aside; nothing was installed."
            # A copy started after the quit would go on running from the
            # set-aside bundle, which is deleted with the staging folder:
            # put it back and stop instead.
            find_running "$STAGING_DIR/previous.app" "$target"
            if [[ -n "$RUNNING_PIDS" ]]; then
                put_back_previous || exit 1
                echo "error: $APP_NAME was started again during the update (pid $RUNNING_PIDS); nothing was installed. Quit it, then run this again ($RERUN_HINT)." >&2
                exit 3
            fi
        fi
        if [[ -e "$target" || -L "$target" ]] || ! rename_path "$staged" "$target"; then
            [[ -e "$STAGING_DIR/previous.app" ]] || die "could not move the new bundle to '$target'; nothing was installed."
            put_back_previous || exit 1
            die "could not move the new bundle into place; the previous install was put back."
        fi
        SWAPPED=true
        echo "Installed $target ($(plist_value "$target" HPCBuildConfiguration), $(plist_value "$target" HPCSourceRevision))."
    fi
    lsregister -f "$target"
    write_record "$target"
    if [[ -n "$PREVIOUS" ]] && is_app_bundle "$PREVIOUS" && ! same_file "$PREVIOUS" "$target"; then
        remove_old_install "$PREVIOUS"
    fi
    # Installed: nothing is reopened from here on, whatever happens.
    STOPPED_BUNDLES=()

    if [[ "$NO_OPEN" == true ]]; then
        if [[ "$stopped" == true ]]; then
            echo "$APP_NAME was quit for the update and not reopened (--no-open); open it from $INSTALL_DIR."
        fi
    else
        if [[ "$stopped" == true ]]; then
            # Let LaunchServices notice the old process is gone, so `open`
            # starts the new copy instead of looking for the one that quit.
            sleep 0.5
        fi
        open_app "$target"
    fi
    forget_build_output
}

# --- Uninstall ------------------------------------------------------------

# Removes the install without ever leaving half of it: everything this
# account must delete is checked before anything is asked to quit, the
# bundle is moved into a staging folder by rename(2) (which fails, changing
# nothing, for one this account may not move), checked again there now that
# nothing runs from it, and only then unregistered and deleted. Until then
# any failure puts it back where it was (see cleanup_staging) and opens the
# app again if this run quit it.
uninstall_app() {
    local target="" recorded candidate dirs=() folders=() moved removed report line path
    if [[ -n "${HPC_INSTALL_DIR:-}" ]]; then
        dirs=("$(absolute_path "$HPC_INSTALL_DIR")")
    else
        dirs=("$DEFAULT_INSTALL_DIR" "$HOME/Applications")
    fi
    # Leftover staging folders first, in the recorded folder (even when the
    # record no longer names the app) and the default ones: a run killed
    # between its two moves left the install in one, which is put back
    # here, so it is found and removed like any other install.
    if recorded="$(recorded_path)"; then
        folders+=("$(dirname "$recorded")")
    fi
    clean_leftover_staging ${folders[@]+"${folders[@]}"} "${dirs[@]}"

    if ! target="$(recorded_install)"; then
        target=""
        for candidate in "${dirs[@]}"; do
            if is_app_bundle "$candidate/$APP_NAME.app"; then
                target="$candidate/$APP_NAME.app"
                break
            fi
        done
    fi
    if [[ -z "$target" ]]; then
        rm -f "$RECORD"
        echo "$APP_NAME is not installed."
        return 0
    fi
    [[ ! -L "$target" ]] || die "'$target' is a symbolic link; remove it yourself."
    TARGET="$target"
    INSTALL_DIR="$(dirname "$target")"
    [[ -w "$INSTALL_DIR" ]] ||
        die "cannot remove '$target': '$INSTALL_DIR' is not writable for this account; nothing was changed."
    check_movable 1 "$target" removed
    make_staging_dir

    RERUN_HINT=""
    stop_copies "$target"
    moved="$STAGING_DIR/previous.app"
    rename_path "$target" "$moved" ||
        die "could not move '$target' out of the way, so nothing was removed."
    # A copy started since the quit now runs from the moved bundle.
    find_running "$moved" "$target"
    if [[ -n "$RUNNING_PIDS" ]]; then
        put_back_previous || exit 1
        echo "error: $APP_NAME (pid $RUNNING_PIDS) was started again while it was being removed, so nothing was removed. Quit it, then run this again." >&2
        exit "$EXIT_STILL_RUNNING"
    fi
    # Before the quit, a refusal by macOS itself was let through for a
    # running copy (see check_movable); now nothing may stand in the way.
    if ! report="$(helper blockers 1 "$moved")"; then
        put_back_previous || exit 1
        die "could not check whether '$target' can be deleted, so nothing was removed."
    fi
    if [[ -n "$report" ]]; then
        put_back_previous || exit 1
        line="${report%%$'\n'*}"
        path="${line#* }"
        bundle_blocked "${line%% *}" "$target${path#"$moved"}" "$target" removed
    fi
    # From here on it goes. Renamed first, so that a run killed now leaves a
    # staging folder the next run deletes instead of putting back.
    removed="$STAGING_DIR/removed.app"
    rename_path "$moved" "$removed" || die "could not move '$moved' within its staging folder, so nothing was removed."
    SWAPPED=true
    STOPPED_BUNDLES=()
    # Unregistered while it still exists (see install_app).
    lsregister -u "$removed"
    rm -f "$RECORD"
    # The checkout's own bundle is the app again (scripts/run_macos_app.sh
    # opens it).
    if is_app_bundle "$SOURCE_BUNDLE"; then
        lsregister -f "$SOURCE_BUNDLE"
    fi
    if rm -rf "$STAGING_DIR"; then
        echo "Removed $target."
    else
        echo "warning: removed $target, but could not delete all of it from '$STAGING_DIR'; delete that folder yourself." >&2
    fi
    STAGING_DIR=""
}

# --- Main -----------------------------------------------------------------

CONFIGURATION="release"
SKIP_BUILD=false
NO_OPEN=false
FORCE=false
ACTION="install"
for argument in "$@"; do
    case "$argument" in
        --debug) CONFIGURATION="debug" ;;
        --release) CONFIGURATION="release" ;;
        --skip-build) SKIP_BUILD=true ;;
        --no-open) NO_OPEN=true ;;
        --force) FORCE=true ;;
        --uninstall) ACTION="uninstall" ;;
        --installed-path) ACTION="print" ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) usage_error "unknown argument '$argument'" ;;
    esac
done

# Answered before any install option is checked: the other scripts read a
# non-zero status as "not installed", so a bad HPC_INSTALL_QUIT_TIMEOUT must
# not hide an install.
if [[ "$ACTION" == "print" ]]; then
    recorded_install
    exit $?
fi

if [[ "${HPC_INSTALL_NO_OPEN:-}" == 1 ]]; then
    NO_OPEN=true
fi
QUIT_TIMEOUT="${HPC_INSTALL_QUIT_TIMEOUT:-120}"
[[ "$QUIT_TIMEOUT" =~ ^[0-9]+$ ]] || usage_error "HPC_INSTALL_QUIT_TIMEOUT must be a whole number of seconds, not '$QUIT_TIMEOUT'"
[[ "$LOCK_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || usage_error "HPC_INSTALL_LOCK_TIMEOUT must be a whole number of seconds, not '$LOCK_TIMEOUT_SECONDS'"

if [[ ! -d "$RUNTIME_DIR" ]]; then
    (umask 077 && mkdir -p "$RUNTIME_DIR")
fi

# One install of this checkout at a time (the build inside has its own lock).
# lockf exits 75 when it gives up waiting, and so does the locked script
# when build_bundle.sh gave up waiting for its own lock (which says so
# itself). To tell the two apart, the locked script deletes a marker file
# as soon as it starts: a marker still there means it never ran.
if [[ -z "${HPC_INSTALL_APP_LOCKED:-}" && -x /usr/bin/lockf ]]; then
    lock_status=0
    lock_marker="$(mktemp "${LOCK_MARKER_PREFIX}XXXXXX")"
    trap 'rm -f "$lock_marker"' EXIT
    HPC_INSTALL_APP_LOCKED="$lock_marker" /usr/bin/lockf -k -s -t "$LOCK_TIMEOUT_SECONDS" \
        "$RUNTIME_DIR/.install_app.lock" "${BASH:-/bin/bash}" "$SCRIPT_PATH" "$@" || lock_status=$?
    if (( lock_status == 75 )) && [[ -e "$lock_marker" ]]; then
        echo "error: another install of this checkout has been running for over $LOCK_TIMEOUT_SECONDS s; try again when it finishes." >&2
    fi
    exit "$lock_status"
fi
case "${HPC_INSTALL_APP_LOCKED:-}" in
    "$LOCK_MARKER_PREFIX"*) rm -f "$HPC_INSTALL_APP_LOCKED" ;;
esac
unset HPC_INSTALL_APP_LOCKED

STAGING_DIR=""
# Set once the staging folder no longer holds an install to put back: the
# new bundle is in place, or --uninstall has decided to delete the old one.
SWAPPED=false
TARGET=""
PREVIOUS=""
RUNNING_PIDS=""
STOPPED_BUNDLES=()
trap on_exit EXIT
case "$ACTION" in
    install) install_app ;;
    uninstall) uninstall_app ;;
esac
