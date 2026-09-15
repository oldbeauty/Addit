#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
#include "Colorways.h"
#include "GlassRoom.h"

using namespace metal;

// The app's wordmark: "ADDIT" cut as a solid, false-coloured, and glowing.
//
// There is no font here. Every letter is a hand-authored polygon — the
// coordinates below *are* the typeface — because the shapes this mark wants
// aren't in any face iOS ships: a raked italic, cut this heavy, with folded
// angular bowls. Drawing them as signed-distance polygons
// rather than as a `Path` is what buys the rest of the file: a 2D distance is
// the one representation you can extrude into a solid, bevel, raymarch, and
// take a glow off, all from the same numbers.
//
// The mark is that 2D profile swept along a *sheared* axis, so the slab runs
// back and down-right from the face. Seen head-on a straight extrusion is
// invisible — the face hides it exactly — and shearing it is how a drawn logo
// has always shown its thickness. What a raymarch adds over stacking offset
// copies, which is what this mark used to be, is that the side walls are real
// surfaces with real normals: they take the room's reflection, they catch the
// bevel's highlight, and the letters occlude each other's extrusions.
//
// The surface is not a material. It is a *readout*: the direction each point
// reflects is measured and looked up in a three-colour false-colour palette —
// blue where a stroke faces the ground, red where it faces the sky, green
// across the horizon between them. Nothing is trying to look like metal.
//
// That is the mark's default and the argument for it is that the other
// ornaments are objects pretending to be glass, where this one is an
// instrument showing you the shape of its own letters. It isn't the only thing
// on offer, though: `kMarkPalettes` below carries colorways in three
// structures — measured *zones*, a lit *room* borrowed from `GlassRoom.h` (the
// rig the toolbar orb and the library marks are lit by, so the mark can be
// made one of that set), and the launch field's own *ramp*. `kMarkColorway`
// picks which ships.
//
// The dome the letters are cut with does all the work under every one of them:
// it is what sweeps the reflected direction across a whole palette between a
// stroke's bottom edge and its top one, and a flat face would show a single
// colour per letter no matter which structure coloured it.
//
// Called from `AdditWordmark.swift` via `.colorEffect`.

// MARK: - Letterform geometry
//
// One space for the whole word: y up, baseline at -0.5, cap line at +0.5, so a
// unit is one cap height and every number below can be read as a fraction of
// the letters' height. **Nothing breaks those two lines.** An earlier cut gave
// the outer letters spurs — a spear over the A, barbs at its feet, a rising
// blade off the T's arm and a point under its stem — and they read as two
// letters in a different font propping up three in this one. Every terminal
// now stops flat at the cap or the baseline, like the D's and the I's do.
//
// The italic is applied to the sample point in `wordProfile`, not baked into
// these coordinates, so the upright drawing stays legible to edit.

/// Slant, in x per unit of y. About 15°, which is where a shear stops reading
/// as "the same letters, tilted" and starts reading as a face that was drawn
/// italic.
constant float kSlant = 0.26;

// A — heavy splayed legs meeting in a flat apex, cut off square at the cap
// line. The counter closes high only because the legs taper toward the top;
// parallel legs this heavy cross so low that the letter reads as a triangle
// with a nick in it.
constant float2 kALegL[4] = { float2(0.36, 0.50), float2(0.52, 0.50),
                              float2(0.27, -0.50), float2(0.00, -0.50) };
constant float2 kALegR[4] = { float2(0.40, 0.50), float2(0.56, 0.50),
                              float2(0.92, -0.50), float2(0.65, -0.50) };
constant float2 kABar[4]  = { float2(0.25, -0.12), float2(0.67, -0.12),
                              float2(0.67, -0.34), float2(0.25, -0.34) };

// D — the bowl is folded rather than curved: two diagonals meeting a short
// vertical at the right. A round bowl on letters cut this hard reads as a
// different logo wearing the same weight.
constant float2 kDOut[6] = { float2(0.00, 0.50), float2(0.52, 0.50),
                             float2(0.82, 0.13), float2(0.82, -0.13),
                             float2(0.52, -0.50), float2(0.00, -0.50) };
constant float2 kDIn[6]  = { float2(0.27, 0.27), float2(0.44, 0.27),
                             float2(0.59, 0.07), float2(0.59, -0.07),
                             float2(0.44, -0.27), float2(0.27, -0.27) };

