#!/bin/zsh
# Lay a set of synthetic covers out with the library's "Sort by Color" and
# write a contact sheet beside the naive hue sort. Development only — nothing
# here ships. See main.swift.
#
#   ./preview.sh [seed] [count]
set -e
cd "$(dirname "$0")"

OUT=$(mktemp -d)
echo "▸ Compiling…"
xcrun -sdk macosx swiftc -O ../../Addit/Utilities/ColorSort.swift main.swift -o "$OUT/render"
echo "▸ Rendering…"
"$OUT/render" color-sort.png "${1:-7}" "${2:-60}"
echo "✓ color-sort.png"
