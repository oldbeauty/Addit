#pragma once

#include <metal_stdlib>
using namespace metal;

// The launch screen's colour, in one place: the ramp the water is read out
// with, the rim light on its leading edges, and the two colours the wordmark's
// halo is built from.
//
// It is one table rather than two sets of constants because the mark sits *on*
// the field, and the halo is what makes them look lit by one light instead of
// composited. Split across the two shaders, they drifted the moment either was
// touched — a magenta halo over amber water reads as two screens on top of
// each other.
//
// Nothing here knows about shape, motion, or the halftone grid: this is the
// palette and only the palette. `PixelRipple.metal` owns how the ramp is
// sampled (and quantises it — see `kPaletteSteps` there, which is what makes
// these stops read as an indexed palette rather than as a gradient);
// `Wordmark.metal` owns the halo's falloffs. Both include this.
//
// What the stops are *for*, which is the thing to know before editing one: the
// field's ramp is bent down hard (`pow(level, 1.75)`) so the undisturbed water
// sits low in it. `void` and `low` are therefore most of the screen most of the
// time and have to stay near-black; `high` and `peak` are crests and are
// allowed to blow out. A colorway is judged on whether those two ends read as
// the same light, not on whether the six swatches look nice in a row.

/// One launch-screen palette.
struct Colorway {
    /// The water's ramp, low to high. Sampled at fixed breakpoints in
    /// `PixelRipple.metal`, so these six are hue only — the *shape* of the ramp
    /// is tuned there and is not a per-colorway decision.
    float3 void_;
    float3 low;
    float3 mid;
    float3 high;
    float3 peak;
    float3 top;

    /// Added on the leading edge of each wavefront, where the surface is
    /// climbing fastest. Off the ramp deliberately: a rim light the same colour
    /// as the crest it rides on disappears into it, and this is the only thing
    /// in the field that says which way a ring is travelling.
    float3 rim;

    /// The wordmark's tight halo, hugging the letters.
    float3 haloNear;
    /// Its wide bloom — mostly atmosphere, and the thing that stops the mark
    /// looking cut out of the field. Kept a different hue from `haloNear` in
    /// every colorway: one exponential can be tight or can carry, never both,
    /// and two colours is how the pair reads as depth rather than as a blur.
    float3 haloFar;
};