// I — wedge serifs. Without them a stem this plain reads as a divider between
// the D's and the T rather than as a letter.
constant float2 kIStem[4] = { float2(0.17, 0.32), float2(0.41, 0.32),
                              float2(0.41, -0.32), float2(0.17, -0.32) };
constant float2 kISerifT[4] = { float2(0.00, 0.50), float2(0.58, 0.50),
                                float2(0.45, 0.28), float2(0.13, 0.28) };
constant float2 kISerifB[4] = { float2(0.00, -0.50), float2(0.58, -0.50),
                                float2(0.45, -0.28), float2(0.13, -0.28) };

// T — a plain arm and a plain stem. The arm's ends taper inward slightly going
// down, which is the same wedge the I's serifs are cut with; that is the only
// flourish either outer letter gets, and it is one the inner letters already
// have.
constant float2 kTBar[4] = { float2(0.00, 0.50), float2(0.90, 0.50),
                             float2(0.82, 0.27), float2(0.08, 0.27) };
constant float2 kTStem[4] = { float2(0.325, 0.34), float2(0.575, 0.34),
                              float2(0.575, -0.50), float2(0.325, -0.50) };

/// Where each glyph's own origin sits along the baseline. Tight, because a
/// logo is a drawing of a word and not a setting of one — the spurs overlap
/// their neighbours' airspace at heights where nothing else is.
constant float kAdvA = 0.00;
constant float kAdvD1 = 1.02;
constant float kAdvD2 = 1.92;
constant float kAdvI = 2.82;
constant float kAdvT = 3.48;

/// Centre of the drawn word, subtracted so the mark is centred in its box. The
/// slant is why it isn't simply half of 4.38: the top of the word leans past
/// its right edge and the bottom past its left by the same amount.
constant float2 kWordCentre = float2(2.19, 0.0);

// MARK: - 2D distance

/// Signed distance to any simple polygon, either winding. The sign comes from
/// a crossing count rather than from the edge normals, so a glyph can be
/// authored clockwise or anticlockwise without the field flipping inside out —
/// which matters when the coordinates above are meant to be edited by hand.
static float sdPoly(float2 p, constant float2 *v, int n) {
    float d = dot(p - v[0], p - v[0]);
    float s = 1.0;
    for (int i = 0, j = n - 1; i < n; j = i, i++) {
        float2 e = v[j] - v[i];
        float2 w = p - v[i];
        float2 b = w - e * saturate(dot(w, e) / dot(e, e));
        d = min(d, dot(b, b));
        bool c1 = p.y >= v[i].y;
        bool c2 = p.y < v[j].y;
        bool c3 = e.x * w.y > e.y * w.x;
        if ((c1 && c2 && c3) || (!c1 && !c2 && !c3)) { s = -s; }
    }
    return s * sqrt(d);
}

