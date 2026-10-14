#!/usr/bin/env bash
# Builds Leeds HPC Monitor and/or its desktop widget and assembles signed .app
# bundles in .runtime/. This is the only place that knows how a bundle is
# made; scripts/run_macos_app.sh, scripts/run_desktop_widget.sh and
# scripts/install_app.sh are thin wrappers around it, so the bundles can no
# longer drift apart.
#
#   scripts/build_bundle.sh [--debug] [--open] [--for-install] PRODUCT [PRODUCT...]
#
#   PRODUCT   AIREMonitorApp (alias: app) or AIREDesktopWidget (alias: widget).
#             Several products are built by one `swift build`.
#   --debug   Build the debug configuration instead of release. Users should
#             run release builds: debug code is several times slower on the
#             main thread (snapshot decoding, SwiftUI bodies) and carries the
#             DEBUG-only preview hooks.
#             (--release, the default, is accepted for symmetry.)
#   --open    Open the first PRODUCT afterwards (or bring it to the front if
#             it is already running the current build).
#   --for-install
#             The app bundle is only the source for scripts/install_app.sh
#             (see below); that script passes this on every run.
#
# A bundle is replaced only when its content would change (executable,
# artwork, Info.plist fields, signing identity, or this script itself; see
# bundle_stamp). Replacing a bundle stops any instance running from it and
# starts it again on the new build, so a bundle is never left running stale
# code and never left stopped; the old bundle is unregistered from
# LaunchServices before it is deleted. When nothing changed, nothing is
# restarted: running the widget launcher while the widget is open just
# brings it forward, and the app keeps its terminal sessions.
#
# Once the app is installed (scripts/install_app.sh --installed-path), or
# with --for-install, .runtime/AIREMonitorApp.app is only the build output
# that install_app.sh copies: it is replaced without stopping a copy running
# from it (install_app.sh asks that one to quit before it builds, so the
# app's own quit confirmation protects its terminals), and it is never opened
# or restarted. Once installed, LaunchServices also forgets it instead of
# registering it, so it cannot compete with the installed app. Before the
# first install it stays registered: install_app.sh unregisters it only after
# the installed copy is in place, so a failed first install leaves the app
# launchable. The widget is unaffected and stays in .runtime/.
#
# Environment:
#   HPC_CODESIGN_IDENTITY  Code-signing identity (name or SHA-1, as for
#                          `codesign --sign`); "-" forces an ad-hoc signature.
#                          Unset: use a certificate named "Leeds HPC Monitor
#                          Local" when the login keychain has one, otherwise
#                          sign ad hoc (see sign_bundle for why it matters).
#   HPC_BUILD_JOBS         Passed to `swift build --jobs` (default: SwiftPM's).
#   HPC_SWIFTPM_BUILD_DIR  SwiftPM scratch directory (pre-rename name
#                          AIRE_SWIFTPM_BUILD_DIR still honoured).
#   HPC_BUILD_LOG          Build log path (default .runtime/swift-build.log, or
#                          .runtime/swift-widget-build.log for the widget alone).
#   SDKROOT                Respected when exported; otherwise SwiftPM uses the
#                          SDK that `xcrun --show-sdk-path` reports.
#   HPC_LSREGISTER         The lsregister tool to call (default: the system's).
#
# Exit status: swift build's status when the build fails, 75 when another
# build of this checkout held the lock for too long, 1 for any other error.
# Every failure is also appended to the build log, so a caller that only sees
# the exit status can show the log's last lines.
set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
RUNTIME_DIR="$ROOT_DIR/.runtime"

