#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
#include "GlassRoom.h"

using namespace metal;

// The library selector's three brand marks, as solid glass.
//
// Each one is the flat mark's outline extruded into a slab with a bevelled
// edge, then raymarched and lit by `GlassRoom.h`. Extrusion rather than a
// sculpt is the whole trick: seen face-on the silhouette is exactly the 2D
// logo, so the selector still reads as Drive / OneDrive / on-device at a
// glance, and it is only when the scroll turns it that there is any depth to
// see. Anything freer would have been a nicer object and a worse sign.
//
// Colour is a tint applied to the glass, not paint on a surface: the room is
// reflected and refracted as normal and then filtered through the mark's own
// colours, which is why the Drive mark's three limbs stay green / blue /
// yellow through every angle instead of sliding around as the light moves.
//
// One entry point for all three, branching on `shape`. The branch is uniform
// across every pixel of a draw, so it costs nothing on the GPU, and it keeps
// the marcher, the antialiasing and the tone map identical between the marks —
// which is what makes them look like a set.

constant int kDrive = 0;    // Google Drive: rounded triangle ring
constant int kCloud = 1;    // OneDrive: cloud with a swoosh crease
constant int kSlab  = 2;    // Local: internal drive

// MARK: - 2D profiles

/// iq's equilateral triangle: apex up, centroid at the origin, side `2r`.
static float sdTriangle(float2 p, float r) {
    const float k = sqrt(3.0);
    p.x = abs(p.x) - r;
    p.y = p.y + r / k;
    if (p.x + k * p.y > 0.0) { p = float2(p.x - k * p.y, -k * p.x - p.y) / 2.0; }
    p.x -= clamp(p.x, -2.0 * r, 0.0);
    return -length(p) * sign(p.y);
}

static float sdCircle(float2 p, float2 c, float r) {
    return length(p - c) - r;
}

