# Sourced (bash) by every script that runs SwiftPM: scripts/build_bundle.sh,
# scripts/test_all.sh and Tests/AIREMonitorAppTests/run_tests.sh. It keeps
# them building on a Mac with only the Command Line Tools, whose macOS 27.2
# release (Swift 6.4) broke the build in two ways:
#
#   if hpc_swiftpm_offers_native_build_system; then args+=(--build-system native); fi
#   hpc_swiftpm_select_sdk
#
# 1. SwiftPM 6.4 builds with the Swift Build engine by default. That engine
#    compiles SwiftTerm's Metal shader (Sources/SwiftTerm/Apple/Metal/
#    Shaders.metal, a `.process` resource since SwiftTerm 1.12), which needs a
#    Metal toolchain the Command Line Tools do not include ("unable to spawn
#    process 'metal'"), and it lays products out under out/Products/
#    <Configuration> instead of <scratch>/<configuration>. The app never turns
#    on SwiftTerm's Metal renderer (it is off unless setUseMetal(true) is
#    called), and build_bundle.sh expects the native layout, so the scripts ask
#    for the native build system whenever this SwiftPM still offers it. An
#    older SwiftPM, without the choice, already uses it.
#
# 2. The macOS 27.2 SDK declares SwiftUI's @State as a macro implemented by
#    the SwiftUIMacros compiler plugin, which ships with Xcode but not with the
#    Command Line Tools: every view with @State fails with "plugin for module
#    'SwiftUIMacros' not found". The same Command Line Tools still carry the
#    macOS 26.5 SDK, whose @State is the plain property wrapper, so
#    hpc_swiftpm_select_sdk builds against the newest SDK that works. The
#    deployment target (macOS 13) does not change.

# `swift build --help`, unwrapped: ArgumentParser wraps the help to COLUMNS,
# and a narrow terminal would split the phrases matched below. The text goes
# through a variable, not a pipe: under `set -o pipefail` a `grep -q` that
# stops reading early would fail the whole pipeline.
hpc_swiftpm_build_help() {
    COLUMNS=500 swift build --help 2>/dev/null || true
}

# Succeeds when SwiftPM lists the native build system.
hpc_swiftpm_offers_native_build_system() {
    local help
    help="$(hpc_swiftpm_build_help)"
    [[ "$help" == *"Native Build System"* ]]
}

# Succeeds when SwiftPM builds with Swift Build unless told otherwise, so
# products land under out/Products/ rather than <scratch>/<configuration>/.
hpc_swiftpm_defaults_to_swift_build() {
    local help
    help="$(hpc_swiftpm_build_help)"
    [[ "$help" == *"(default: swiftbuild)"* ]]
}

# Succeeds when the SDK at $1 declares SwiftUI's @State as a macro (the
# macOS 27.2 SDK does), which needs the SwiftUIMacros compiler plugin. Older
# SDKs also implement a few rarely used macros (@Entry, ...) in that plugin;
# the app uses none of them, so only @State counts.
hpc_sdk_has_state_macro() {
    local interface
    for interface in "$1"/System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule/*-apple-macos.swiftinterface; do
        [[ -f "$interface" ]] || continue
        grep -q 'type: "StateMacro"' "$interface"
        return
    done
    return 1
}

# Exports SDKROOT as the newest Command Line Tools SDK that builds the app,
# and says so on stderr, when all of these hold: the Command Line Tools are
# the active developer directory, they have no SwiftUIMacros plugin, and the
# SDK in use needs one. That SDK is SDKROOT when it is set — shells often
# export it as the generic MacOSX.sdk, which now links to the 27.2 SDK — or
# SwiftPM's default. Otherwise does nothing, so Xcode, an SDKROOT that builds
# and a later Command Line Tools release that ships the plugin are kept.
hpc_swiftpm_select_sdk() {
    local clt="/Library/Developer/CommandLineTools"
    local developer current candidate version minor rank best="" best_rank=-1
    developer="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
    [[ "$developer" == "$clt"* ]] || return 0
    if compgen -G "$clt/usr/lib/swift/host/plugins/*SwiftUIMacros*" >/dev/null; then
        return 0
    fi
    # SDKROOT may be a path or a name xcrun resolves ("macosx", "macosx27.2").
    current="${SDKROOT:-macosx}"
    if [[ ! -d "$current" ]]; then
        current="$(xcrun --sdk "$current" --show-sdk-path 2>/dev/null || true)"
    fi
    [[ -n "$current" ]] || return 0
    hpc_sdk_has_state_macro "$current" || return 0
    for candidate in "$clt"/SDKs/MacOSX[0-9]*.sdk; do
        [[ -d "$candidate" ]] || continue
        version="${candidate##*/MacOSX}"
        version="${version%.sdk}"
        [[ "$version" =~ ^[0-9]+(\.[0-9]+)?$ ]] || continue
        hpc_sdk_has_state_macro "$candidate" && continue
        minor=0
        if [[ "$version" == *.* ]]; then
            minor="${version#*.}"
        fi
        rank=$(( 10#${version%%.*} * 1000 + 10#$minor ))
        if (( rank > best_rank )); then
            best_rank=$rank
            best="$candidate"
        fi
    done
    [[ -n "$best" ]] || return 0
    export SDKROOT="$best"
    echo "note: building against ${best##*/} instead of ${current##*/}: that SDK's SwiftUI needs the SwiftUIMacros plugin, which the Command Line Tools do not include." >&2
}