# Marketing version (CFBundleShortVersionString) until the repository carries
# a vX.Y.Z tag; from then on the newest such tag wins. It stays numeric
# because LaunchServices and the About panel expect "X.Y.Z"; the exact source
# revision goes into HPCSourceRevision instead.
MARKETING_VERSION_FALLBACK="0.2.0"
# Keep in step with `platforms:` in Package.swift.
MINIMUM_SYSTEM_VERSION="13.0"
# Code-signing certificate picked up automatically when present (see
# sign_bundle). Picked up by name rather than through an environment variable
# because the app and the widget run these scripts from a GUI process, which
# never sees variables exported in a shell profile.
DEFAULT_SIGNING_IDENTITY="Leeds HPC Monitor Local"
# Copied into Contents/Resources of every bundle: the emblem (sidebar, widget
# header) and the app icon. Both bundles carry the neutral Leeds HPC artwork.
BUNDLE_RESOURCES=(LeedsHPCMark.png LeedsHPCMonitor.icns)
ICON_NAME="LeedsHPCMonitor"
# Waiting longer than this for another build of the same checkout gives up
# with status 75. A clean release build of both products takes a few minutes.
LOCK_TIMEOUT_SECONDS=1200
# How long a running instance gets to exit after SIGTERM before SIGKILL.
STOP_GRACE_TENTHS=50

usage() {
    sed -n '2,/^set -euo pipefail$/p' "$SCRIPT_PATH" | sed -e '$d' -e 's/^# \{0,1\}//'
}

# Prints to stderr and, once the build has started, appends to the build log,
# so a caller that only captures the exit status can still show why.
log_failure() {
    echo "$*" >&2
    if [[ -n "${BUILD_LOG:-}" && -f "$BUILD_LOG" ]]; then
        echo "build_bundle.sh: $*" >>"$BUILD_LOG"
    fi
}

die() {
    log_failure "error: $*"
    exit 1
}

# --- Products -------------------------------------------------------------

canonical_product() {
    case "$1" in
        AIREMonitorApp | app) echo "AIREMonitorApp" ;;
        AIREDesktopWidget | widget) echo "AIREDesktopWidget" ;;
        *) return 1 ;;
    esac
}

# Sets the Info.plist fields that differ between the two bundles. The bundle
# identifiers predate the Leeds HPC rename and are kept on purpose: the
# Keychain item, notification permission and saved window frames hang off them.
load_product() {
    case "$1" in
        AIREMonitorApp)
            BUNDLE_ID="local.aire.monitor"
            BUNDLE_NAME="Leeds HPC Monitor"
            UI_ELEMENT=false
            ;;
        AIREDesktopWidget)
            # LSUIElement: the widget has no Dock icon or menu bar.
            BUNDLE_ID="local.aire.desktop-widget"
            BUNDLE_NAME="Leeds HPC Widget"
            UI_ELEMENT=true
            ;;
    esac
}

# --- Helpers --------------------------------------------------------------

sha256_of() {
    shasum -a 256 <"$1" | awk '{print $1}'
}

# Escapes a literal string for use in an extended regular expression.
ere_escape() {
    printf '%s' "$1" | sed -e 's/[][\\.^$*+?(){}|]/\\&/g'
}

# PIDs (of this user) whose command line starts with the given executable.
# Anchored, so a process that merely mentions the path (an editor, `tail`,
# lldb) is never matched.
running_pids() {
    pgrep -U "$(id -u)" -f "^$(ere_escape "$1")( |\$)" 2>/dev/null || true
}

# Stops every instance running from the given executable and waits until they
# are gone: `open` on a bundle whose old instance is still exiting would only
# activate the dying process instead of launching the new build.
# Returns 0 when something was running.
stop_instances() {
    local executable="$1" pids pid tenths=0
    pids="$(running_pids "$executable")"
    [[ -n "$pids" ]] || return 1
    for pid in $pids; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    while (( tenths < STOP_GRACE_TENTHS )); do
        [[ -n "$(running_pids "$executable")" ]] || return 0
        sleep 0.1
        tenths=$((tenths + 1))
    done
    pids="$(running_pids "$executable")"
    for pid in $pids; do
        echo "warning: $(basename "$executable") (pid $pid) ignored SIGTERM; killing it." >&2
        kill -KILL "$pid" 2>/dev/null || true
    done
    sleep 0.2
    return 0
}

