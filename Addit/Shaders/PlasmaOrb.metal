#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
#include "GlassRoom.h"

using namespace metal;

// A single blob of glass, raymarched.
//
// The whole thing is one signed-distance field — a sphere kneaded by warped
// sine lattices until it folds in on itself — lit only by a procedural
// environment. Nothing here is a sprite or a gradient stack: the colour is what
// the room looks like *off* and *through* the surface, so twisting the field
// re-reflects everything rather than sliding artwork around.
//
// Called from PlasmaOrb.swift via `.colorEffect`, so it runs once per pixel of
// a ~28pt view — about 7k pixels on a 3x screen, which is why marching it
// properly is affordable and why antialiasing can be a closest-approach
// estimate rather than supersampling.

// MARK: - Small helpers

/// The room the blob lives in: a hue sweep cut into hard softbox strips.
///
/// Deliberately over-saturated. A physically neutral room reflected in a 28pt
/// object produces a grey pebble; the colour has to come from somewhere, and
/// putting it in the environment rather than tinting the surface keeps the
/// reflection and the transmission agreeing with each other.
static float3 environment(float3 d) {
    d = normalize(d);

    // Interpolate between named endpoints instead of running each channel
    // through its own cosine. Per-channel phases are how the first version
    // produced green: G peaked at a direction where R and B were both low, and
    // there is no phase triple that reliably avoids that while still sweeping.
    // Mixing between colours that are all on the magenta→cyan side of the wheel
    // makes an unwanted hue unreachable rather than merely unlikely.
    float k = 0.55 * d.x + 0.42 * d.y + 0.30 * d.z;
    const float3 kMagenta = float3(1.00, 0.09, 0.78);
    const float3 kCyan    = float3(0.10, 0.98, 1.35);
    const float3 kViolet  = float3(0.40, 0.12, 1.10);

    // Even mix. Weighting it either way overshoots hard, because the coloured
    // sources below stack on top of whatever this produces — bias the sweep
    // *and* the lights toward the same end and the blob comes out monochrome in
    // that colour. Balance is held in the sources, not here.
    float sweep = 0.5 + 0.5 * sin(6.28318 * 1.15 * k);
    float3 hue = mix(kCyan, kMagenta, sweep);
    // A second, slower axis folds violet in, so the sweep isn't a two-colour
    // ramp that reads as a gradient painted on.
    hue = mix(hue, kViolet, 0.28 * (0.5 + 0.5 * sin(2.30 * (d.y * 1.5 - d.z * 0.8) + 1.7)));

    // Strips, and a floor near zero. The reference is chrome: its darks go
    // properly black between the lights, and lifting them even slightly is what
    // turns the whole thing into a soap bubble.
    float3 col = hue * softbox(d, 1.15, 0.015) * 2.05;

    // Broad magenta and blue sources, biasing the palette toward the pinks and
    // electric blues rather than letting the hue sweep wander evenly.
    col += float3(1.55, 0.20, 1.40) * pow(saturate(dot(d, normalize(float3(-0.55, 0.62, 0.55)))), 4.0);
    col += float3(0.16, 0.80, 1.75) * pow(saturate(dot(d, normalize(float3( 0.70, -0.28, 0.66)))), 3.6);

    // Hard key: a small white source, far over 1.0 so the tone map has
    // something to blow out into a hotspot.
    col += float3(9.00) * pow(saturate(dot(d, normalize(float3(-0.35, 0.88, 0.32)))), 140.0);
    return col;
}

// MARK: - The blob

/// The shear the blob carries with no scroll at all.
constant float kStandingTwist = 0.95;
/// How far `mapBlob` understates its own distance. Displacing a distance field
/// breaks its Lipschitz bound and the twist stretches it further, so every step
/// is deliberately short of what the field claims.
constant float kFieldSafety = 0.16;
/// Extra understatement per radian of shear.
constant float kTwistRelax = 0.40;

