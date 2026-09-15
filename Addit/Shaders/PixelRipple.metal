#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
#include "Colorways.h"

using namespace metal;

// The launch screen's field: a panel of round emitters behaving like struck
// water.
//
// Nothing here is a sprite or an easing curve. The surface is a height field —
// a handful of expanding circular wavefronts summed together — sampled once
// per *cell* rather than once per pixel. That sampling is the entire point of
// the effect: the wave is smooth and continuous, and quantising it onto a grid
// is what makes it read as a low-resolution display showing a fluid rather
// than as a blurred gradient.
//
// The cell's sample is then drawn as a **dot whose size is its brightness** —
// a full-bleed disc at the top of the ramp, nothing at all at the bottom. This
// is halftone, and it does two jobs one flat square couldn't. The grid stops
// being something the picture is chopped into and becomes a thing in its own
// right, a panel of emitters that happen to be showing water; and it carries
// value twice over, in size as well as colour, so a crest reads even where the
// palette is running out of headroom.
//
// What colour any of it is comes from `Colorways.h`, which the wordmark drawn
// on top of this shares — the field and the mark have to be lit by one light,
// and that only holds if one table says so. Everything in this file is the
// *shape* of the effect: where the water is, how high, and how big a dot that
// makes.
//
// `PixelEQGrid` is the app's other pixel grid and stays square-ish and fixed:
// it's a readout you're meant to count, and a cell that changes size can't be
// counted. This one is a display you're meant to read *through*.
//
// Called from `PixelRippleField.swift` via `.colorEffect`.

// MARK: - Tuning

/// Wavefronts in flight. Each one owns a staggered slot in `kDropPeriod`, so
/// this is also what sets the patter: a new drop lands every
/// `kDropPeriod / kDrops` seconds.
constant int kDrops = 8;
/// Seconds from a drop landing to its slot recycling somewhere else. Long
/// enough that a ring crosses the screen and dies before its slot is reused,
/// so slots never visibly "jump".
///
/// Also the full length of the fill, and so the length of the launch: every
/// slot has fired exactly once by the time this is up. Keep it in step with
/// `LoadingSplashView.launchHold`.
constant float kDropPeriod = 2.4;
/// Wavefront speed, in screen widths per second.
constant float kWaveSpeed = 0.42;
/// Ripples per screen width. High enough for several rings inside one front.
constant float kWaveNumber = 46.0;

/// Clearance between two neighbouring dots at full brightness, as a fraction
/// of the cell. The grid's limit: a dot never grows past this, so even a screen
/// blown out to ice keeps its emitters separate instead of merging into a
/// sheet.
constant float kGap = 0.13;
/// Radius of the dimmest dot, in cell units. Not zero — an emitter at rest is
/// still an emitter, and letting the darks vanish outright turns the calm parts
/// of the field into a hole in the panel rather than water lying flat.
constant float kMinRadius = 0.055;
/// The unlit panel the dots sit on. Below the palette's own darkest entry, so
/// the emitters read as *on* something rather than as holes cut in the void.
///
/// The one colour here that is *not* per-colorway, and deliberately: this same
/// value is written in Swift in `LoadingSplashView`, which paints it behind the
/// field so a partial bottom row and the launch storyboard match instead of
/// flashing. A backdrop that moved with the colorway would have to be lifted
/// out of the shader to keep those two in step, for a colour that is within a
/// hair of black in every direction anyway.
constant float3 kBackdrop = float3(0.006, 0.004, 0.021);

/// Palette steps. The field is continuous; this is what makes it look
/// *indexed* — flat bands of colour stepping into each other the way a 256
/// colour display would have done it. Lower is chunkier.
///
/// Applied to the dots and *not* to the bloom below, which is the one place
/// the two disagree on purpose: the panel is indexed, and the light coming off
/// it into the air isn't. That is also what a real LED sign does behind haze.
constant float kPaletteSteps = 26.0;

/// Where the resting surface sits in the ramp: higher bends the midtones
/// further down.
///
/// This is the field's contrast control, and the reason it isn't higher is the
/// bloom. Without one, most of the screen is undisturbed water and lands
/// mid-ramp, so the whole field comes back as one flat wash with the ripples
/// barely brighter than it — which is what a hard bend was fixing. The bloom
/// separates the calm from the disturbed by *light* instead, so the bend can
/// come back up a little and let some colour into the body of the water.
constant float kMidBend = 1.60;

/// How hard the light between the dots is driven.
///
/// The bloom: the same surface sampled once per *pixel* rather than once per
/// cell, so it crosses cell boundaries and fills the gaps the halftone leaves.
/// It costs a second pass over every wavefront and is the only place in this
/// file where the price is real — what it buys is the difference between dots
/// on black and a panel that is actually lit. A within-cell falloff round each
/// dot was tried first and is the wrong shape: it cannot reach past the cell
/// it belongs to, so every dot's glow squares off against its neighbours.
constant float kBleed = 0.85;

