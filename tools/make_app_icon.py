#!/usr/bin/env python3
"""Regenerate Addit/AppIcon.icon.

    python3 tools/make_app_icon.py [--preview out.png]

The icon is a lattice of dots on a plane that bulges out of two opposite
corners and sinks into the other two. It is the same surface `AdditStructure`
describes in Swift, projected head-on — keep the constants below in step with
`AdditStructure.Parameters` or the home-screen icon and anything drawing
`StructureView` stop being the same object.

Deliberate choices, each of which replaced something that looked wrong:

* Dot radius comes from the distance to a dot's own projected neighbours, not
  from a power of the perspective factor. Spacing grows with the perspective
  factor, so any radius that grows faster eventually swallows the gaps and the
  crown merges into a blob.
* The bulge is carried by dot *size*, not by displacement. Perspective
  magnification alone is physically right and visually wrong: a magnifier over
  a lattice shows fewer, larger dots, so the raised area thins out and reads as
  a hole rather than as something pushing forward.
* Domes are raised cosines — zero slope at both peak and rim. A Gaussian's
  flanks are steep enough that projection rarefies them into a visible void.
* The camera sits far back. Up close, perspective drags raised dots away from
  the view axis and stretches each bulge into a comet shape.
* The plane is generated well past the frame (`EXTENT` against `VISIBLE`) so
  its own border is never inside the icon.
"""
import argparse
import json
import math
import os
import shutil
import subprocess
import sys

CANVAS = 1024.0
CENTER = CANVAS / 2

# --- surface (mirror of AdditStructure.Parameters) ---------------------------
STEP = 0.088          # lattice spacing, model units
EXTENT = 2.0          # half-width of the generated plane
VISIBLE = 1.30        # half-extent mapped to half the canvas
CAMERA = 8.0          # eye distance from the origin
DOT_RATIO = 0.16      # base radius as a fraction of the neighbour gap
SWELL = 2.8           # extra radius at a crown, as a multiple of DOT_RATIO
MAX_FILL = 0.46       # ceiling on radius as a fraction of the neighbour gap
MIN_RADIUS = 1.0      # px

# (centre_x, centre_y, height, radius). Positive height bulges toward the
# viewer, negative sinks away. Both diagonals carry a matched pair, which is
# what lets all four sit this close to the edge without looking lopsided.
# Pits are deepened relative to crowns because shrinking dots read as weaker
# than growing ones — symmetric values look asymmetric.
DOMES = [
    (0.60, 0.60, 1.00, 0.66),     # top-right, out
    (-0.60, -0.60, 1.00, 0.66),   # bottom-left, out
    (-0.60, 0.60, -1.15, 0.66),   # top-left, in
    (0.60, -0.60, -1.15, 0.66),   # bottom-right, in
]

DOT = "#FFFFFF"
BACKGROUND = "srgb:0.055,0.055,0.059,1.000"

ICON_PATH = "Addit/AppIcon.icon"


def height(x, y):
    """Summed displacement of every dome. Summing rather than max()-ing stays
    well-defined if two are ever moved close enough to overlap."""
    total = 0.0
    for (bx, by, amp, radius) in DOMES:
        d = math.hypot(x - bx, y - by)
        if d >= radius:
            continue
        total += amp * 0.5 * (1 + math.cos(math.pi * d / radius))
    return total


def size_factor(h):
    """`h` is height normalised to the deepest excursion: +1 crown, -1 pit.

    Crowns multiply and pits divide, so the two are exact inverses. A linear
    `1 + SWELL*h` would go negative past h = -1/SWELL, and clamping that at
    zero flattens a pit's floor into one dead value instead of keeping the
    gradient that makes it read as a depression."""
    return 1 + SWELL * h if h >= 0 else 1 / (1 + SWELL * -h)


def build_svg():
    side = int(round(2 * EXTENT / STEP)) + 1
    peak = max(abs(d[2]) for d in DOMES)

    projected = []
    for iy in range(side):
        for ix in range(side):
            x = -EXTENT + STEP * ix
            y = -EXTENT + STEP * iy
            z = height(x, y)
            f = CAMERA / (CAMERA - z)
            projected.append((CENTER + x * f * (CENTER / VISIBLE),
                              CENTER - y * f * (CENTER / VISIBLE), z))

    def gap(a, b):
        return math.hypot(projected[a][0] - projected[b][0],
                          projected[a][1] - projected[b][1])

    items = []
    for iy in range(side):
        for ix in range(side):
            i = iy * side + ix
            px, py, z = projected[i]
            if not (-80 <= px <= CANVAS + 80 and -80 <= py <= CANVAS + 80):
                continue
            neighbours = []
            if ix + 1 < side: neighbours.append(gap(i, i + 1))
            if ix > 0: neighbours.append(gap(i, i - 1))
            if iy + 1 < side: neighbours.append(gap(i, i + side))
            if iy > 0: neighbours.append(gap(i, i - side))
            if not neighbours:
                continue
            g = min(neighbours)
            r = max(min(DOT_RATIO * g * size_factor(z / peak), MAX_FILL * g), MIN_RADIUS)
            items.append((z, '  <circle cx="%.2f" cy="%.2f" r="%.2f" fill="%s"/>'
                          % (px, py, r, DOT)))

    items.sort(key=lambda it: it[0])          # painter's algorithm: far first
    body = "\n".join(s for _, s in items)
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
            'viewBox="0 0 1024 1024">\n%s\n</svg>\n' % body)


def write_icon(path):
    if os.path.exists(path):
        shutil.rmtree(path)
    os.makedirs(os.path.join(path, "Assets"))
    with open(os.path.join(path, "Assets", "mark.svg"), "w") as f:
        f.write(build_svg())
    with open(os.path.join(path, "icon.json"), "w") as f:
        json.dump({
            "fill": {"automatic-gradient": BACKGROUND},
            "groups": [{
                "layers": [{"image-name": "mark.svg", "name": "Field"}],
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
    ap.add_argument("--preview", help="also export a PNG here")
    ap.add_argument("--size", type=int, default=512)
    ap.add_argument("--rendition", default="Default",
                    help="Default, Dark, TintedLight, TintedDark, ClearLight, ClearDark")
    args = ap.parse_args()

    write_icon(args.path)
    print("wrote %s" % args.path, file=sys.stderr)
    if args.preview:
        preview(args.path, args.preview, args.size, args.rendition)
        print("preview %s" % args.preview, file=sys.stderr)
