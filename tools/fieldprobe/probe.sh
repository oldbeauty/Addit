#!/bin/zsh
# Compile the analysis kernel for macOS and step the real pipeline through a
# launch. Development only — nothing here ships. See main.swift.
#
#   ./probe.sh [seconds] [seed]
set -e
cd "$(dirname "$0")"

SHADERS=../../Addit/Shaders
OUT=$(mktemp -d)

# -I the shaders directory so FieldAnalysis.metal's #include of
# RippleSurface.h resolves — the same water the app draws.
xcrun -sdk macosx metal -c "$SHADERS/FieldAnalysis.metal" -I "$SHADERS" -o "$OUT/Probe.air"
xcrun -sdk macosx metallib "$OUT/Probe.air" -o "$OUT/Probe.metallib"

# The shipping analysis, compiled as-is rather than copied.
# FieldSampler.swift comes along for its `lattice` — the tool has to index the
# same grid the app does, and reimplementing that rule here is exactly the kind
# of drift this tool exists to catch.
swiftc -O main.swift \
  ../../Addit/Utilities/FieldAnalysis.swift \
  ../../Addit/Utilities/FieldSampler.swift \
  -o "$OUT/fieldprobe"
"$OUT/fieldprobe" "$OUT/Probe.metallib" "${1:-2.4}" "${2:-0}"