/// Ramp level a point has to reach before it glows at all.
///
/// The load-bearing half of the bloom, and it took seeing it without one. An
/// unthresholded bloom is a *second picture* of the water: continuous where
/// the panel is quantised, and — because `kWaveNumber` puts far more ripples
/// across the screen than there are cells — carrying detail finer than the
/// grid can show. The field came back as a bright blue wash with smooth dark
/// arcs crossing the dots at the wrong scale, which reads as two exposures of
/// the same frame printed out of register.
///
/// Thresholding fixes both at once. Only crests glow, so the calm body of the
/// water stays near-black instead of flooding, and the bloom's fine structure
/// is confined to exactly the places the dots are already big and bright
/// enough to hide it.
constant float kBleedFloor = 0.28;

/// Extra light at a dot's centre, as a fraction of the dot's own colour. An
/// emitter with a hot middle reads as lit from inside; a flat disc reads as
/// printed. Scaled by the colour it brightens rather than added as white, so
/// the calm half of the field doesn't sprout grey pinpricks.
constant float kCore = 0.60;

/// Rim gain on the leading edge of a front.
constant float kRimGain = 0.52;

/// Saturation over the finished pixel. Above 1 this pulls every colour away
/// from its own luminance — the palette is already near-primary, so what this
/// actually recovers is the saturation the bloom costs: two coloured layers
/// summed always land closer to white than either of them was.
constant float kVibrance = 1.30;

// MARK: - Helpers

/// Hoskins' hash: two uncorrelated values in 0…1 from an integer pair.
/// Used for drop placement, so `(slot, cycle)` in gives a different point on
/// screen every time a slot comes round.
static float2 hash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

/// The water at `uv`: its height, and its quadrature — the same wave a quarter
/// period ahead, which peaks where the surface is climbing fastest and is what
/// the rim light is drawn from.
///
/// Called twice per pixel, at the cell's centre for the dots and at the pixel
/// itself for the bloom. One function rather than two because the two have to
/// be the *same* water: a bloom that disagrees with the dots it sits under
/// reads as a badly registered second print of the picture.
static float2 surfaceAt(float2 uv, float aspect, float time) {
    float height = 0.0;
    float lead = 0.0;

    for (int i = 0; i < kDrops; i++) {
        float slot = float(i);
        // Slot `i` first fires `i` intervals in, and `local` is the time since
        // then. Negative means its first drop hasn't landed yet, and that slot
        // contributes nothing at all.
        //
        // That guard is what gives the launch a shape. Without it the slots
        // are simply periodic, and any stagger — forwards or backwards — just
        // relabels which slot is which: t = 0 always lands mid-storm. Cutting
        // off everything before zero instead means the field starts empty and
        // fills one ring at a time, and by `kDropPeriod` every slot has fired
        // exactly once. That is the whole animation, and it is why the splash
        // is held for exactly that long — see `LoadingSplashView.launchHold`.
        float local = time - slot * (kDropPeriod / float(kDrops));
        if (local < 0.0) { continue; }
        float cycle = floor(local / kDropPeriod);
        float age = local - cycle * kDropPeriod;

        float2 rnd = hash22(float2(slot, cycle));
        float2 origin = float2(rnd.x, rnd.y * aspect);

        float dist = distance(uv, origin);
        // Distance behind the wavefront. Negative outside the ring, positive
        // inside it, zero exactly on it.
        float front = dist - kWaveSpeed * age;

        // The ring widens as it travels — a front of constant width reads as a
        // hard expanding circle, an object rather than a disturbance.
        float width = 0.13 + 0.075 * age;
        float envelope = exp(-(front * front) / (width * width));
        // Energy leaves with time, and spreads out over a growing circumference.
        // The floor in the denominator is what keeps a fresh drop from
        // clipping to a white square at its own centre — without it the
        // amplitude runs away as `dist` goes to zero and the impact point
        // blows out instead of reading as the hottest part of the ripple.
        float decay = exp(-1.25 * age) / (0.62 + 3.0 * dist);

        float phase = kWaveNumber * front;
        height += sin(phase) * envelope * decay;
        lead += cos(phase) * envelope * decay;
    }

    // A slow swell under everything, so the field is never completely flat
    // between drops. Two incommensurate sheets, so it doesn't loop visibly.
    height += 0.075 * sin(uv.x * 6.3 + time * 0.55) * sin(uv.y * 4.7 - time * 0.41);

    return float2(height, lead);
}

/// Height → where that lands in the ramp, 0…1.
///
/// Ripples are small and signed; this centres them so the resting surface sits
/// low in the ramp and crests climb out of it. `tanh` rather than a clamp: two
/// fronts crossing shouldn't flatten into a plate.
static float rampLevel(float height) {
    return pow(0.5 + 0.5 * tanh(height * 2.6), kMidBend);
}