/// Box distance, used as a conservative stand-in for a glyph the sample is
/// nowhere near — it under-estimates the true distance, which is all a sphere
/// march needs, and skips twenty-odd edge tests to get it.
static float sdBoxAt(float2 p, float2 centre, float2 halfSize) {
    float2 q = abs(p - centre) - halfSize;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

/// Past this, a glyph is far enough that its bounding box stands in for it.
constant float kGlyphCull = 0.34;

static float sdGlyphA(float2 p) {
    float bb = sdBoxAt(p, float2(0.46, 0.0), float2(0.46, 0.50));
    if (bb > kGlyphCull) { return bb; }
    float d = sdPoly(p, kALegL, 4);
    d = min(d, sdPoly(p, kALegR, 4));
    d = min(d, sdPoly(p, kABar, 4));
    return d;
}

static float sdGlyphD(float2 p) {
    float bb = sdBoxAt(p, float2(0.41, 0.0), float2(0.43, 0.52));
    if (bb > kGlyphCull) { return bb; }
    // The counter is cut out of the bowl rather than assembled around, so the
    // arms stay one solid whose inner corners are as sharp as its outer ones.
    return max(sdPoly(p, kDOut, 6), -sdPoly(p, kDIn, 6));
}

static float sdGlyphI(float2 p) {
    float bb = sdBoxAt(p, float2(0.29, 0.0), float2(0.31, 0.52));
    if (bb > kGlyphCull) { return bb; }
    float d = sdPoly(p, kIStem, 4);
    d = min(d, sdPoly(p, kISerifT, 4));
    d = min(d, sdPoly(p, kISerifB, 4));
    return d;
}

static float sdGlyphT(float2 p) {
    float bb = sdBoxAt(p, float2(0.45, 0.0), float2(0.45, 0.50));
    if (bb > kGlyphCull) { return bb; }
    float d = sdPoly(p, kTBar, 4);
    d = min(d, sdPoly(p, kTStem, 4));
    return d;
}

/// Signed distance to the flat wordmark, in the shared unit-cap-height space.
/// The slant is undone on the way in, so every glyph is tested upright.
static float wordProfile(float2 p) {
    p += kWordCentre;
    p.x -= kSlant * p.y;
    float d = sdGlyphA(p - float2(kAdvA, 0.0));
    d = min(d, sdGlyphD(p - float2(kAdvD1, 0.0)));
    d = min(d, sdGlyphD(p - float2(kAdvD2, 0.0)));
    d = min(d, sdGlyphI(p - float2(kAdvI, 0.0)));
    d = min(d, sdGlyphT(p - float2(kAdvT, 0.0)));
    // Un-shearing stretches the field along x; hand back a distance the march
    // can trust rather than one that tunnels through the thin strokes.
    return d * 0.96;
}

// MARK: - The solid

/// Half the slab's thickness.
constant float kDepth = 0.30;
/// How far the silhouette's edge rolls over. Small — the dome below does the
/// material's work, and this is only here to stop the outline being a razor.
constant float kBevel = 0.030;

/// The face is a dome, not a plane, and this is the number that matters most
/// in the file.
///
/// `kCrownFloor` is the slab's thickness at a stroke's edge as a fraction of
/// its thickness at the middle, and `kDomeRun` is the half-width of a typical
/// stroke — the distance from an edge to the crown, so the climb is the stroke.
///
/// The cross-section is a circle's, `sqrt(t(2-t))`, and that is the part that
/// took three tries. A smoothstep between the same two heights looks like the
/// right curve and is exactly wrong: its slope is zero at *both* ends, so the
/// surface comes out flat along the crown, flat again at the edge, and does
/// all of its bending in a narrow ring in between — a flat-faced letter with a
/// rolled rim, which is what a bevel filter produces and the thing this was
/// meant to avoid. A circular section is steepest where it meets the edge and
/// level at the crown, so the normal sweeps the whole way across a stroke.
///
/// Why a dome at all: a flat face seen head-on reflects *one* patch of room,
/// the same patch on every letter, and the first cut of this mark came out as
/// white paint with noise on it for exactly that reason. Curving the face
/// makes the surface normal swing as it crosses a stroke, so the measured
/// direction sweeps — ground under the bottom shoulder, the horizon along the
/// crown, sky over the top one. That sweep is what the palette is read with, and building
/// it from geometry rather than painting a gradient on is what makes it follow
/// the letters around their corners and break correctly at their terminals.
constant float kCrownFloor = 0.25;
constant float kDomeRun = 0.13;
/// Sweep axis, in profile units per unit of depth. The back of the slab sits
/// down and to the right of the face, so the walls that show are the ones a
/// key light at the upper left would leave dark — which is what makes the face
/// look like it's in front of them rather than printed on them.
constant float2 kSkew = float2(0.42, -0.30);

static float mapWord(float3 p) {
    float2 q = p.xy - p.z * kSkew;
    float profile = wordProfile(q);
    float inset = max(-profile, 0.0);
    float t = saturate(inset / kDomeRun);
    float halfThick = kDepth * mix(kCrownFloor, 1.0, sqrt(t * (2.0 - t)));
    float2 w = float2(profile + kBevel, abs(p.z) - (halfThick - kBevel));
    float d = min(max(w.x, w.y), 0.0) + length(max(w, 0.0)) - kBevel;
    // The shear stretches the field along the sweep and the dome bends it
    // outright — a circular section's slope runs away at the edge, so this is
    // nowhere near a true distance there. Understate the step rather than let
    // a ray punch through a wall at a glancing angle, which shows up as a nick
    // taken out of a letter's outline.
    return d * 0.35;
}

static float3 wordNormal(float3 p) {
    const float2 e = float2(1.0, -1.0) * 0.0016;
    return normalize(
        e.xyy * mapWord(p + e.xyy) + e.yyx * mapWord(p + e.yyx) +
        e.yxy * mapWord(p + e.yxy) + e.xxx * mapWord(p + e.xxx)
    );
}

// MARK: - Surface texture

static float hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), f.x),
               mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), f.x), f.y);
}

