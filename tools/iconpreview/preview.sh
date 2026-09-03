#!/bin/zsh
# Compile the icon shaders for macOS and render a contact sheet.
# Development only — nothing here ships. See render.swift.
set -e
cd "$(dirname "$0")"

SHADERS=../../Addit/Shaders
OUT=$(mktemp -d)

build() {
  local name=$1
  xcrun -sdk macosx metal -c "$SHADERS/$name.metal" -I "$SHADERS" -o "$OUT/$name.air"
  xcrun -sdk macosx metallib "$OUT/$name.air" -o "$OUT/$name.metallib"
}

echo "▸ Compiling…"
build MenuIcons

echo "▸ Rendering…"
swift render.swift "$OUT/MenuIcons.metallib" menu-icons.png 10 menuIconKernel

echo "✓ menu-icons.png"

build GlassLogo
swift render.swift "$OUT/GlassLogo.metallib" provider-marks.png 3 glassLogoKernel
echo "✓ provider-marks.png"
