#!/bin/zsh
# Compile the launch screen's shaders for macOS and render every colorway.
# Development only — nothing here ships. See render.swift.
#
#   ./preview.sh [seconds-into-the-fill] [output-dir]
set -e
cd "$(dirname "$0")"

SHADERS=../../Addit/Shaders
OUT=$(mktemp -d)

echo "▸ Compiling…"
# -I the shaders directory so Preview.metal's #includes of the two shipping
# files resolve, and so their own #include "Colorways.h" does too.
xcrun -sdk macosx metal -c Preview.metal -I "$SHADERS" -o "$OUT/Preview.air"
xcrun -sdk macosx metallib "$OUT/Preview.air" -o "$OUT/Preview.metallib"

echo "▸ Rendering…"
OUTDIR=${2:-.}
mkdir -p "$OUTDIR"
swift render.swift "$OUT/Preview.metallib" "${1:-2.1}" "$OUTDIR"
