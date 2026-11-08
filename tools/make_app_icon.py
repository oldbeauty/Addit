#!/usr/bin/env python3
"""Regenerate Addit/AppIcon.icon.

    python3 tools/make_app_icon.py [--span 0.25] [--preview out.png]

The icon is white with a black plus in its bottom-right corner (2026-10-27).
Before that it was the dot field `AdditStructure` describes, which an earlier
version of this script baked to SVG.

`--span` is the plus's width as a share of the icon's. Its arms are `WEIGHT`
of that thick, round-ended (square for its first day), and its tips sit
`MARGIN` in from the right and bottom edges whatever its size, so a bigger
plus grows in from the corner.

Left to Icon Composer, the home screen's other styles lose the plus:

* Dark turns a solid fill dark and keeps the layer's black. The fill is pinned
  white in dark too, through `fill-specializations` — which is ignored when a
  plain `fill` is also there, so there isn't one.
* Tinted and Clear lay their own ground and read the layer by its colour, and
  black reads as nothing. In those the plus is white, which they tint or glaze.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys

CANVAS = 1024.0
SPAN = 0.25     # the plus's width, as a share of the icon's
WEIGHT = 0.2    # its arms' thickness, as a share of its width
MARGIN = 0.11   # its tips' distance from the right and bottom edges, of the icon's

WHITE = "srgb:1.00000,1.00000,1.00000,1.00000"
PLUS = "#000000"

ICON_PATH = "Addit/AppIcon.icon"


def build_svg(span):
    """The plus as two capsules crossed on the whole canvas, centred on the
    diagonal, so the layer needs no position of its own. Each arm's round
    end reaches the same tip the square one did."""
    width = span * CANVAS
    thick = WEIGHT * width
    c = CANVAS * (1 - MARGIN) - width / 2
    a, b = c - width / 2, c - thick / 2
    arm = '<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" rx="%.2f" fill="%s"/>'
    across = arm % (a, b, width, thick, thick / 2, PLUS)
    down = arm % (b, a, thick, width, thick / 2, PLUS)
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
            'viewBox="0 0 1024 1024">\n  %s\n  %s\n</svg>\n' % (across, down))


def write_icon(path, span=SPAN):
    if os.path.exists(path):
        shutil.rmtree(path)
    os.makedirs(os.path.join(path, "Assets"))
    with open(os.path.join(path, "Assets", "plus.svg"), "w") as f:
        f.write(build_svg(span))
    with open(os.path.join(path, "icon.json"), "w") as f:
        json.dump({
            "fill-specializations": [
                {"value": {"solid": WHITE}},
                {"appearance": "dark", "value": {"solid": WHITE}},
            ],
            "groups": [{
                "layers": [{
                    "image-name": "plus.svg",
                    "name": "Plus",
                    "fill-specializations": [
                        {"appearance": "tinted", "value": {"solid": WHITE}},
                    ],
                }],
                "shadow": {"kind": "neutral", "opacity": 0.5},
                "translucency": {"enabled": False, "value": 0.5},
            }],
            "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
        }, f, indent=2)


def ictool():
    developer = subprocess.check_output(["xcode-select", "-p"]).decode().strip()
    return os.path.join(developer, "..", "Applications", "Icon Composer.app",
                        "Contents", "Executables", "ictool")


def preview(path, out, size=512, rendition="Default"):
    subprocess.run([ictool(), path, "--export-image", "--output-file", out,
                    "--platform", "iOS", "--rendition", rendition,
                    "--width", str(size), "--height", str(size), "--scale", "1"],
                   check=True, capture_output=True)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--path", default=ICON_PATH, help="icon bundle to write")
    ap.add_argument("--span", type=float, default=SPAN,
                    help="the plus's width as a share of the icon's")
    ap.add_argument("--preview", help="also export a PNG here")
    ap.add_argument("--size", type=int, default=512)
    ap.add_argument("--rendition", default="Default",
                    help="Default, Dark, TintedLight, TintedDark, ClearLight, ClearDark")
    args = ap.parse_args()

    write_icon(args.path, args.span)
    print("wrote %s" % args.path, file=sys.stderr)
    if args.preview:
        preview(args.path, args.preview, args.size, args.rendition)
        print("preview %s" % args.preview, file=sys.stderr)