static float sdRoundBox(float2 p, float2 halfSize, float r) {
    float2 q = abs(p) - halfSize + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

static float smoothMin(float a, float b, float k) {
    float h = saturate(0.5 + 0.5 * (b - a) / k);
    return mix(b, a, h) - k * h * (1.0 - h);
}

static float smoothMax(float a, float b, float k) {
    return -smoothMin(-a, -b, k);
}

/// Signed distance to the flat mark at `p`, in a frame where the mark spans
/// roughly ±0.95 across its long axis.
static float logoProfile(float2 p, int shape) {
    if (shape == kDrive) {
        // Both edges of the ring come off the *same* triangle field, one
        // isoline outside it and one inside, which is why they stay concentric
        // and the limbs stay an even width. Offsetting outwards rounds corners
        // and offsetting inwards keeps them sharp — exactly the asymmetry the
        // real mark has, for free.
        // Pushed down off its centroid so the mark sits on the *middle of its
        // bounding box*, which is where the flat artwork sat — a triangle's
        // centroid is a third of the way up, so centring on it would hang the
        // mark high in the capsule.
        float t = sdTriangle(p + float2(0.0, 0.179), 0.62);
        return max(t - 0.235, -(t + 0.145));
    }
    if (shape == kCloud) {
        // OneDrive's cloud, four lobes rather than three.
        //
        // The mark is not a symmetric puff: it is a tall dome left of centre, a
        // lower and wider dome to its right, and a low shoulder at each end, so
        // the skyline rises, dips, and rises again to a lower second peak. Three
        // equal-ish lobes gave a generic cartoon cloud because they left only
        // one peak — the second, lower crest is the part that identifies it.
        //
        // Lobes hang well below the cut on purpose: one merely *tangent* to the
        // slice leaves the bottom edge scalloped between lobes rather than
        // straight, which no cloud mark has.
        // `s` and the offset are not free: the lobes below span q ∈ [-0.78,
        // 0.86] × [-0.30, 0.68], and `s` is exactly what maps that half-width
        // onto the ±0.95 this function promises, with the offset putting the
        // shape's centre — not the lobes' origin — at p = 0. Move a lobe and
        // both have to be refitted, or the mark grows past the canvas and the
        // shader clips it into a flat edge.
        const float s = 1.159;
        float2 q = p / s + float2(0.04, 0.19);
        float d =        sdCircle(q, float2(-0.08,  0.12), 0.56);        // main dome
        d = smoothMin(d, sdCircle(q, float2( 0.40, -0.02), 0.40), 0.10); // second crest
        d = smoothMin(d, sdCircle(q, float2(-0.48, -0.10), 0.30), 0.10); // left shoulder
        d = smoothMin(d, sdCircle(q, float2( 0.62, -0.14), 0.24), 0.10); // right shoulder
        d = smoothMax(d, -0.30 - q.y, 0.08);
        return d * s;
    }
    float d = sdRoundBox(p, float2(0.80, 0.56), 0.16);
    return max(d, -sdCircle(p, float2(0.42, 0.0), 0.115));   // the drive's eye
}

/// Half-thickness of the slab at `p`. Constant except where a mark has a
/// feature that is a *crease* rather than an outline.
static float logoDepth(float2 p, int shape) {
    if (shape == kCloud) {
        // OneDrive's swoosh. Cut as a shallow trough rather than drawn as a
        // line, because on glass a trough is more legible than a stripe would
        // be: it bends the highlight that crosses it, so the mark's signature
        // curve appears in the *lighting* and survives the mark turning.
        // Sweeps up to the right rather than waving symmetrically across, which
        // is the direction the real swoosh runs — it separates the shadowed
        // back-left of the cloud from the lit front-right.
        float crease = 0.30 * p.x - 0.11 * sin(2.60 * p.x + 0.55) - 0.10;
        float band = exp(-pow((p.y - crease) / 0.15, 2.0));
        return 0.22 - 0.085 * band;
    }
    return shape == kDrive ? 0.19 : 0.24;
}

/// Bevel radius on the extruded edge. Must stay under half the thinnest limb
/// of the profile, or the bevel eats the mark from both sides at once — the
/// Drive ring is the binding constraint at 0.19 half-width.
static float logoBevel(int shape) {
    return shape == kDrive ? 0.075 : (shape == kCloud ? 0.095 : 0.100);
}

// MARK: - The slab

/// World space → the mark's own space. Shading needs this as well as the
/// marcher does, since the tint is keyed to where a point sits *on the mark*,
/// not to where it ended up on screen.
static float3 logoSpace(float3 p, float yaw, float pitch, float twist) {
    p.yz = spin2(p.yz, pitch);
    // Twist folded into the yaw as a function of height: the slab wrings along
    // its own axis instead of a finished shape being bent afterwards.
    p.xz = spin2(p.xz, yaw + twist * p.y);
    return p;
}

static float mapLogo(float3 p, float yaw, float pitch, float twist, int shape) {
    p = logoSpace(p, yaw, pitch, twist);

    float bevel = logoBevel(shape);
    // Rounded extrusion: shrink the profile and the depth by the bevel, then
    // give the result a radius back. The silhouette lands exactly where the
    // flat profile is, with the edge rolled over.
    float2 w = float2(logoProfile(p.xy, shape) + bevel,
                      abs(p.z) - (logoDepth(p.xy, shape) - bevel));
    float d = min(max(w.x, w.y), 0.0) + length(max(w, 0.0)) - bevel;

    // The twist stretches the field, and the crease displacement breaks its
    // Lipschitz bound outright; understating the step is far cheaper than the
    // banding that shows up when a ray tunnels through a thin slab.
    return d * 0.62 / (1.0 + abs(twist) * 0.50);
}

static float3 logoNormal(float3 p, float yaw, float pitch, float twist, int shape) {
    // Tetrahedral gradient: four taps instead of the six a central difference
    // costs, which matters when this runs for every pixel that hits.
    const float2 e = float2(1.0, -1.0) * 0.0018;
    return normalize(
        e.xyy * mapLogo(p + e.xyy, yaw, pitch, twist, shape) +
        e.yyx * mapLogo(p + e.yyx, yaw, pitch, twist, shape) +
        e.yxy * mapLogo(p + e.yxy, yaw, pitch, twist, shape) +
        e.xxx * mapLogo(p + e.xxx, yaw, pitch, twist, shape)
    );
}

// MARK: - Colour

/// Angular weight for a wedge centred on `centre`, wrapped properly. Built out
/// of sin/cos rather than a modulo so the seam at ±π is not a special case.
static float wedge(float angle, float centre) {
    float delta = angle - centre;
    float wrapped = abs(atan2(sin(delta), cos(delta)));
    // Full weight well past halfway to the neighbouring centre, then a short
    // blend. The seams sit 1.047 rad from each centre, so a falloff that starts
    // at 0.35 is already handing weight to two wedges over most of every limb —
    // which is why the mark came out as one green-to-yellow smear instead of
    // three colours meeting. Blending only across the last ~20° keeps Drive's
    // flat-artwork seams while still producing the cyan and violet the real
    // mark shows where its panels meet.
    return saturate(1.0 - (wrapped - 0.78) / 0.34);
}

/// The mark's own colour at `p`, as a filter rather than a paint — everything
/// the glass shows gets multiplied by this, so the values are keyed bright.
/// A literal brand hex used as a filter reads almost black.
static float3 logoTint(float2 p, int shape) {
    if (shape == kDrive) {
        // Three wedges from the centroid, seams pointing at the midpoints of
        // the sides — the same division the flat mark uses. They overlap, and
        // the overlap is the point: the blends where they meet are the cyan
        // and the violet the real mark fades through.
        float a = atan2(p.y + 0.179, p.x);      // the centroid, not the box
        float g = wedge(a,  1.57080);       // green, up
        float b = wedge(a, -2.61799);       // blue, lower left
        float y = wedge(a, -0.52360);       // yellow, lower right
        // Deeper than the brand hexes, not brighter. The room is near-white and
        // the tint multiplies it, so the panel's saturation is bounded by how
        // far the tint pulls each channel *down* — raising the low channels to
        // "look right" as swatches is what left the blue reading steel and the
        // yellow olive once the tone map rolled them off.
        float3 mixed = g * float3(0.10, 1.00, 0.34)
                     + b * float3(0.08, 0.40, 1.00)
                     + y * float3(1.00, 0.74, 0.02);
        return mixed / max(g + b + y, 0.001);
    }
    if (shape == kCloud) {
        float t = saturate(0.5 + 0.62 * (p.x * 0.55 + p.y * 0.85));
        return mix(float3(0.05, 0.34, 0.95), float3(0.28, 0.86, 1.00), t);
    }
    return float3(0.36, 0.43, 0.58);        // graphite, faintly cool
}

/// The room each mark is lit by. Neutral base, then sources in that mark's own
/// colours, so a reflection is already the right family before the tint gets
/// to it — tinting a magenta room green produces mud, not green glass.
static float3 logoRoom(float3 d, int shape) {
    d = normalize(d);

    // Few, broad strips: the mark's outline has to stay the loudest thing in
    // the frame at 20-odd points.
    float3 col = float3(0.22, 0.24, 0.30) * softbox(d, 0.62, 0.10) * 1.40;

    if (shape == kDrive) {
        // Neutral, and brighter to compensate.
        //
        // This room used to carry green, blue and yellow sources of its own.
        // That is what smeared the mark into one gradient: a source is keyed to
        // a *direction*, so every point on every limb reflects some of all
        // three, and the mix has nothing to do with which panel the point
        // belongs to. `logoTint` then multiplied a colour that was already
        // wrong. With the room white, the tint alone decides hue, and Drive's
        // three panels come out as three panels.
        // Brighter and broader than the coloured trio they replace. Those were
        // carrying most of the mark's light as well as its (wrong) colour, so
        // swapping them for neutral at the same intensity left the blue panel
        // reading navy and the yellow olive — a filter can only pass what the
        // room gives it.
        col += float3(1.90, 1.95, 2.05) * pow(saturate(dot(d, normalize(float3(-0.15,  0.80, 0.58)))), 2.2);
        col += float3(1.55, 1.60, 1.75) * pow(saturate(dot(d, normalize(float3( 0.62, -0.35, 0.60)))), 2.2);
    } else if (shape == kCloud) {
        col += float3(0.10, 0.55, 1.60) * pow(saturate(dot(d, normalize(float3(-0.55,  0.70, 0.45)))), 3.0);
        col += float3(0.20, 0.95, 1.50) * pow(saturate(dot(d, normalize(float3( 0.75, -0.30, 0.58)))), 3.0);
    } else if (shape == kSlab) {
        // Cool key, warm fill — the split that reads as polished metal rather
        // than as coloured plastic.
        col += float3(0.70, 0.82, 1.05) * pow(saturate(dot(d, normalize(float3(-0.50,  0.75, 0.42)))), 3.0);
        col += float3(1.00, 0.80, 0.62) * pow(saturate(dot(d, normalize(float3( 0.70, -0.35, 0.60)))), 3.0);
    }

    // Hard key, far over 1.0 so the tone map has something to blow out into a
    // hotspot as an edge rolls past it.
    col += float3(7.00) * pow(saturate(dot(d, normalize(float3(-0.32, 0.86, 0.40)))), 130.0);
    return col;
}

// MARK: - Entry point

[[ stitchable ]] half4 glassLogo(float2 position,
                                 half4 currentColor,
                                 float2 size,
                                 float yaw,
                                 float pitch,
                                 float twist,
                                 float shapeId) {
    int shape = int(shapeId + 0.5);

    float2 uv = (position - size * 0.5) / (min(size.x, size.y) * 0.5);
    uv.y = -uv.y;                       // SwiftUI is y-down; the mark is y-up.

    float3 ro = float3(0.0, 0.0, 3.0);
    float3 rd = normalize(float3(uv * 0.38, -1.0));

    float t = 0.0;
    float closest = 1e9;                // closest approach, for the soft edge

    // As with the orb, the hit threshold is far tighter than it looks like it
    // needs to be: a loose one stops each ray a slightly different distance
    // short of the surface, and the high-contrast lighting turns a fraction of
    // a percent of normal error into visible terracing across the flat faces —
    // where it is most obvious, since a flat face should be *one* colour.
    for (int i = 0; i < 90; i++) {
        float3 p = ro + rd * t;
        float d = mapLogo(p, yaw, pitch, twist, shape);
        closest = min(closest, d);
        if (d < 0.00012) { break; }
        t += d;
        if (t > 5.0) { break; }
    }

    // Rays that only grazed the mark get a sliver of coverage instead of being
    // dropped: that is the whole antialiasing scheme, and it is what keeps a
    // triangle's corners and a slab's straight edges clean at this size
    // without supersampling.
    float aa = 0.6 * (2.0 * 0.38 * 2.6) / min(size.x, size.y);
    float alpha = 1.0 - smoothstep(0.0, aa, closest);
    if (alpha <= 0.002) { return half4(0.0h); }

    float3 p = ro + rd * t;
    float3 n = logoNormal(p, yaw, pitch, twist, shape);
    float3 v = -rd;
    float facing = saturate(dot(n, v));

    // Where on the mark this pixel landed, which is what the tint is keyed to.
    float3 tint = logoTint(logoSpace(p, yaw, pitch, twist).xy, shape);

    // Schlick, with a floor so the faces you look straight through still carry
    // a little of the room.
    // Schlick's floor is low here, unlike the orb's: a flat extruded face is
    // nearly all facing the camera, so the floor decides almost the whole
    // mark, and a high one drowns the colour in reflected room.
    float fresnel = mix(0.30, 1.0, pow(1.0 - facing, 3.0));

    // Reflection is mostly tinted but not entirely — it is the untinted
    // remainder, the near-white glancing streaks, that says "glass" rather
    // than "coloured plastic".
    float3 mirror = reflect(rd, n);
    float3 reflected = logoRoom(mirror, shape);
    float3 col = mix(reflected, reflected * tint, 0.65);

    // Transmission carries the colour in full: this is the body of the mark,
    // the part a glance actually names. Dispersed across three indices for the
    // rainbow fringing along the bevel.
    float3 through = float3(logoRoom(refract(rd, n, 1.0 / 1.38), shape).r,
                            logoRoom(refract(rd, n, 1.0 / 1.46), shape).g,
                            logoRoom(refract(rd, n, 1.0 / 1.54), shape).b);
    col = mix(through * tint * 1.25, col, fresnel);

    col *= iridescence(facing, 0.12);

    // Direct speculars. The room already contains these lights, but only a
    // reflection pointing almost exactly at one finds it, and glass without a
    // broad highlight has no shape. The tight white lobe is what travels
    // across a face as the mark turns and sells the whole thing as solid.
    col += float3(1.65, 1.65, 1.58) * pow(saturate(dot(mirror, normalize(float3(-0.32,  0.86, 0.40)))), 220.0);
    col += tint * 0.55 * pow(saturate(dot(mirror, normalize(float3(-0.60,  0.28, 0.75)))), 18.0);

    // Rim: light creeping around the far side, white rather than tinted so the
    // mark keeps a legible outline against any toolbar background.
    col += pow(1.0 - facing, 4.0) * 0.50;

    // More saturation push than the orb takes. Filtering a bright room through
    // a tint costs chroma, and these three have to stay nameable colours.
    col = glassTonemap(col, 1.25, 1.55);

    return half4(half3(col) * half(alpha), half(alpha));
}