/// The set. Each is a whole identity, not a tint of the one above it — the
/// point of keeping them in a table is that they can be compared at the size
/// they ship at, which is what `tools/ripplepreview` is for.
constant Colorway kColorways[] = {
    // 0 — Aqua. Cool the whole way and pushed hard toward the blues, with the
    // magenta arriving only at the crests so the two never average into a
    // muddy purple across the middle. The app's original launch colour.
    {
        float3(0.015, 0.010, 0.055), float3(0.075, 0.030, 0.240),
        float3(0.155, 0.080, 0.580), float3(0.060, 0.430, 0.960),
        float3(0.200, 0.900, 1.000), float3(0.880, 0.995, 1.000),
        float3(1.000, 0.160, 0.720),
        float3(0.412, 0.739, 1.000), float3(1.000, 0.160, 0.720),
    },
    // 1 — Readout. The wordmark's own blue → green → red signal palette, run
    // along the water's height instead of across a letter's dome. The two
    // surfaces then say the same thing in the same key: elevation is colour.
    // The only colorway here where the ramp climbs *through* green rather than
    // past it, which is what makes a ring read as a contour line.
    //
    // Magenta rim, which took a trial to arrive at. The obvious choice is
    // white — the over-range colour on a thermal scale, and it is what this
    // was first — but the rim lands on calm cells as well as crests, and a
    // white rim at a tenth of its strength is *grey*: the dark half of the
    // field came out speckled with dead pixels. Magenta is off the ramp
    // entirely, so it stays a colour all the way down to nothing.
    {
        float3(0.010, 0.012, 0.048), float3(0.020, 0.055, 0.330),
        float3(0.000, 0.300, 0.950), float3(0.000, 0.880, 0.420),
        float3(1.000, 0.880, 0.080), float3(1.000, 0.320, 0.120),
        float3(1.000, 0.160, 0.720),
        float3(0.560, 1.000, 0.700), float3(0.080, 0.340, 1.000),
    },
    // 2 — Inferno. Plum through crimson to white-hot: the borrowed convention
    // is a thermal camera, and the water reads as something cooling. Lands
    // closest to the wordmark's red zone, which is the top of its scale too.
    {
        float3(0.020, 0.004, 0.030), float3(0.180, 0.020, 0.180),
        float3(0.520, 0.040, 0.320), float3(0.950, 0.200, 0.150),
        float3(1.000, 0.560, 0.050), float3(1.000, 0.960, 0.820),
        float3(1.000, 0.850, 0.450),
        float3(1.000, 0.800, 0.550), float3(0.850, 0.100, 0.450),
    },
    // 3 — Oil slick. Teal to violet to magenta: the hue turns a corner rather
    // than climbing, the way thin film does, so two crests at different
    // heights are different *colours* rather than two brightnesses. The green
    // rim is the complement the film would throw.
    {
        float3(0.010, 0.020, 0.035), float3(0.030, 0.140, 0.230),
        float3(0.020, 0.520, 0.520), float3(0.240, 0.240, 0.900),
        float3(0.900, 0.250, 0.850), float3(1.000, 0.880, 0.600),
        float3(0.300, 1.000, 0.750),
        float3(0.800, 0.900, 1.000), float3(0.600, 0.200, 1.000),
    },
    // 4 — Phosphor. A green CRT, with an amber rim standing in for a second
    // phosphor burning where the beam turns. The design language's Atari half,
    // played straight.
    {
        float3(0.005, 0.020, 0.012), float3(0.020, 0.130, 0.060),
        float3(0.030, 0.380, 0.150), float3(0.150, 0.780, 0.250),
        float3(0.650, 1.000, 0.300), float3(0.930, 1.000, 0.850),
        float3(1.000, 0.720, 0.100),
        float3(0.850, 1.000, 0.900), float3(0.100, 0.900, 0.350),
    },
    // 5 — Sodium. Monochrome amber, and the only colorway with no second hue
    // anywhere in it: the rim is simply hotter. Everything else here is two
    // lights, and this is what one light looks like for comparison.
    {
        float3(0.020, 0.008, 0.002), float3(0.150, 0.050, 0.010),
        float3(0.380, 0.140, 0.020), float3(0.800, 0.350, 0.030),
        float3(1.000, 0.680, 0.120), float3(1.000, 0.950, 0.800),
        float3(1.000, 0.950, 0.850),
        float3(1.000, 0.880, 0.680), float3(0.900, 0.280, 0.020),
    },
    // 6 — Ultraviolet. Aqua run backwards: magenta through the body, blue at
    // the crests, ice at the top. The cyan rim is Aqua's own relationship
    // inverted, and it is the closest thing here to the app's accent.
    {
        float3(0.020, 0.004, 0.030), float3(0.180, 0.020, 0.150),
        float3(0.480, 0.040, 0.420), float3(0.900, 0.150, 0.650),
        float3(0.550, 0.350, 1.000), float3(0.850, 0.930, 1.000),
        float3(0.200, 0.950, 1.000),
        float3(0.900, 0.850, 1.000), float3(1.000, 0.200, 0.800),
    },
    // 7 — Coral. The complementary split: a cool body with warm crests, so
    // height reads as temperature and a ring carries both halves of the
    // colour wheel at once. The only one here where the ramp crosses white in
    // the middle of its climb rather than at the end of it.
    {
        float3(0.008, 0.020, 0.030), float3(0.020, 0.120, 0.160),
        float3(0.030, 0.420, 0.400), float3(0.250, 0.850, 0.650),
        float3(1.000, 0.620, 0.380), float3(1.000, 0.930, 0.850),
        float3(1.000, 0.750, 0.200),
        float3(1.000, 0.880, 0.800), float3(0.100, 0.800, 0.750),
    },
    // 8 — Arcade. Saturated primaries with nothing transitional between them:
    // violet, blue, magenta, amber. The others are ramps that happen to be
    // indexed; this one is what an actual 8-colour palette looked like, and
    // `kPaletteSteps` has more to bite on here than anywhere else in the set.
    {
        float3(0.010, 0.010, 0.030), float3(0.100, 0.020, 0.300),
        float3(0.000, 0.200, 1.000), float3(1.000, 0.000, 0.550),
        float3(1.000, 0.700, 0.000), float3(1.000, 1.000, 0.900),
        float3(0.100, 1.000, 0.600),
        float3(1.000, 0.950, 0.600), float3(0.400, 0.100, 1.000),
    },
};

constant int kColorwayCount = 9;

/// The one that ships.
///
/// A single index rather than a copy of the winning stops inlined into each
/// shader, because the two files have to move together and an index is the
/// smallest thing that can't be half-changed. When the set stops being
/// interesting, delete the rest of the table — not this constant.
constant int kColorway = 1;

/// The colorway at `way`, wrapped so a tool can sweep past the end of the set.
static inline Colorway colorwayAt(int way) {
    return kColorways[((way % kColorwayCount) + kColorwayCount) % kColorwayCount];
}

/// The ramp, low to high, in one colorway.
///
/// The breakpoints are the tuning; the stops are the colorway. Where each
/// transition lands decides how much of a sweep is body and how much is crest,
/// and that is the same for all of them — the first stop alone owns a third of
/// the ramp, because the field's `level` is bent down and the undisturbed water
/// spends its life there. Swapping hues is safe. Moving these numbers changes
/// every colorway at once.
///
/// Lives here rather than in `PixelRipple.metal` because the wordmark borrows
/// it too: one of the mark's colorways reads its own elevation through this
/// exact ramp, which is the only way to get the letters and the water onto one
/// palette by construction rather than by eye.
static inline float3 spectrum(float t, Colorway way) {
    float3 c = mix(way.void_, way.low, smoothstep(0.00, 0.34, t));
    c = mix(c, way.mid,  smoothstep(0.34, 0.52, t));
    c = mix(c, way.high, smoothstep(0.52, 0.70, t));
    c = mix(c, way.peak, smoothstep(0.70, 0.86, t));
    c = mix(c, way.top,  smoothstep(0.86, 1.00, t));
    return c;
}
