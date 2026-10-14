#!/usr/bin/env bash
# Renders offscreen PNG screenshots of the app's main surfaces in dark and
# light mode, using real snapshot data: the overview, every cluster tab,
# Nodes at the minimum window and at 1100/1220 x 760, the menu bar dropdown,
# the job sheet (also for a pending array remainder), the sign-in states,
# the status strip for each refresh failure kind (and with Details open),
# a paused cluster's Trends, and the Files tab over a fake remote. Useful
# for reviewing layout when a screen capture is not possible. No SSH,
# Keychain or runtime writes: the Files render answers every remote command
# itself and downloads nothing.
#
#   scripts/render_previews.sh [output-dir] [data-dir]
#
# output-dir defaults to .runtime/previews; data-dir defaults to
# .runtime/clusters (the app's own per-cluster snapshot cache), so the
# renders show your current jobs and quotas. Keep the output out of git.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$ROOT_DIR/.runtime/previews}"
DATA_DIR="${2:-$ROOT_DIR/.runtime/clusters}"

# Both paths are made absolute HERE, against the caller's working directory:
# run_tests.sh changes into the checkout before `swift test`, so a relative
# path would otherwise name a different folder in the tests (PNGs written
# inside the checkout, and a data folder that silently falls back to the
# bundled fixtures).
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
if [[ -d "$DATA_DIR" ]]; then
    DATA_DIR="$(cd "$DATA_DIR" && pwd)"
elif [[ -n "${2:-}" ]]; then
    echo "render_previews.sh: data folder not found: $DATA_DIR" >&2
    exit 1
fi
# A missing default data folder (the app never ran here) is fine: the
# renders then use the bundled fixtures.

HPC_RENDER_PREVIEWS="$OUT_DIR" HPC_PREVIEW_DATA="$DATA_DIR" \
    "$ROOT_DIR/Tests/AIREMonitorAppTests/run_tests.sh" --filter PreviewRenderTests
echo "Previews written to $OUT_DIR"