/// Push `c` away from its own luminance. Clamped at zero because the palette
/// runs to near-primaries and pushing a saturated blue further takes its red
/// and green negative.
static float3 vibrance(float3 c, float amount) {
    float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
    return max(mix(float3(luma), c, amount), 0.0);
}

// The ramp itself is `spectrum` in `Colorways.h`, next to the stops it
// interpolates.

/// The lit colour for a point of the surface, before the halftone.
static float3 waterColour(float2 surface, float level, Colorway palette) {
    float3 col = spectrum(level, palette);

    // The colorway's rim light on the leading edge of each front. Keeping it
    // on the edges is what makes it read as a rim light on a moving surface
    // instead of tinting the whole field, and it is the only thing in here
    // that says which way a ring is travelling: the height field is
    // symmetric, so without it an expanding ring and a collapsing one look the
    // same.
    return col + palette.rim * kRimGain * smoothstep(0.18, 0.85, surface.y);
}

// MARK: - Entry point

/// The field at one pixel, in one colorway.
///
/// Split out from the stitchable entry point below only so
/// `tools/ripplepreview` can sweep `way` at runtime and put every colorway on
/// one sheet. The app always passes `kColorway`, where it folds to a constant.
static half4 renderRipple(float2 position, float2 size, float cell, float time, int way) {
    Colorway palette = colorwayAt(way);

    // Normalise by width alone so a cell stays square: y runs 0…aspect, not
    // 0…1. Using each axis' own extent would stretch the rings into ellipses
    // on a tall screen.
    float aspect = size.y / size.x;

    // --- The panel. Snapped to the centre of the cell this pixel belongs to
    // and treated as a single sample from here on, which is the whole effect:
    // the water is smooth and continuous, and quantising it onto a grid is
    // what makes it read as a low-resolution display showing a fluid.
    float2 cellUV = (floor(position / cell) + 0.5) * cell / size.x;
    float2 cellSurface = surfaceAt(cellUV, aspect, time);
    // Quantise the ramp parameter rather than the final colour, so the bands
    // land on the same values everywhere on screen and read as a palette
    // rather than as banding artefacts.
    float cellLevel = rampLevel(cellSurface.x);
    cellLevel = round(cellLevel * (kPaletteSteps - 1.0)) / (kPaletteSteps - 1.0);
    float3 dotCol = waterColour(cellSurface, cellLevel, palette);

    // --- The light above it, sampled per pixel and left continuous.
    float2 bloomSurface = surfaceAt(position / size.x, aspect, time);
    float bloomLevel = rampLevel(bloomSurface.x);
    float3 bloom = waterColour(bloomSurface, bloomLevel, palette) * kBleed
                 * smoothstep(kBleedFloor, 0.85, bloomLevel);

    // Cut the dot. Its radius runs with `level` — the same quantised ramp the
    // colour comes from, so size steps in the same palette increments the
    // colour does and the two never disagree about how lit a cell is. The top
    // of the ramp fills the cell to the grid's limit, the void is a speck.
    //
    // Deliberately the ramp rather than the colour's luminance: a spectrum can
    // spend its middle in indigo and ultraviolet, which are plainly *lit* and
    // barely bright, so sizing by luminance would shrink the whole body of a
    // ripple and leave only its brightest crest showing.
    float radius = mix(kMinRadius, 0.5 - kGap * 0.5, cellLevel);

    // Antialiased over roughly a point rather than hard-edged: the cell size is
    // fitted to the screen width and is almost never a whole number of device
    // pixels, so a hard edge would round differently from one dot to the next
    // and a grid of supposedly identical emitters would visibly seethe.
    float2 local = position / cell - floor(position / cell);
    float fromCentre = length(local - 0.5);
    float aa = 0.5 / cell;
    // Named `coverage` rather than `dot`, which is a Metal builtin.
    float coverage = 1.0 - smoothstep(radius - aa, radius + aa, fromCentre);

    // The filament: brightest at the middle of the dot, gone by its edge.
    dotCol += dotCol * kCore * (1.0 - smoothstep(0.0, radius * 0.9, fromCentre));

    // Panel, then emitter, then the light in the air — which is additive over
    // both, so a dot at a crest sits inside its own glow rather than being
    // pasted on top of it.
    float3 col = mix(kBackdrop, dotCol, coverage) + bloom;

    return half4(half3(vibrance(col, kVibrance)), 1.0h);
}

[[ stitchable ]] half4 pixelRipple(float2 position,
                                   half4 currentColor,
                                   float2 size,
                                   float cell,
                                   float time) {
    return renderRipple(position, size, cell, time, kColorway);
}