# Opens a bundle through LaunchServices. When that is unavailable (for
# example error -600 from a non-GUI session), starts the executable directly,
# detached from this script's terminal; the bundle layout still lets it find
# its resources and the project root.
launch_bundle() {
    local bundle="$1" product="$2"
    if open "$bundle"; then
        return 0
    fi
    echo "macOS open failed; starting $product directly." >&2
    nohup "$bundle/Contents/MacOS/$product" </dev/null >/dev/null 2>&1 &
}

# True when PRODUCT's bundle is only the source of an install (see the
# header): the app, once installed or with --for-install.
is_install_source() {
    [[ "$1" == "AIREMonitorApp" && "$APP_IS_INSTALL_SOURCE" == true ]]
}

# True when PRODUCT is the app and an install exists.
is_installed() {
    [[ "$1" == "AIREMonitorApp" && -n "$INSTALLED_APP" ]]
}

# --- Version and signing --------------------------------------------------

# Reads the version fields from git without taking .git/index.lock
# (GIT_OPTIONAL_LOCKS=0), so a build started from the app never collides with
# a git command the user is running. Outside a git checkout the fallbacks stay.
resolve_version() {
    MARKETING_VERSION="$MARKETING_VERSION_FALLBACK"
    BUILD_NUMBER="1"
    SOURCE_REVISION="unknown"
    local toplevel tag count revision
    # Only this checkout's own repository counts, not one that happens to
    # enclose a copy of it (a home directory under git, say).
    toplevel="$(GIT_OPTIONAL_LOCKS=0 git -C "$ROOT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -z "$toplevel" || "$toplevel" != "$(cd "$ROOT_DIR" && pwd -P)" ]] ||
        ! GIT_OPTIONAL_LOCKS=0 git -C "$ROOT_DIR" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
        return 0
    fi
    tag="$(GIT_OPTIONAL_LOCKS=0 git -C "$ROOT_DIR" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
    tag="${tag#v}"
    if [[ "$tag" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
        MARKETING_VERSION="$tag"
    fi
    # CFBundleVersion must be numeric and should only grow: the commit count.
    count="$(GIT_OPTIONAL_LOCKS=0 git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || true)"
    if [[ "$count" =~ ^[0-9]+$ ]]; then
        BUILD_NUMBER="$count"
    fi
    revision="$(GIT_OPTIONAL_LOCKS=0 git -C "$ROOT_DIR" describe --tags --always --dirty 2>/dev/null || true)"
    if [[ -n "$revision" ]]; then
        SOURCE_REVISION="$revision"
    fi
}

# Chooses the signing identity before the (possibly long) build, so a
# misconfigured HPC_CODESIGN_IDENTITY fails in a second, not after minutes.
resolve_signing_identity() {
    SIGN_IDENTITY_SOURCE="default"
    if [[ -n "${HPC_CODESIGN_IDENTITY:-}" ]]; then
        SIGN_IDENTITY="$HPC_CODESIGN_IDENTITY"
        SIGN_IDENTITY_SOURCE="environment"
        if [[ "$SIGN_IDENTITY" != "-" ]] &&
            ! security find-identity -p codesigning 2>/dev/null | grep -Fq -- "$SIGN_IDENTITY"; then
            die "HPC_CODESIGN_IDENTITY='$SIGN_IDENTITY' matches no code-signing identity in your keychains (see \`security find-identity -p codesigning\`). Unset it, or set it to - to sign ad hoc."
        fi
    elif security find-identity -p codesigning 2>/dev/null | grep -Fq -- "\"$DEFAULT_SIGNING_IDENTITY\""; then
        SIGN_IDENTITY="$DEFAULT_SIGNING_IDENTITY"
        SIGN_IDENTITY_SOURCE="keychain"
    else
        SIGN_IDENTITY="-"
    fi
}

describe_identity() {
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        echo "ad hoc"
    else
        echo "'$SIGN_IDENTITY'"
    fi
}

# Signs the whole bundle with the real bundle identifier. Without this the
# executable keeps only the linker's ad-hoc signature, whose identifier is
# "<product>-<hash>", to which Info.plist is not bound and which seals no
# resources. Such a process is not reliably tied to local.aire.monitor (a
# likely cause of the notification authorisation that failed on every launch),
# and Keychain sees a different app after every build.
#
# Even a proper ad-hoc signature is identified by its code hash, which
# changes on every rebuild, so the first Keychain read after a rebuild still
# asks for permission. A stable self-signed certificate avoids that: Keychain
# Access > Certificate Assistant > Create a Certificate..., name it
# "Leeds HPC Monitor Local", identity type "Self Signed Root", certificate
# type "Code Signing". This script then picks it up automatically, also when
# the app or the widget runs it.
sign_bundle() {
    local bundle="$1" output
    # Extended attributes copied from the checkout (provenance, quarantine,
    # Finder info) have no place in a signed bundle; --strict rejects some.
    xattr -cr "$bundle" 2>/dev/null || true
    if output="$(codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$bundle" 2>&1)"; then
        return 0
    fi
    if [[ "$SIGN_IDENTITY_SOURCE" != "keychain" ]]; then
        die "codesign --sign $(describe_identity) failed for $bundle: $output"
    fi
    # The certificate was picked up implicitly and could not be used (for
    # example a locked keychain while the app runs this script): sign ad hoc
    # rather than fail the launch, and mark the bundle so the next build,
    # whose stamp names the certificate again, replaces it.
    log_failure "warning: signing with '$SIGN_IDENTITY' failed ($output); signing ad hoc instead."
    plutil -replace HPCBuildStamp -string "ad-hoc-fallback" "$bundle/Contents/Info.plist"
    SIGN_IDENTITY="-"
    SIGN_IDENTITY_SOURCE="fallback"
    output="$(codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$bundle" 2>&1)" ||
        die "codesign --sign - failed for $bundle: $output"
}

