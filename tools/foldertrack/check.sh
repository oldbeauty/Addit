#!/bin/zsh
# Check folder tracking's rules against the shipping model — what counts as
# new, baselines, the grow-only snapshot, event grouping and wording, the
# file format, and how a check splits batches the drive turns down.
# Development only — nothing here ships. See main.swift.
#
#   ./check.sh
set -e
cd "$(dirname "$0")"

OUT=$(mktemp -d)
echo "▸ Compiling…"
xcrun -sdk macosx swiftc -O ../../Addit/Models/FolderWatch.swift main.swift -o "$OUT/check"
echo "▸ Checking…"
"$OUT/check"