/// Four octaves, which is the fewest that still has both a dent you can see
/// and a grain you can't quite.
static float fbm(float2 p) {
    float a = 0.5, sum = 0.0;
    for (int i = 0; i < 4; i++) { sum += a * vnoise(p); p *= 2.03; a *= 0.5; }
    return sum;
}

/// Ridged noise — the fbm folded about its midline so its contours become
/// creases. The scratches are cut from this: a fold is a line, and a line is
/// what a scratch has to be.
static float ridged(float2 p) {
    return pow(1.0 - abs(2.0 * fbm(p) - 1.0), 3.0);
}

// MARK: - The palette

/// Half-width of the level band, in units of reflected elevation. Wide,
/// because elevation sweeps the full ±1 across a single stroke — a band of
/// ±0.05 would be a couple of device pixels rather than a stripe you can see.
///
/// `kModeZones` only.
constant float kBandHalf = 0.22;

/// How a colorway turns a reflected direction into colour.
///
/// `kModeZones` is the instrument: three colours keyed to elevation with black
/// between them, so the *gaps* draw the letterforms. `kModeRoom` is glass —
/// `GlassRoom.h`'s rig, the same one the orb and the library marks use, with
/// the palette's three colours as the room's. `kModeRamp` borrows the launch
/// field's own ramp (`spectrum`), which is the only structure that puts the
/// letters and the water on one palette by construction instead of by eye.
constant int kModeZones = 0;
constant int kModeRoom  = 1;
constant int kModeRamp  = 2;

/// One surface palette for the mark.
struct MarkPalette {
    /// Zones: facing the ground. Room: one end of the hue sweep, and the
    /// colour of its low source.
    float3 low;
    /// Zones: the band across the horizon. Room: the third colour folded into
    /// the sweep on a slower axis, so it isn't a two-colour gradient.
    float3 mid;
    /// Zones: facing the sky. Room: the other end of the sweep, and its high
    /// source.
    float3 high;
    int mode;
};

/// The set.
///
/// Values over 1.0 are deliberate in the room colorways: those are lights, and
/// `glassTonemap` needs something above white to roll off into a hotspot. In
/// the zone colorways they simply clip, which is also fine — a measurement at
/// the top of its scale is allowed to be at the top of its scale.
constant MarkPalette kMarkPalettes[] = {
    // 0 — Signal. Near-primaries, and that is the point rather than an
    // accident of how they were arrived at. A false-colour map is a convention
    // borrowed from instruments — it says *these are measurements, not paint*
    // — and the convention only reads if the colours are ones no material has.
    // Softened into teals and corals they stop being a key and start being a
    // bad airbrush.
    { float3(0.00, 0.00, 1.00), float3(0.00, 1.00, 0.00),
      float3(1.00, 0.00, 0.00), kModeZones },
    // 1 — Plasma, measured. The toolbar orb's three colours read as an
    // instrument rather than as glass: cyan along the ground, violet across
    // the horizon, magenta into the sky.
    { float3(0.10, 0.95, 1.30), float3(0.45, 0.14, 1.10),
      float3(1.00, 0.09, 0.78), kModeZones },
    // 2 — Plasma, lit. The same three colours in the orb's own rig, which is
    // the honest answer to "the colorway the orb has": the orb's identity is a
    // *room*, not a swatch set, and three colours in a readout can't carry a
    // strip-lit reflection or a blown-out key.
    { float3(0.10, 0.98, 1.35), float3(0.40, 0.12, 1.10),
      float3(1.00, 0.09, 0.78), kModeRoom },
    // 3 — Chrome. A neutral steel room, which is what this mark was before it
    // was a readout — worth having back in the set to argue against.
    { float3(0.55, 0.62, 0.78), float3(1.00, 1.00, 1.00),
      float3(0.80, 0.88, 1.05), kModeRoom },
    // 4 — Gold. The one warm room. Reads as an award plaque, which is either
    // exactly right over water or exactly wrong.
    { float3(0.45, 0.20, 0.03), float3(1.00, 0.80, 0.32),
      float3(1.00, 0.94, 0.70), kModeRoom },
    // 5 — Ice. The launch field's aqua as zones: indigo underfoot, ice across
    // the horizon, electric blue overhead.
    { float3(0.16, 0.10, 0.85), float3(0.88, 0.99, 1.00),
      float3(0.10, 0.75, 1.00), kModeZones },
    // 6 — Film. Thin film as zones — magenta, gold, cyan — so the letters
    // carry the three hues an oil slick turns through rather than a ramp
    // between two of them.
    { float3(1.00, 0.10, 0.70), float3(1.00, 0.85, 0.20),
      float3(0.10, 0.95, 1.00), kModeZones },
    // 7 — Field. The launch screen's own ramp, so the mark is read out on
    // exactly the scale the water under it is. Follows `kColorway`: change the
    // water and this changes with it, which is the whole point of it.
    { float3(0.0), float3(0.0), float3(0.0), kModeRamp },
};

