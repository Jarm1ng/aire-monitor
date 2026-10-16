#!/usr/bin/env bash
set -euo pipefail

SKIP_INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --skip-install|-SkipInstall)
            SKIP_INSTALL=1
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="$REPO_DIR/.venv/bin/python"

if [[ ! -x "$PYTHON" ]]; then
    python3 -m venv "$REPO_DIR/.venv"
fi

if [[ "$SKIP_INSTALL" -eq 0 ]]; then
    "$PYTHON" -m pip install -r "$REPO_DIR/linux/requirements-dev.txt"
fi

cd "$REPO_DIR"

"$PYTHON" -m PyInstaller --noconfirm --clean --windowed --noupx --onedir \
    --name LeedsHPCMonitor --paths linux --paths scripts \
    --hidden-import keyring.backends.SecretService \
    --hidden-import keyring.backends.kwallet \
    --hidden-import secretstorage \
    --hidden-import jeepney \
    --copy-metadata keyring \
    --distpath linux/dist --workpath linux/build --specpath linux \
    --add-data "$REPO_DIR/LICENSE:." \
    --add-data "$REPO_DIR/linux/THIRD_PARTY_NOTICES.md:." \
    linux/main.py

OUTPUT_DIR="$REPO_DIR/linux/dist"
cp "$REPO_DIR/LINUX_APP.md" "$OUTPUT_DIR/LeedsHPCMonitor/LINUX_APP.md"
"$PYTHON" "$REPO_DIR/linux/collect_licenses.py" "$OUTPUT_DIR/LeedsHPCMonitor/licenses"

QT_QPA_PLATFORM=offscreen timeout 30s "$OUTPUT_DIR/LeedsHPCMonitor/LeedsHPCMonitor" --smoke-test

RAW_ARCH="${LEEDS_HPC_ARCH:-$(uname -m)}"
case "$RAW_ARCH" in
    x86_64|amd64)
        ARCH_TAG="x64"
        ;;
    aarch64|arm64)
        ARCH_TAG="arm64"
        ;;
    *)
        ARCH_TAG="$RAW_ARCH"
        ;;
esac

ARCHIVE="$OUTPUT_DIR/LeedsHPCMonitor-Linux-${ARCH_TAG}.tar.gz"
tar -C "$OUTPUT_DIR" -czf "$ARCHIVE" LeedsHPCMonitor
sha256sum "$ARCHIVE"