# --- Build ----------------------------------------------------------------

# Prints "Build complete!" or "Build of product 'X' complete!" lines; SwiftPM
# prints the second form when --product is given.
build_completed_in_log() {
    grep -Eq "Build (of product '[^']+' )?complete!" "$BUILD_LOG"
}

# True when the product's executable can be trusted after a build that
# SwiftPM reported as complete but whose exit status is non-zero: it was
# linked during this build, or none of its inputs changed since it was linked.
# (Either test alone is not enough: SwiftPM skips relinking when recompiled
# objects come out identical, so a current binary can be older than a
# touched source; and an unchanged build relinks nothing.)
executable_is_current() {
    local product="$1" executable="$2" modified newer
    [[ -f "$executable" ]] || return 1
    modified="$(stat -f %m "$executable" 2>/dev/null || echo 0)"
    if (( modified >= BUILD_START_TS - 5 )); then
        return 0
    fi
    newer="$(find "$ROOT_DIR/Package.swift" "$ROOT_DIR/Package.resolved" \
        "$ROOT_DIR/Sources/HPCCore" "$ROOT_DIR/Sources/$product" \
        -newer "$executable" -print 2>/dev/null | head -n 1)"
    [[ -z "$newer" ]]
}

run_swift_build() {
    local status=0 product
    local args=(build --disable-sandbox --scratch-path "$BUILD_DIR" -c "$CONFIGURATION")
    if [[ -n "${HPC_BUILD_JOBS:-}" ]]; then
        [[ "$HPC_BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] || die "HPC_BUILD_JOBS must be a positive integer, not '$HPC_BUILD_JOBS'."
        args+=(--jobs "$HPC_BUILD_JOBS")
    fi
    # One product: build just its dependency graph. Several: build every
    # product in one go (SwiftPM's --product takes a single name), which also
    # compiles HPCCore once for both.
    if (( ${#PRODUCTS[@]} == 1 )); then
        args+=(--product "${PRODUCTS[0]}")
    fi

    echo "# swift ${args[*]}" >>"$BUILD_LOG"
    echo "Building ${PRODUCTS[*]} ($CONFIGURATION)..."
    BUILD_START_TS="$(date +%s)"
    swift "${args[@]}" >>"$BUILD_LOG" 2>&1 || status=$?
    if (( status == 0 )); then
        return 0
    fi

    # Some toolchain/macOS combinations fail the final build.db write-back
    # ("disk I/O error") after a fully successful compile, mostly when the
    # scratch directory sits on a volume a backup or sync tool watches.
    # Accept such a build only when SwiftPM reported completion AND every
    # executable is current (see executable_is_current).
    if build_completed_in_log; then
        local all_current=true
        for product in "${PRODUCTS[@]}"; do
            executable_is_current "$product" "$BIN_DIR/$product" || all_current=false
        done
        if [[ "$all_current" == true ]]; then
            log_failure "warning: swift build exited $status after reporting completion; continuing with the fresh binaries."
            return 0
        fi
    fi

    # Report the compiler errors themselves, not the whole log (hundreds of
    # "Compiling" lines); the same summary closes the log for the app.
    local errors
    errors="$(grep -E '(^|: )error: ' "$BUILD_LOG" | awk '!seen[$0]++' | head -n 15 || true)"
    if [[ -n "$errors" ]]; then
        echo "$errors" >&2
        echo "$errors" >>"$BUILD_LOG"
    else
        tail -n 20 "$BUILD_LOG" >&2
    fi
    log_failure "error: swift build failed with status $status; full log: $BUILD_LOG"
    exit "$status"
}

# Starts a fresh log for this run before anything can fail, so the log never
# mixes an earlier build's output with this run's error.
start_build_log() {
    mkdir -p "$(dirname "$BUILD_LOG")"
    {
        echo "# build_bundle.sh $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# products: ${PRODUCTS[*]}; configuration: $CONFIGURATION; jobs: ${HPC_BUILD_JOBS:-default}"
        echo "# sdk: ${SDKROOT:-$(xcrun --show-sdk-path 2>/dev/null || echo unknown)}"
    } >"$BUILD_LOG"
}

# --- Bundles --------------------------------------------------------------

# Content hash of everything that ends up in the bundle, computed before the
# bundle is assembled so an unchanged bundle is neither rebuilt nor restarted.
# Deliberately excludes the commit count and source revision: a docs-only
# commit must not restart the app (and kill its terminal sessions). Those two
# Info.plist fields therefore describe the build that last changed the bundle.
bundle_stamp() {
    local product="$1" resource
    {
        echo "script $(sha256_of "$SCRIPT_PATH")"
        echo "product $product"
        echo "configuration $CONFIGURATION"
        echo "identifier $BUNDLE_ID"
        echo "name $BUNDLE_NAME"
        echo "ui-element $UI_ELEMENT"
        echo "version $MARKETING_VERSION"
        echo "minimum-system $MINIMUM_SYSTEM_VERSION"
        echo "project-root $ROOT_DIR"
        echo "signing $SIGN_IDENTITY"
        echo "executable $(sha256_of "$BIN_DIR/$product")"
        for resource in "${BUNDLE_RESOURCES[@]}"; do
            echo "resource $resource $(sha256_of "$ROOT_DIR/assets/$resource")"
        done
    } | shasum -a 256 | awk '{print $1}'
}

installed_stamp() {
    local bundle="$1"
    plutil -extract HPCBuildStamp raw -o - "$bundle/Contents/Info.plist" 2>/dev/null || true
}

write_info_plist() {
    local plist="$1" product="$2" stamp="$3"
    cat >"$plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST
    # plutil handles XML escaping, so names and paths need no quoting rules.
    plutil -insert CFBundleInfoDictionaryVersion -string "6.0" "$plist"
    plutil -insert CFBundleDevelopmentRegion -string "en" "$plist"
    plutil -insert CFBundleExecutable -string "$product" "$plist"
    plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$plist"
    plutil -insert CFBundleName -string "$BUNDLE_NAME" "$plist"
    plutil -insert CFBundleDisplayName -string "$BUNDLE_NAME" "$plist"
    plutil -insert CFBundlePackageType -string "APPL" "$plist"
    plutil -insert CFBundleIconFile -string "$ICON_NAME" "$plist"
    plutil -insert CFBundleShortVersionString -string "$MARKETING_VERSION" "$plist"
    plutil -insert CFBundleVersion -string "$BUILD_NUMBER" "$plist"
    plutil -insert LSMinimumSystemVersion -string "$MINIMUM_SYSTEM_VERSION" "$plist"
    plutil -insert NSHighResolutionCapable -bool YES "$plist"
    if [[ "$UI_ELEMENT" == true ]]; then
        plutil -insert LSUIElement -bool YES "$plist"
    fi
    # Lets a bundle that was moved or copied out of .runtime (installed into
    # /Applications by scripts/install_app.sh, or registered as a login item)
    # still find this checkout. Both the app and the widget check that the
    # directory holds scripts/hpc_snapshot.py before trusting it, so a stale
    # value after the checkout moves falls through to their other lookups.
    # LSEnvironment applies only to launches through LaunchServices;
    # HPCProjectRoot is read from the bundle itself (ProjectRootLocator in
    # HPCCore), so it also works when the executable is started directly.
    plutil -insert LSEnvironment -xml "<dict/>" "$plist"
    plutil -insert LSEnvironment.HPC_PROJECT_ROOT -string "$ROOT_DIR" "$plist"
    plutil -insert HPCProjectRoot -string "$ROOT_DIR" "$plist"
    # Build provenance, readable with `defaults read <bundle>/Contents/Info
    # HPCSourceRevision`. HPCBuildStamp identifies the bundle's content (see
    # bundle_stamp): two bundles with equal stamps are interchangeable.
    plutil -insert HPCSourceRevision -string "$SOURCE_REVISION" "$plist"
    plutil -insert HPCBuildConfiguration -string "$CONFIGURATION" "$plist"
    plutil -insert HPCBuildStamp -string "$stamp" "$plist"
    plutil -lint -s "$plist" >/dev/null || die "generated an invalid Info.plist for $product."
}

# Assembles PRODUCT into a staging directory next to its destination, signs
# and verifies it, and only then swaps it in, so a failed step never leaves a
# half-built bundle behind for the Widget buttons to open.
install_bundle() {
    local product="$1" bundle stamp staging staged resource
    load_product "$product"
    bundle="$RUNTIME_DIR/$product.app"
    [[ -x "$BIN_DIR/$product" ]] || die "swift build reported success but produced no $BIN_DIR/$product."

    stamp="$(bundle_stamp "$product")"
    if [[ "$(installed_stamp "$bundle")" == "$stamp" && -x "$bundle/Contents/MacOS/$product" ]] &&
        codesign --verify --strict "$bundle" >/dev/null 2>&1; then
        echo "$product.app is up to date."
        return 0
    fi

    staging="$(mktemp -d "$RUNTIME_DIR/.$product.staging.XXXXXX")"
    STAGING_DIRS+=("$staging")
    staged="$staging/$product.app"
    mkdir -p "$staged/Contents/MacOS" "$staged/Contents/Resources"
    cp -X "$BIN_DIR/$product" "$staged/Contents/MacOS/$product"
    for resource in "${BUNDLE_RESOURCES[@]}"; do
        cp -X "$ROOT_DIR/assets/$resource" "$staged/Contents/Resources/$resource"
    done
    printf 'APPL????' >"$staged/Contents/PkgInfo"
    write_info_plist "$staged/Contents/Info.plist" "$product" "$stamp"
    sign_bundle "$staged"
    codesign --verify --strict "$staged" >/dev/null 2>&1 || die "the signed $product.app does not verify."

    # An install source is never stopped here: asking a copy running from it
    # to quit, with the app's own confirmation, is install_app.sh's job, and
    # it does that before it builds.
    if ! is_install_source "$product" && stop_instances "$bundle/Contents/MacOS/$product"; then
        RESTART_PRODUCTS+=("$product")
    fi
    # Unregistered while it still exists: LaunchServices keeps the record of
    # a bundle deleted while registered, and `lsregister -u` on the path
    # afterwards reaches only the new bundle there. (An install was left
    # with the .runtime copy the app had been running from still listed.)
    if [[ -d "$bundle" ]]; then
        "$LSREGISTER" -u "$bundle" >/dev/null 2>&1 || true
    fi
    rm -rf "$bundle"
    mv "$staged" "$bundle"
    rmdir "$staging" 2>/dev/null || true
    if is_installed "$product"; then
        # Only the installed copy may be found by bundle identifier.
        "$LSREGISTER" -u "$bundle" >/dev/null 2>&1 || true
    else
        # Refresh LaunchServices' cached copy of the Info.plist (name, icon,
        # LSEnvironment) now rather than whenever it next notices the change.
        "$LSREGISTER" -f "$bundle" >/dev/null 2>&1 || true
    fi
    echo "Built $product.app ($CONFIGURATION, signed $(describe_identity))."
    if [[ "$SIGN_IDENTITY" == "-" && "$product" == "AIREMonitorApp" ]]; then
        APP_SIGNED_AD_HOC=true
    fi
}

cleanup() {
    local dir
    for dir in ${STAGING_DIRS[@]+"${STAGING_DIRS[@]}"}; do
        rm -rf "$dir"
    done
}

# --- Main -----------------------------------------------------------------

CONFIGURATION="release"
OPEN_FIRST=false
FOR_INSTALL=false
PRODUCTS=()
for argument in "$@"; do
    case "$argument" in
        --debug) CONFIGURATION="debug" ;;
        --release) CONFIGURATION="release" ;;
        --open) OPEN_FIRST=true ;;
        --for-install) FOR_INSTALL=true ;;
        -h | --help)
            usage
            exit 0
            ;;
        -*) die "unknown option '$argument' (see --help)." ;;
        *)
            product="$(canonical_product "$argument")" ||
                die "unknown product '$argument'; expected AIREMonitorApp (app) or AIREDesktopWidget (widget)."
            case " ${PRODUCTS[*]-} " in
                *" $product "*) ;;
                *) PRODUCTS+=("$product") ;;
            esac
            ;;
    esac
