#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="$REPO_DIR/.venv/bin/python"

if [[ ! -x "$PYTHON" ]]; then
    echo "Create the environment first: python3 -m venv .venv && ./.venv/bin/python -m pip install -r linux/requirements.txt" >&2
    exit 1
fi

ARGS=("$REPO_DIR/linux/main.py")
for arg in "$@"; do
    if [[ "$arg" == "-Demo" ]]; then
        ARGS+=("--demo")
    else
        ARGS+=("$arg")
    fi
done

exec "$PYTHON" "${ARGS[@]}"
