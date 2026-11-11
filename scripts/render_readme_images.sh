#!/usr/bin/env bash
# Renders the README's screenshots into docs/images/: the overview and Jobs
# windows (dark and light), Nodes, Trends, a job's resource use, the
# Sessions card and the menu bar dropdown. They are drawn offscreen from
# the checked-in fixtures plus demo data (Tests/AIREMonitorAppTests/
# ReadmeScreenshotTests.swift), never from .runtime/, so no real account,
# job or path can end up in the repository.
#
#   scripts/render_readme_images.sh
#
# Needs a logged-in macOS session (a window server). The renders are 2x;
# this scales each to the width the README needs and, when zopflipng is
# installed, recompresses it losslessly.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/docs/images"
RAW_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hpc-readme-images.XXXXXX")"
trap 'rm -rf "$RAW_DIR"' EXIT

HPC_RENDER_README="$RAW_DIR" \
    "$ROOT_DIR/Tests/AIREMonitorAppTests/run_tests.sh" --filter ReadmeScreenshotTests

# Rewrites a PNG's image data as one zlib stream at level 9. ImageIO's own
# PNGs are valid but use streams zopflipng's decoder sometimes rejects
# ("invalid ADLER32"); this also shrinks them when zopflipng is missing.
restream_png() {
    /usr/bin/python3 -I - "$1" <<'PY'
import struct, sys, zlib
path = sys.argv[1]
data = open(path, "rb").read()
pos, chunks, idat = 8, [], b""
while pos < len(data):
    length, kind = struct.unpack(">I4s", data[pos:pos + 8])
    body = data[pos + 8:pos + 8 + length]
    if kind == b"IDAT":
        if not idat:
            chunks.append((kind, None))
        idat += body
    else:
        chunks.append((kind, body))
    pos += 12 + length
pixels = zlib.compress(zlib.decompress(idat), 9)
out = [data[:8]]
for kind, body in chunks:
    body = pixels if kind == b"IDAT" else body
    out.append(struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF))
open(path, "wb").write(b"".join(out))
PY
}

mkdir -p "$OUT_DIR"
# name and target width in pixels (the README shows them at half that).
while read -r name width; do
    [[ -n "$name" ]] || continue
    source="$RAW_DIR/$name.png"
    [[ -f "$source" ]] || { echo "missing render: $name" >&2; exit 1; }
    target="$OUT_DIR/$name.png"
    cp "$source" "$target"
    current="$(sips -g pixelWidth "$target" | awk '/pixelWidth/ {print $2}')"
    if (( current > width )); then
        sips --resampleWidth "$width" "$target" >/dev/null
    fi
    restream_png "$target"
    if command -v zopflipng >/dev/null 2>&1; then
        zopflipng -y --lossy_transparent "$target" "$target" >/dev/null 2>&1 ||
            echo "note: zopflipng could not optimise $name.png; kept the restreamed file" >&2
    fi
    printf '%-24s %6s KB\n' "$name.png" "$(( $(stat -f %z "$target") / 1024 ))"
done <<'LIST'
overview-dark 2000
overview-light 2000
jobs-dark 2000
jobs-light 2000
nodes-dark 2000
trends-dark 2000
job-usage-dark 1300
sessions-dark 760
menubar-dark 680
LIST
echo "README images written to docs/images/"