done
(( ${#PRODUCTS[@]} > 0 )) || die "no product given (see --help)."

# .runtime holds logs, pid files and snapshot caches that are nobody else's
# business on a shared Mac: create it private when it does not exist yet.
if [[ ! -d "$RUNTIME_DIR" ]]; then
    (umask 077 && mkdir -p "$RUNTIME_DIR")
fi

# One build of this checkout at a time: a second launcher (a double-clicked
# Widget button, or run_macos_app.sh while the widget builds) waits here
# rather than racing on the bundles. lockf holds the lock for this process
# only; the apps it opens do not inherit it.
if [[ -z "${HPC_BUILD_BUNDLE_LOCKED:-}" && -x /usr/bin/lockf ]]; then
    lock_status=0
    HPC_BUILD_BUNDLE_LOCKED=1 /usr/bin/lockf -k -s -t "$LOCK_TIMEOUT_SECONDS" \
        "$RUNTIME_DIR/.build_bundle.lock" "${BASH:-/bin/bash}" "$SCRIPT_PATH" "$@" || lock_status=$?
    if (( lock_status == 75 )); then
        echo "error: another build of this checkout has been running for over $LOCK_TIMEOUT_SECONDS s; try again when it finishes." >&2
    fi
    exit "$lock_status"
fi
unset HPC_BUILD_BUNDLE_LOCKED

if [[ -n "${HPC_BUILD_LOG:-}" ]]; then
    case "$HPC_BUILD_LOG" in
        /*) BUILD_LOG="$HPC_BUILD_LOG" ;;
        *) BUILD_LOG="$PWD/$HPC_BUILD_LOG" ;;
    esac
elif [[ "${PRODUCTS[*]}" == "AIREDesktopWidget" ]]; then
    BUILD_LOG="$RUNTIME_DIR/swift-widget-build.log"
else
    BUILD_LOG="$RUNTIME_DIR/swift-build.log"
fi
start_build_log

cd "$ROOT_DIR"
for resource in "${BUNDLE_RESOURCES[@]}"; do
    [[ -f "$ROOT_DIR/assets/$resource" ]] || die "assets/$resource is missing; is this a complete checkout?"
done

# Build outside the project volume, in the per-user Darwin temp directory
# (mode 700, never shared or world-writable): sync and backup tools watching
# the project break llbuild's SQLite database mid-build. The directory name
# predates the rename and is kept so the existing package cache is reused.
USER_TMP="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "$RUNTIME_DIR/")"
BUILD_DIR="${HPC_SWIFTPM_BUILD_DIR:-${AIRE_SWIFTPM_BUILD_DIR:-${USER_TMP%/}/aire-monitor-build}}"
BIN_DIR="$BUILD_DIR/$CONFIGURATION"
LSREGISTER="${HPC_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
STAGING_DIRS=()
RESTART_PRODUCTS=()
APP_SIGNED_AD_HOC=false
trap cleanup EXIT

# The app's bundle is an install source when install_app.sh says so, or
# when an install exists (see the header).
APP_IS_INSTALL_SOURCE=false
INSTALLED_APP=""
case " ${PRODUCTS[*]} " in
    *" AIREMonitorApp "*)
        if INSTALLED_APP="$("${BASH:-/bin/bash}" "$ROOT_DIR/scripts/install_app.sh" --installed-path 2>/dev/null)"; then
            APP_IS_INSTALL_SOURCE=true
        else
            INSTALLED_APP=""
            [[ "$FOR_INSTALL" == false ]] || APP_IS_INSTALL_SOURCE=true
        fi
        ;;
esac

resolve_version
resolve_signing_identity
run_swift_build

for product in "${PRODUCTS[@]}"; do
    install_bundle "$product"
done
if [[ "$APP_SIGNED_AD_HOC" == true && "$SIGN_IDENTITY_SOURCE" == "default" ]]; then
    echo "note: the app is signed ad hoc, so Keychain may ask again for the saved password after this rebuild; see sign_bundle in scripts/build_bundle.sh to set up a stable signing identity." >&2
fi

# Bring back what was stopped for the swap, then open the requested product
# last so it ends up in front.
for product in ${RESTART_PRODUCTS[@]+"${RESTART_PRODUCTS[@]}"}; do
    if [[ "$OPEN_FIRST" == true && "$product" == "${PRODUCTS[0]}" ]]; then
        continue
    fi
    echo "Restarting $product on the new build."
    launch_bundle "$RUNTIME_DIR/$product.app" "$product"
done
if [[ "$OPEN_FIRST" == true ]]; then
    if is_installed "${PRODUCTS[0]}"; then
        echo "note: not opening .runtime/${PRODUCTS[0]}.app: the app is installed at $INSTALLED_APP. scripts/install_app.sh (or run_macos_app.sh) updates and opens that copy." >&2
    elif is_install_source "${PRODUCTS[0]}"; then
        echo "note: not opening .runtime/${PRODUCTS[0]}.app: with --for-install it is only what scripts/install_app.sh installs, and that script opens the installed copy." >&2
    else
        launch_bundle "$RUNTIME_DIR/${PRODUCTS[0]}.app" "${PRODUCTS[0]}"
    fi
fi