constant int kMarkColorwayCount = 8;

/// The one that ships.
constant int kMarkColorway = 7;

static inline MarkPalette markPaletteAt(int way) {
    return kMarkPalettes[((way % kMarkColorwayCount) + kMarkColorwayCount)
                         % kMarkColorwayCount];
}

/// The room, for the colorways that are lit rather than measured.
///
/// Structurally the orb's `environment` with the palette's colours in place of
/// its hard-coded ones: a hue sweep between two of them with the third folded
/// in on a slower axis, cut into softbox strips whose darks go properly black,
/// two broad sources to bias the palette, and a small white key far over 1.0.
/// Kept in step with that file by hand — what has to match is the *shape* of
/// the room, since that is what makes an ornament read as one of the set.
static float3 markRoom(float3 d, MarkPalette mark) {
    float k = 0.55 * d.x + 0.42 * d.y + 0.30 * d.z;
    float sweep = 0.5 + 0.5 * sin(6.28318 * 1.15 * k);
    float3 hue = mix(mark.high, mark.low, sweep);
    hue = mix(hue, mark.mid,
              0.28 * (0.5 + 0.5 * sin(2.30 * (d.y * 1.5 - d.z * 0.8) + 1.7)));

    float3 col = hue * softbox(d, 1.15, 0.015) * 2.05;
    col += mark.high * 1.45 * pow(saturate(dot(d, normalize(float3(-0.55, 0.62, 0.55)))), 4.0);
    col += mark.low  * 1.25 * pow(saturate(dot(d, normalize(float3( 0.70, -0.28, 0.66)))), 3.6);
    col += float3(9.00) * pow(saturate(dot(d, normalize(float3(-0.35, 0.88, 0.32)))), 140.0);
    return col;
}

/// The mark's colour for a point reflecting toward `d`.
///
/// Left continuous, which is worth a note because the obvious move here is to
/// quantise the elevation into palette steps — it is what `PixelRipple.metal`
/// does to its own ramp, and it would tie the two together. Tried, and wrong
/// for this: the elevation is very nearly flat across the crown of a stroke,
/// so stepping it snaps whole faces to one entry and the letters come back as
/// plates of flat colour with the shape gone out of them. The ripple field
/// gets away with it because its ramp is *moving*. This one is a still.
static float3 wordDisplay(float3 d, float lift, MarkPalette mark) {
    float3 dir = normalize(d);
    float h = dir.y;

    if (mark.mode == kModeRoom) {
        // The orb's exposure and saturation. Lift drives the room harder,
        // which is the one honest reading of it here — there is no separate
        // light to turn up on a surface that *is* its reflection.
        return glassTonemap(markRoom(dir, mark), 1.55 * (1.0 + lift * 0.4), 1.60);
    }
    if (mark.mode == kModeRamp) {
        // Elevation straight into the field's ramp. No quantisation, for the
        // reason below: the crown of a stroke is nearly flat, and stepping it
        // snaps whole faces to one entry.
        return spectrum(0.5 + 0.5 * h, colorwayAt(kColorway)) * (1.0 + lift * 0.45);
    }

    float band = 1.0 - smoothstep(0.0, kBandHalf, abs(h));
    // Each ramp is bent so its bottom end falls away fast. Left linear, every
    // pixel of every letter is lit by something and the mark comes back as one
    // saturated mass with no shape in it — the black *between* the zones is
    // what draws the letterforms here, in place of the shading a material
    // would have done it with.
    float3 col = mark.high * pow(saturate(h), 1.35)
               + mark.low * pow(saturate(-h), 1.25)
               + mark.mid * band;
    return col * (1.0 + lift * 0.45);
}

