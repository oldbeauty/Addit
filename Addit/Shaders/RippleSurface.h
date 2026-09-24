#pragma once

#include <metal_stdlib>
using namespace metal;

// The launch screen's water, as a function rather than a picture: where the
// surface is, how high, and where that lands in the palette's ramp.
//
// Split out of `PixelRipple.metal` because two things now read this field and
// they have to read the *same* one. `PixelRipple.metal` draws it as a panel of
// halftone dots; `FieldAnalysis.metal` samples it per cell for the launch
// screen's pattern-recognition overlay, which detects, tracks and fits a model
// to what the panel is showing. An analyser working from its own copy of this
// arithmetic would be a lookalike — its boxes would drift off the dots the
// first time either copy was touched, and the overlay's whole claim is that it
// is reading the screen.
//
// Nothing here knows about dots, colour, or the bloom: this is the surface and
// the ramp only. `PixelRipple.metal` owns the halftone and `Colorways.h` owns
// the palette.

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
///
/// The overlay *measures* this rather than being told it — `FieldAnalysis`
/// differentiates the radius of the circle it fits to a detected arc, and the
/// number it prints should land near this one. That is the one honest check
/// that the analysis is reading the water and not decorating it.
constant float kWaveSpeed = 0.42;
/// Ripples per screen width. High enough for several rings inside one front.
constant float kWaveNumber = 46.0;

/// Where the resting surface sits in the ramp: higher bends the midtones
/// further down.
///
/// This is the field's contrast control, and the reason it isn't higher is the
/// bloom in `PixelRipple.metal`. Without one, most of the screen is undisturbed
/// water and lands mid-ramp, so the whole field comes back as one flat wash
/// with the ripples barely brighter than it — which is what a hard bend was
/// fixing. The bloom separates the calm from the disturbed by *light* instead,
/// so the bend can come back up a little and let some colour into the body of
/// the water.
constant float kMidBend = 1.60;

/// Palette steps. The field is continuous; this is what makes it look
/// *indexed* — flat bands of colour stepping into each other the way a 256
/// colour display would have done it. Lower is chunkier.
///
/// Applied to the dots and *not* to the bloom, which is the one place the two
/// disagree on purpose: the panel is indexed, and the light coming off it into
/// the air isn't. That is also what a real LED sign does behind haze.
///
/// The analyser quantises too, and for a different reason: it is looking at
/// the panel, so it should see the value the panel actually displays. Its
/// level histogram has exactly this many bins for the same reason.
constant float kPaletteSteps = 26.0;

// MARK: - The surface

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
/// `seed` decides *where the drops land* — it is added to the cycle counter
/// the placement hash is keyed on, so every value of it is a different field
/// running the same choreography. The app draws a fresh one per launch
/// (`PixelRippleField.seed`); the tools pass 0, which is the field this was
/// tuned on and the one their committed output shows.
///
/// Kept small (the app uses 0…4095) for a precision reason, not a taste one:
/// this arrives as a `float`, and at 1e8 an increment of 1 is no longer
/// representable — a large seed would collapse `cycle`, `cycle + 1` and
/// `cycle + 2` onto one value and every slot would stop recycling to a new
/// place.
///
/// Called twice per pixel by the renderer, at the cell's centre for the dots
/// and at the pixel itself for the bloom, and once per cell by the analyser.
/// One function rather than three because they all have to be the *same*
/// water: a bloom that disagrees with the dots it sits under reads as a badly
/// registered second print of the picture, and an overlay that disagrees with
/// either reads as a cartoon of an instrument.
static float2 surfaceAt(float2 uv, float aspect, float time, float seed) {
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

        float2 rnd = hash22(float2(slot, cycle + seed));
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

/// The ramp parameter snapped to the palette's own steps.
///
/// Quantise this rather than the final colour, so the bands land on the same
/// values everywhere on screen and read as a palette rather than as banding
/// artefacts.
static float quantiseLevel(float level) {
    return round(level * (kPaletteSteps - 1.0)) / (kPaletteSteps - 1.0);
}
