#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
#include "Colorways.h"
#include "RippleSurface.h"

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
// and that only holds if one table says so. Where the water *is* comes from
// `RippleSurface.h`, which the launch screen's analysis overlay shares for the
// same kind of reason: the overlay draws boxes on the dots this file draws, so
// the two cannot be working from separate copies of the wave. Everything left
// in this file is the halftone — how big a dot a given height makes, and what
// light comes off it.
//
// `PixelEQGrid` is the app's other pixel grid and stays square-ish and fixed:
// it's a readout you're meant to count, and a cell that changes size can't be
// counted. This one is a display you're meant to read *through*.
//
// Called from `PixelRippleField.swift` via `.colorEffect`.

// MARK: - Tuning

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
static half4 renderRipple(float2 position, float2 size, float cell,
                          float time, float seed, int way) {
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
    float2 cellSurface = surfaceAt(cellUV, aspect, time, seed);
    float cellLevel = quantiseLevel(rampLevel(cellSurface.x));
    float3 dotCol = waterColour(cellSurface, cellLevel, palette);

    // --- The light above it, sampled per pixel and left continuous.
    float2 bloomSurface = surfaceAt(position / size.x, aspect, time, seed);
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
                                   float time,
                                   float seed) {
    return renderRipple(position, size, cell, time, seed, kColorway);
}