// MARK: - Render

/// The mark for a sample at `p`, in cap-height units with the word centred on
/// the origin. `texel` is one device pixel in those same units, which is what
/// every soft edge here is measured in.
///
/// Returns premultiplied colour, because most of this view is transparent —
/// it sits over the launch screen's water and over the sign-in panel alike.
///
/// `palette` is only ever read by the halo. The surface's own colour is the
/// signal map above and is not a colorway's business — the mark is an
/// instrument, and an instrument that changes what its colours mean to match
/// the wallpaper is not one. What the halo is *for* is the opposite: it is the
/// light the mark and the water underneath it share, so it has to move with
/// the field or the two composite instead of sitting in one room.
static half4 renderWordmark(float2 p, float time, float lift, float texel,
                            Colorway palette, MarkPalette mark) {
    // Distance to the flat profile at the face. Every layer keys off this: the
    // glow falls away from it, the drop shadow is it offset, and a ray whose
    // sample is further from it than the sweep can reach cannot possibly hit
    // the solid, which is what keeps the march off most of the canvas.
    float d2 = wordProfile(p);
    float reach = kDepth * length(kSkew) + kBevel + 0.03;

    float pulse = 0.5 + 0.5 * sin(time * 1.55);

    // --- Layer 1: contact shadow, cast along the sweep so the slab looks like
    // it is standing off the surface behind it rather than lying on it.
    float shadow = wordProfile(p - kSkew * 0.42);
    float shadowAlpha = 0.60 * exp(-max(shadow, 0.0) * 14.0);

    // --- Layer 2: the halo. Two falloffs: a tight cyan one hugging the
    // letters, and a wide magenta bloom that is mostly atmosphere. Split
    // because one exponential can be tight or can carry, never both — and the
    // wide one is what stops the mark from looking cut out of the field.
    float near = exp(-max(d2, 0.0) * 14.0);
    float far = exp(-max(d2, 0.0) * 3.2);
    float3 glow = palette.haloNear * near * (1.45 + 0.40 * pulse)
                + palette.haloFar * far * (0.62 + 0.22 * pulse);
    glow *= 1.0 + lift * 0.6;
    // Weighted toward the tight half. Carried mostly by the wide one, the mark
    // wears an even outline at a constant distance from itself, which is what
    // a sticker's die-cut looks like — the falloff has to be fast enough that
    // the halo is plainly coming off the letters.
    float glowAlpha = saturate(near * 0.80 + far * 0.22);

    // --- Layer 3: the solid.
    // Camera far back: a wide word under a near lens splays its letters
    // outward at the ends, and these already lean. Enough perspective to see
    // the sweep converge, no more.
    const float kEye = 9.0;
    float3 ro = float3(0.0, 0.0, kEye);
    float3 rd = float3(p.x, p.y, -kEye);
    float len = length(rd);
    rd /= len;

    float3 col = float3(0.0);
    float alpha = 0.0;

    if (d2 < reach) {
        // Enter at the front face and give up once past the back one; the slab
        // is thin, so marching the whole ray would spend every step in vacuum.
        float t = (kEye - kDepth - 0.02) * len / kEye;
        float tMax = (kEye + kDepth + 0.05) * len / kEye;
        float closest = 1e9;

        for (int i = 0; i < 72; i++) {
            float3 q = ro + rd * t;
            float d = mapWord(q);
            closest = min(closest, d);
            if (d < 0.00025) { break; }
            t += d;
            if (t > tMax) { break; }
        }

        // Grazing rays get a sliver of coverage rather than being dropped —
        // the same edge antialiasing the glass marks use, and what keeps the
        // A's apex and the corners of the D's bowl clean at 50 points without
        // supersampling the whole canvas.
        alpha = 1.0 - smoothstep(0.0, texel * 1.1, closest);

        if (alpha > 0.002) {
            float3 hit = ro + rd * t;
            float3 n = wordNormal(hit);
            float2 face = hit.xy - hit.z * kSkew;

            // Texture. Perturbing the *normal* rather than the colour is the
            // whole difference between metal that has been somewhere and a
            // grey gradient with noise laid over it: a reflected room shows a
            // dent by bending, and bending is a normal.
            // Texture is three separate things, and they are separate because
            // they sit at different scales and a single noise can only be at
            // one of them. Broad swell is the casting's own unevenness; dents
            // are where it was knocked about; scratches are what has happened
            // to it since. All three are applied to the *normal*: a mirror
            // shows a flaw by bending, so a flaw that doesn't bend the surface
            // is a smudge painted on top of the reflection rather than a mark
            // in the metal.
            float swell = fbm(face * 2.1);
            float2 swellGrad = float2(fbm(face * 2.1 + float2(0.02, 0.0)) - swell,
                                      fbm(face * 2.1 + float2(0.0, 0.02)) - swell);
            float dent = fbm(face * 4.2);
            float2 dentGrad = float2(fbm(face * 4.2 + float2(0.015, 0.0)) - dent,
                                     fbm(face * 4.2 + float2(0.0, 0.015)) - dent);

            // Scratches run with the slant, and tilt the surface *across*
            // themselves — which is the whole reason brushed metal looks
            // brushed, rather than looking like fine lines drawn on it.
            float2 along = normalize(float2(kSlant, 1.0));
            float2 across = float2(along.y, -along.x);
            float scratch = smoothstep(0.70, 1.0,
                ridged(float2(dot(face, across) * 150.0, dot(face, along) * 2.5)));

            // These numbers are small, and the reason is the most useful
            // thing in the file. A tilt of the normal lands roughly twice over
            // in the reflection, so a perturbation of 0.25 moves `h` by 0.5 —
            // wider than the dark horizon band is — and every flaw drags some
            // part of the ramp on top of some other part. The band goes, the
            // ramp goes with it, and the mark reads as grey paint. That is
            // what happened here twice, each time while *increasing* the
            // texture to fix it.
            //
            // The way out is that the ramp is steep. On a surface that swings
            // from ground to sky across a quarter of a cap height, a tilt too
            // small to measure still throws a pixel clean across a band — so
            // the texture you can see is bought by the contrast, not by the
            // amplitude. Turn the ramp up and the flaws turn up with it.
            //
            // Weighted to the ends of the scale, too. Mid-frequency noise is
            // the one thing a mirror cannot carry: coarse enough to scatter
            // the reflection into patches, fine enough that there are dozens
            // per letter, which is the lichen-on-stone look. Broad swell only
            // makes the ramp waver; a scratch is a line, and a line doesn't
            // break a gradient.
            n = normalize(n + float3(swellGrad * 1.2 + dentGrad * 0.6, 0.0)
                            + float3(across * scratch * 0.09, 0.0));

            // Every point's colour is just where it points. No fresnel, no
            // speculars, no tone map — all three exist to make a reflection
            // behave like a real surface, and this one is a measurement being
            // displayed. Rolling it off would mix the palette's entries into
            // each other, which is the one thing it must not do.
            //
            // The texture above still matters, and is the only reason this
            // isn't five flat stencils: a scratch tilts the surface just
            // enough to throw a pixel across a step boundary, so the flaws in
            // the casting show up as the palette's own edges breaking up.
            col = wordDisplay(reflect(rd, n), lift, mark);
        } else {
            alpha = 0.0;
        }
    }

    // Composite back to front, premultiplied.
    float3 outCol = float3(0.0);              // shadow is black
    float outA = shadowAlpha;
    outCol = glow * glowAlpha + outCol * (1.0 - glowAlpha);
    outA = glowAlpha + outA * (1.0 - glowAlpha);
    outCol = col * alpha + outCol * (1.0 - alpha);
    outA = alpha + outA * (1.0 - alpha);

    return half4(half3(outCol), half(saturate(outA)));
}

/// How many cap heights the view is, across and down. The mark itself spans
/// about 4.6 by 1.0 — it is exactly cap height now that nothing overshoots —
/// and the rest is room for the halo, which has to fall off inside the view or
/// it ends at a straight edge.
constant float2 kViewUnits = float2(6.40, 2.40);

[[ stitchable ]] half4 wordmark(float2 position,
                                half4 currentColor,
                                float2 size,
                                float time,
                                float lift) {
    float2 p = (position / size - 0.5) * kViewUnits;
    p.y = -p.y;                         // SwiftUI is y-down; the mark is y-up.
    return renderWordmark(p, time, lift, kViewUnits.x / size.x,
                          colorwayAt(kColorway), markPaletteAt(kMarkColorway));
}