/// The factor `mapBlob`'s return is scaled by.
///
/// Exposed because the silhouette fade needs it too: `closest` is a *scaled*
/// distance, so comparing it against a threshold in world units makes the fade
/// wider by exactly this factor. Getting that wrong is not subtle — it stops
/// looking like antialiasing and starts looking like a halo around the orb.
static inline float fieldScale(float twist) {
    return kFieldSafety / (1.0 + abs(twist + kStandingTwist) * kTwistRelax);
}

/// Distance to the blob at `p`, already spun by `spin` and sheared by `twist`.
///
/// The twist is applied to the domain before the folds are evaluated, so the
/// folds themselves wring out along the axis instead of a finished shape being
/// bent — that difference is the whole effect.
static float mapBlob(float3 p, float spin, float twist) {
    // A standing twist on top of whatever the scroll adds. At rest the previous
    // version relaxed into a smooth kneaded ball, and the thing it is meant to
    // look like is *wrung* — the shear has to be part of the shape, with the
    // scroll deepening it rather than creating it.
    float shear = twist + kStandingTwist;
    p.xz = spin2(p.xz, spin + shear * p.y);

    // The folds are evaluated in a tilted frame. A sine lattice read straight
    // off the axes puts its lobes on a grid, and a grid of lobes is a bunch of
    // balls stuck together, not one mass — the tilt is what hides the lattice.
    float3 w = p;
    w.xz = spin2(w.xz, 0.70);
    w.xy = spin2(w.xy, 0.50);

    // Sines nested inside sines: warping the domain before sampling it bends
    // the lobes into each other, so what would be a regular egg-carton comes
    // out as one kneaded shape with a waist and a couple of overhangs.
    float3 q = w * 2.45;
    float fold = sin(q.x + 0.90 * sin(q.z)) * sin(q.y * 1.12) * sin(q.z + 0.70 * sin(q.x));

    // Helical ridges, cut in cylindrical coordinates so the shear carries them
    // around the axis: this is what actually reads as wrung. `1 - abs(sin)` has
    // a corner at every zero, so these are creases with an edge rather than the
    // rounded humps a plain sine leaves — the difference between chrome and wax.
    float theta = atan2(p.z, p.x);
    float helix = 1.0 - abs(sin(theta * 1.5 + p.y * 2.30));
    // Deliberately the gentlest term. Every crease costs the marcher step
    // length, and this is the highest frequency of the three — pushed any
    // harder it is what tears the silhouette into speckle.
    float striate = 1.0 - abs(sin(theta * 5.0 + p.y * 7.50));

    float3 r = w * 5.20 + float3(2.10, 0.30, 1.20);
    float ripple = sin(r.x + 0.50 * sin(r.y)) * sin(r.y) * sin(r.z);

    // Bigger base radius than the displacement average, so the blob actually
    // fills its box — the folds subtract as much as they add, and the old
    // radius left it rattling around inside a 28pt frame.
    float d = length(p) - 0.80
            + 0.225 * fold
            + 0.105 * helix
            + 0.020 * striate
            + 0.035 * ripple;

    return d * fieldScale(twist);
}

static float3 blobNormal(float3 p, float spin, float twist) {
    // Tetrahedral gradient: four taps instead of the six a central difference
    // costs, which matters when this runs inside the shading of every pixel.
    const float2 e = float2(1.0, -1.0) * 0.0022;
    return normalize(
        e.xyy * mapBlob(p + e.xyy, spin, twist) +
        e.yyx * mapBlob(p + e.yyx, spin, twist) +
        e.yxy * mapBlob(p + e.yxy, spin, twist) +
        e.xxx * mapBlob(p + e.xxx, spin, twist)
    );
}

// MARK: - Entry point

[[ stitchable ]] half4 plasmaOrb(float2 position,
                                 half4 currentColor,
                                 float2 size,
                                 float spin,
                                 float twist) {
    float2 uv = (position - size * 0.5) / (min(size.x, size.y) * 0.5);
    uv.y = -uv.y;                       // SwiftUI is y-down; the field is y-up.

    float3 ro = float3(0.0, 0.0, 3.0);
    float3 rd = normalize(float3(uv * 0.38, -1.0));

    float t = 0.0;
    float closest = 1e9;                // closest approach, for the soft edge

    // The hit threshold is far tighter than it looks like it needs to be, and
    // that is deliberate. A loose one stops each ray a slightly different
    // distance short of the surface, the normal inherits that error, and the
    // high-contrast lighting below magnifies a fraction of a percent of normal
    // error into visible terraces — the whole blob turns into a contour map.
    // Converging properly is cheaper than any amount of shading cleverness.
    for (int i = 0; i < 150; i++) {
        float3 p = ro + rd * t;
        float d = mapBlob(p, spin, twist);
        closest = min(closest, d);
        if (d < 0.0001) { break; }
        t += d;
        if (t > 5.0) { break; }
    }

    // Width the silhouette fades across, in world units. `size` is in points
    // but this runs per device pixel, so the fade is deliberately well under a
    // point — around two pixels on a 3x screen. Any wider and a 28pt orb looks
    // out of focus rather than antialiased.
    //
    // Rays that only grazed the blob get a sliver of coverage instead of being
    // dropped: that is the whole antialiasing scheme, and it is why the edge
    // survives at 28pt without supersampling.
    float aa = 0.6 * (2.0 * 0.38 * 2.6) / min(size.x, size.y);
    // `closest` is in the field's own understated units, so it has to be put
    // back into world units before it can be compared against a world-space
    // width. Skipping this divides the effective threshold by `fieldScale` —
    // roughly an eightfold-wider fade, which is a milky halo standing off the
    // silhouette rather than an antialiased edge, and it is glaring on a light
    // background where there is something for it to wash out.
    float alpha = 1.0 - smoothstep(0.0, aa, closest / fieldScale(twist));
    if (alpha <= 0.002) { return half4(0.0h); }

    float3 p = ro + rd * t;
    float3 n = blobNormal(p, spin, twist);
    float3 v = -rd;
    float facing = saturate(dot(n, v));

    // Schlick, with a floor so the faces you look straight through still carry
    // a little of the room.
    float fresnel = mix(0.42, 1.0, pow(1.0 - facing, 3.0));

    // Mirror first. The blob is shaded as a highly reflective surface rather
    // than a transparent one, because that is what the strips buy: reflections
    // slide across a fold and draw its shape, where transmission through a
    // marched interior mostly produced iso-bands of thickness — a contour map,
    // not glass.
    float3 mirror = reflect(rd, n);
    float3 col = environment(mirror);

    // The transmitted part, one bend only, kept as a minority term. It is what
    // stops the blob reading as solid chrome: the middle, where the surface
    // faces you and reflects almost nothing interesting, gets its colour from
    // behind instead. Dispersed across three indices for the rainbow fringing.
    float3 through = float3(environment(refract(rd, n, 1.0 / 1.38)).r,
                            environment(refract(rd, n, 1.0 / 1.46)).g,
                            environment(refract(rd, n, 1.0 / 1.54)).b);
    col = mix(through * 0.85, col, fresnel);

    // Thin film over the top of both.
    col *= iridescence(facing, 0.22);

    // Direct speculars. The room already contains these lights, but only a
    // reflection pointing almost exactly at one finds it, and glass without a
    // broad highlight has no shape — it reads as a flat iridescent decal. The
    // white lobe is tight and the coloured ones are wide, which is the
    // difference between a lit object and a merely coloured one.
    col += float3(1.70, 1.70, 1.62) * pow(saturate(dot(mirror, normalize(float3(-0.35,  0.88,  0.32)))), 220.0);
    col += float3(1.00, 0.20, 1.05) * pow(saturate(dot(mirror, normalize(float3(-0.62,  0.30,  0.72)))), 20.0);
    col += float3(0.20, 0.70, 1.35) * pow(saturate(dot(mirror, normalize(float3( 0.68, -0.22,  0.70)))), 13.0);

    // No rim term. There used to be a white `pow(1 - facing, 4)` lift here for
    // outline legibility, but grazing pixels are exactly the ones the edge fade
    // is handing partial alpha to — brightening them lit up the antialiasing
    // itself, and premultiplying spread it into a soft halo standing off the
    // silhouette. The blob is bright enough against a toolbar without it.

    col = glassTonemap(col, 1.55, 1.60);

    return half4(half3(col) * half(alpha), half(alpha));
}
