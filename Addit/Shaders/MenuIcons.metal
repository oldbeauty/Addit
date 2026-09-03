#include <metal_stdlib>
#include "GlassRoom.h"

using namespace metal;

// The album menu's ornaments: every action in the ellipsis menu as a small
// moulded object rather than a glyph.
//
// These render **offscreen**, once, to a still image — which is the one real
// difference between this file and `AccessIcons.metal`, and it drives most of
// what follows. A `Menu` is drawn by UIKit as a `UIMenu`, whose item icons are
// `UIImage`s; there is no SwiftUI host in there to run a `colorEffect`, so a
// live shader cannot go in a menu at all. So there is no `[[stitchable]]`
// entry point here, only a compute kernel, and `MenuIconRenderer` calls it.
//
// Two things follow from being still, and both are gains. The pose is chosen
// rather than passing through — each model is turned to the one angle that
// says what it is, instead of having to stay readable through a whole rock.
// And the render is supersampled (`kSamples`), which a per-frame shader could
// not afford: these are ~66px images, made once and cached for the process.
//
// What does NOT change is the room. `menuEnvironment` is one rig for the whole
// set and it is deliberately close kin to the Access sheet's, because a menu
// of ten objects lit ten ways is a junk drawer. Materials carry the meaning —
// `surfaceFor` is the palette — and the shading, marcher and tone map are
// shared by every icon, which is what makes them read as one family.
//
// The three storage-provider marks in the "Duplicate to…" submenu are NOT
// here: they are the real brand marks and already exist as glass in
// `GlassLogo.metal`, which grew its own kernel to be rendered the same way.

// MARK: - Icon ids
//
// Kept in step with `MenuIcon` in MenuIconRenderer.swift — that enum's raw
// values are these numbers, and the kernel switches on them.

constant int kAccess    = 0;
constant int kLink      = 1;
constant int kChat      = 2;
constant int kEdit      = 3;
constant int kDownload  = 4;
constant int kRemove    = 5;
constant int kEye       = 6;
constant int kEyeSlash  = 7;
constant int kExport    = 8;
constant int kDuplicate = 9;

// MARK: - Materials
//
// A material id rides alongside the distance in every `map` function's
// `float2(distance, material)`. Ids are floats only because that is what fits
// in the second lane; they are compared as integers after rounding.

constant float mIvory    = 0.0;
constant float mSteel    = 1.0;
constant float mChrome   = 2.0;
constant float mAzure    = 3.0;
constant float mRed      = 4.0;
constant float mGreen    = 5.0;
constant float mYellow   = 6.0;
constant float mWood     = 7.0;
constant float mGraphite = 8.0;
constant float mBlush    = 9.0;
constant float mCharcoal = 10.0;
constant float mIris     = 11.0;
constant float mPupil    = 12.0;

struct Surface {
    float3 albedo;
    float  spec;        // strength of the tight highlight
    float  power;       // its exponent — high is hard plastic, low is soft
    float  mirror;      // how much of the room the surface returns
    float  mirrorFloor; // Fresnel floor; polished metal reflects head-on too
    float  emission;    // self-lit floor of the material's own colour
};

/// The palette. Each entry is a material, not a colour: the highlight, the
/// share of the room it returns and how much it glows on its own are as much
/// a part of "this is chrome" as the albedo is, and keeping them together is
/// what stops an icon being recoloured into something that no longer looks
/// made of anything.
///
/// The coloured entries are pushed past 1.0 deliberately. Nothing on screen
/// can be brighter than white, but the tone map rolls off rather than clips,
/// so an albedo of 1.2 does not blow out — it arrives at the top of the ramp
/// with its hue intact while a 0.9 lands short of it, which is the difference
/// between a colour that sits on the object and one that comes off it. Paired
/// with `emission` (below) that is the whole fluorescent trick.
static Surface surfaceFor(int m) {
    switch (m) {
        // Was a flat mid-grey. Now dark chrome — it is the *second* metal in
        // this set and reads against the bright one by tone, not by finish.
        case  1: return Surface{ float3(0.14, 0.16, 0.21), 0.95, 150.0, 1.02, 0.54, 0.00 };
        // Chrome's albedo is nearly black on purpose — what you see is the
        // room, and any body colour under a mirror only greys the reflection.
        case  2: return Surface{ float3(0.07, 0.08, 0.10), 1.00, 230.0, 1.34, 0.80, 0.00 };
        case  3: return Surface{ float3(0.02, 0.42, 1.35), 0.95, 110.0, 0.34, 0.10, 0.24 };
        case  4: return Surface{ float3(1.35, 0.04, 0.16), 0.95, 110.0, 0.32, 0.10, 0.26 };
        case  5: return Surface{ float3(0.10, 1.30, 0.26), 0.95, 110.0, 0.32, 0.10, 0.26 };
        case  6: return Surface{ float3(1.45, 1.00, 0.02), 0.95, 100.0, 0.30, 0.10, 0.28 };
        // Bare wood stays the one soft thing in the set. A pencil whose collar
        // is as glossy as its barrel loses the "sharpened" cue entirely, and
        // one dull material is also what gives the others something to be
        // shiny *against*.
        case  7: return Surface{ float3(0.98, 0.72, 0.36), 0.35, 26.0,  0.10, 0.05, 0.06 };
        case  8: return Surface{ float3(0.09, 0.09, 0.11), 0.75, 90.0,  0.34, 0.12, 0.00 };
        case  9: return Surface{ float3(1.32, 0.10, 0.52), 0.90, 70.0,  0.26, 0.09, 0.26 };
        // Stays properly dark. This is the ground the neon cross sits on, and a
        // mirror-bright puck would leave nothing for it to pop against.
        case 10: return Surface{ float3(0.06, 0.06, 0.08), 0.85, 120.0, 0.34, 0.12, 0.00 };
        case 11: return Surface{ float3(0.02, 0.90, 1.25), 0.95, 150.0, 0.34, 0.12, 0.30 };
        case 12: return Surface{ float3(0.01, 0.01, 0.02), 1.00, 200.0, 0.30, 0.14, 0.00 };
        // Pearl, and half a mirror. Kept neutral on purpose — it is the only
        // near-white body in the set, so any tint it picks up reads as a colour
        // cast over the whole menu rather than as a choice.
        default: return Surface{ float3(1.02, 1.02, 1.06), 0.90, 130.0, 0.50, 0.22, 0.04 };
    }
}

// MARK: - The room

/// One rig for the whole menu. Same structure as the Access sheet's chrome
/// room — a cool vertical gradient broken into softbox strips, one hot key —
/// because these objects are meant to look like they were photographed on the
/// same table as the globe and the chain.
static float3 menuEnvironment(float3 d) {
    d = normalize(d);
    float3 col = mix(float3(0.01, 0.02, 0.05), float3(1.20, 1.26, 1.44), saturate(d.y * 0.5 + 0.5));
    // Harder and busier than the room started out. Chrome has nothing of its
    // own to show, so all of its character is the room's contrast: dropping the
    // floor between the strips to near-black is what turns a grey doughnut into
    // polished steel, and the extra strips give a curved surface more edges to
    // bend across.
    col *= softbox(d, 1.45, 0.03) * 2.45;
    // Two coloured bounces from opposite sides, so a mirrored surface gets two
    // differently coloured sweeps instead of one grey streak. Tight and weak:
    // the first pass had these broad and strong, and chrome came out lavender —
    // a mirror shows the room *whole*, so anything wide in here stops being a
    // glint and becomes the colour of the metal itself.
    col += float3(0.30, 0.10, 0.34) * pow(saturate(dot(d, normalize(float3( 0.72, 0.02, 0.60)))), 9.0);
    col += float3(0.08, 0.26, 0.55) * pow(saturate(dot(d, normalize(float3(-0.76, -0.22, 0.52)))), 10.0);
    col += float3(9.0) * pow(saturate(dot(d, normalize(float3(-0.42, 0.82, 0.38)))), 150.0);
    return col;
}

/// The key. Shared by every icon so highlights fall the same way across the
/// menu — the cheapest thing that makes a set look like a set.
constant float3 kKeyLight = float3(-0.42, 0.78, 0.55);

/// A cool fill from the other side, which only ever makes a second, broader
/// highlight. Two speculars is the difference between "lit" and "polished".
constant float3 kFillLight = float3(0.62, 0.10, 0.72);

// MARK: - Primitives

static float3 rotX(float3 p, float a) {
    float c = cos(a), s = sin(a);
    return float3(p.x, p.y * c - p.z * s, p.y * s + p.z * c);
}

static float3 rotY(float3 p, float a) {
    float c = cos(a), s = sin(a);
    return float3(p.x * c - p.z * s, p.y, p.x * s + p.z * c);
}

static float3 rotZ(float3 p, float a) {
    float c = cos(a), s = sin(a);
    return float3(p.x * c - p.y * s, p.x * s + p.y * c, p.z);
}

static float sdSphere(float3 p, float r) {
    return length(p) - r;
}

static float sdRoundBox(float3 p, float3 b, float r) {
    float3 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - r;
}

/// Capped cylinder about Z — the axis that points at the camera, which is what
/// a disc seen face-on wants.
static float sdCylinderZ(float3 p, float r, float halfDepth) {
    float2 d = float2(length(p.xy) - r, abs(p.z) - halfDepth);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
}

/// Torus in XZ, axis along Y.
static float sdTorusXZ(float3 p, float2 t) {
    float2 q = float2(length(p.xz) - t.x, p.y);
    return length(q) - t.y;
}

/// Round cone about +Y: radius `r1` at y=0 tapering to `r2` at y=h, with a
/// hemispherical cap at each end. The workhorse here — every arrowhead, every
/// pencil point and both shoulders are this.
static float sdRoundCone(float3 p, float r1, float r2, float h) {
    float2 q = float2(length(p.xz), p.y);
    float b = (r1 - r2) / h;
    float a = sqrt(max(0.0, 1.0 - b * b));
    float k = dot(q, float2(-b, a));
    if (k < 0.0) { return length(q) - r1; }
    if (k > a * h) { return length(q - float2(0.0, h)) - r2; }
    return dot(q, float2(a, b)) - r1;
}

/// Cone about +Y with a **flat** base: `sdRoundCone` with its base cap sliced
/// off at y=0.
///
/// The slice is the entire point. A round cone caps its wide end with a
/// hemisphere of that radius, so an arrowhead built from one straight is a
/// ball on a stick — every arrow in this file was a lollipop until this
/// existed.
static float sdConeY(float3 p, float r, float h) {
    return max(sdRoundCone(p, r, 0.015, h), -p.y);
}

/// Hexagonal prism, cross-section in XY and extruded along Z. Only the pencil
/// needs it, and only because a round barrel reads as a dowel.
static float sdHexPrismZ(float3 p, float r, float halfLen) {
    const float3 k = float3(-0.8660254, 0.5, 0.57735);
    p = abs(p);
    p.xy -= 2.0 * min(dot(k.xy, p.xy), 0.0) * k.xy;
    float2 d = float2(length(p.xy - float2(clamp(p.x, -k.z * r, k.z * r), r)) * sign(p.y - r),
                      p.z - halfLen);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
}

static float smoothMinF(float a, float b, float k) {
    float h = saturate(0.5 + 0.5 * (b - a) / k);
    return mix(b, a, h) - k * h * (1.0 - h);
}

/// Union of two (distance, material) pairs — the nearer one wins outright.
static float2 opU(float2 a, float2 b) {
    return a.x < b.x ? a : b;
}

// MARK: - Models
//
// Each model is authored to sit inside roughly ±1.05 and is pre-turned to its
// final pose here rather than by the camera, so the pose travels with the
// shape it was chosen for. Poses lean the same way across the set — a shallow
// yaw to the left and a touch of top-down pitch — so the menu looks like one
// shelf of objects under one light, not ten separate renders.

/// One figure: a head over a wide, flat-bottomed shoulder dome, scaled by `s`.
///
/// The shoulders are an ellipsoid and not a cone, which is the difference
/// between a person and a chess pawn — a cone runs in a straight taper from
/// its base to the neck, and that silhouette is a pawn no matter what sits on
/// top of it. The flat cut underneath is the other half: a bust ends, it does
/// not come to a rounded point.
static float bust(float3 p, float s) {
    p /= s;
    float head = sdSphere(p - float3(0.0, 0.26, 0.0), 0.27);
    float3 q = p - float3(0.0, -0.44, 0.0);
    float3 e = float3(q.x, q.y * 1.55, q.z * 1.35);
    float shoulders = (length(e) - 0.62) / 1.55;
    shoulders = max(shoulders, -(q.y + 0.30));
    return smoothMinF(head, shoulders, 0.09) * s;
}

/// Access — two figures, the nearer one ivory and the further one steel.
///
/// The material split is doing real work: two busts in the same colour merge
/// into one blob at 20pt, and it is the tonal step between them, not the
/// silhouette, that says there are two people here.
static float2 mapAccess(float3 p) {
    p = rotY(p, 0.26);
    p = rotX(p, 0.08);

    return opU(float2(bust(p - float3(-0.40, 0.06, -0.34), 0.82), mSteel),
               float2(bust(p - float3( 0.32, -0.10, 0.30), 1.0), mIvory));
}

/// Share Link — the same two chrome links the Access sheet wears.
///
/// Deliberately the *same* object, not a second link icon: the sheet and this
/// menu row hand out the identical URL, and repeating the ornament is the
/// cheapest way to say so. Rolled corner to corner for the reason it is there
/// too — two links left level leave the top and bottom of a square icon empty.
static float2 mapLink(float3 p) {
    p = rotZ(p, -0.62);
    p = rotX(p, 0.44);
    p = rotY(p, -0.30);

    const float2 ring = float2(0.45, 0.145);
    float a = sdTorusXZ(p - float3(-0.36, 0.0, 0.0), ring);
    float3 q = p - float3(0.36, 0.0, 0.0);
    float b = sdTorusXZ(float3(q.x, q.z, q.y), ring);
    return float2(min(a, b), mChrome);
}

/// Chat — a speech bubble, moulded rather than drawn.
///
/// No dots or rule lines on the face: at this size each would be a pixel and a
/// half and would only muddy the one thing that identifies the shape, which is
/// the tail. The tail is smooth-unioned so it grows out of the body the way a
/// moulded part would, instead of being a cone parked against it.
static float2 mapChat(float3 p) {
    p = rotY(p, 0.40);
    p = rotX(p, 0.10);

    float body = sdRoundBox(p - float3(0.0, 0.18, 0.0), float3(0.72, 0.48, 0.17), 0.24);

    float3 t = rotZ(p - float3(-0.26, -0.26, 0.0), 0.42);
    float tail = sdRoundCone(float3(t.x, -t.y, t.z), 0.22, 0.02, 0.52);

    return float2(smoothMinF(body, tail, 0.11), mAzure);
}

/// Edit — a pencil, built along Z and then laid diagonally.
///
/// Five materials in one object, which is more than anything else in the set
/// gets. It earns them: at 20pt the yellow barrel, the pale wood collar and
/// the dark point are what make this a pencil rather than a stick, and they do
/// it with colour alone at a size where no amount of shape would.
static float2 mapEdit(float3 p) {
    p = rotZ(p, -0.68);
    p = rotY(p, 1.18);
    p = rotX(p, 0.20);

    float2 res = float2(1e9, mYellow);

    float barrel = sdHexPrismZ(p - float3(0.0, 0.0, 0.36), 0.185, 0.52);
    res = opU(res, float2(barrel, mYellow));

    float ferrule = sdCylinderZ(p - float3(0.0, 0.0, 0.955), 0.185, 0.075);
    res = opU(res, float2(ferrule, mChrome));

    float eraser = sdRoundBox(p - float3(0.0, 0.0, 1.075), float3(0.15, 0.15, 0.075), 0.09);
    res = opU(res, float2(eraser, mBlush));

    // Cone from the barrel's end down to the point, growing in -z. The wood
    // and the graphite are one shape split by depth — a separate lead cone
    // would need its own tip to line up with this one to a fraction of a pixel.
    float3 c = float3(p.x, -(p.z + 0.16), p.y);
    float point = sdRoundCone(c, 0.185, 0.014, 0.66);
    float pointM = p.z < -0.62 ? mGraphite : mWood;
    res = opU(res, float2(point, pointM));

    return res;
}

/// Make Available Offline — an arrow onto a shelf.
///
/// The bar underneath is not decoration; an arrow alone points but does not
/// say where to, and the shelf is what turns "down" into "onto this device".
static float2 mapDownload(float3 p) {
    p = rotY(p, 0.34);
    p = rotX(p, 0.12);

    float shaft = sdRoundBox(p - float3(0.0, 0.42, 0.0), float3(0.155, 0.38, 0.155), 0.06);
    // Negating y grows the cone downward from a base plane at y = -0.02.
    float head = sdConeY(float3(p.x, -(p.y + 0.02), p.z), 0.42, 0.50);
    float arrow = min(shaft, head);

    float bar = sdRoundBox(p - float3(0.0, -0.82, 0.0), float3(0.56, 0.10, 0.17), 0.07);

    return opU(float2(arrow, mGreen), float2(bar, mSteel));
}

/// Remove Offline Access — a red cross standing off a dark puck.
///
/// The cross is a separate solid held proud of the disc rather than a mark on
/// its face, so the shape survives being lit from any angle: paint would go
/// dark exactly where the disc does.
static float2 mapRemove(float3 p) {
    p = rotY(p, 0.26);
    p = rotX(p, 0.10);

    float disc = sdCylinderZ(p, 0.84, 0.17);

    float3 q = p - float3(0.0, 0.0, 0.17);
    float bar1 = sdRoundBox(rotZ(q,  0.7854), float3(0.48, 0.115, 0.13), 0.06);
    float bar2 = sdRoundBox(rotZ(q, -0.7854), float3(0.48, 0.115, 0.13), 0.06);

    return opU(float2(disc, mCharcoal), float2(min(bar1, bar2), mRed));
}

/// Show / Hide Hidden Tracks — an eye, optionally struck through.
///
/// The almond is the intersection of two spheres, squashed in Z: that is the
/// standard lens, and it gives a real bulged cornea to catch the key light
/// instead of a flat lozenge. The pupil is painted by radius on the iris
/// rather than modelled, because a pupil sphere would have to poke out through
/// the iris to be visible at all, and at this size that reads as a bubble.
static float2 mapEye(float3 p, bool slashed) {
    p = rotY(p, 0.14);
    p = rotX(p, 0.06);

    // Squashing p in Z compresses the object; the field steepens by the same
    // factor, so the result is divided back down to stay a usable SDF.
    //
    // The squash is what decides whether there is an eye here at all. The two
    // spheres meet 1.015 out along Z, so the lens jumps forward as this number
    // falls — at 1.9 the sclera's own front sits at 0.53 and swallows the iris
    // whole, and the icon renders as a blank almond. Flat enough that the iris
    // clears it is the constraint, not the look.
    const float squash = 2.7;
    float3 e = float3(p.x, p.y, p.z * squash);
    float almond = max(sdSphere(e - float3(0.0, -0.78, 0.0), 1.28),
                       sdSphere(e - float3(0.0,  0.78, 0.0), 1.28)) / squash;

    // Set forward so it domes out past the sclera like a real cornea, which is
    // also what catches the key light and stops the eye reading as a sticker.
    float iris = sdSphere(p - float3(0.0, 0.0, 0.24), 0.34);
    float irisM = length(p.xy) < 0.135 ? mPupil : mIris;

    float2 res = opU(float2(almond, mIvory), float2(iris, irisM));

    if (slashed) {
        // Clear of the cornea's 0.58 front, or the bar would tunnel through it.
        float3 s = rotZ(p - float3(0.0, 0.0, 0.66), 0.66);
        float bar = sdRoundBox(s, float3(0.96, 0.075, 0.075), 0.05);
        res = opU(res, float2(bar, mChrome));
    }
    return res;
}

/// Export — an arrow rising out of an open carton.
///
/// The carton is a U cut from a slab, not a hollow box, and that is the second
/// attempt. A real box has to be pitched steeply before its opening faces the
/// camera at all — level, you get its front wall and the icon is a brick — but
/// pitching that far lays the arrow down and foreshortens its head into a nail.
/// The U has no such angle to find: it is open from the front, so the arrow
/// keeps the upright pose that makes it an arrow.
static float2 mapExport(float3 p) {
    p = rotY(p, 0.28);
    p = rotX(p, 0.12);

    float slab = sdRoundBox(p - float3(0.0, -0.44, 0.0), float3(0.72, 0.46, 0.16), 0.13);
    // Cuts the top-centre out, leaving a base and two uprights.
    float notch = sdRoundBox(p - float3(0.0, -0.10, 0.0), float3(0.42, 0.44, 0.40), 0.05);
    float carton = max(slab, -notch);

    float shaft = sdRoundBox(p - float3(0.0, 0.02, 0.0), float3(0.15, 0.42, 0.15), 0.06);
    float head = sdConeY(p - float3(0.0, 0.40, 0.0), 0.38, 0.46);

    return opU(float2(carton, mSteel), float2(min(shaft, head), mAzure));
}

/// Duplicate to… — one plate behind another, the front one carrying a plus.
///
/// Separated in depth as well as across, so the pair reads as two objects at a
/// glance from the shadow between them; offset alone leaves a shape that could
/// be one notched plate.
static float2 mapDuplicate(float3 p) {
    p = rotY(p, 0.34);
    p = rotX(p, 0.12);

    float back  = sdRoundBox(p - float3(-0.26,  0.26, -0.30), float3(0.58, 0.58, 0.10), 0.16);
    float front = sdRoundBox(p - float3( 0.22, -0.22,  0.16), float3(0.58, 0.58, 0.10), 0.16);

    float3 q = p - float3(0.22, -0.22, 0.28);
    float plus = min(sdRoundBox(q, float3(0.085, 0.28, 0.08), 0.04),
                     sdRoundBox(q, float3(0.28, 0.085, 0.08), 0.04));

    float2 res = opU(float2(back, mSteel), float2(front, mIvory));
    return opU(res, float2(plus, mAzure));
}

// MARK: - Dispatch

static float2 mapIcon(float3 p, int icon) {
    switch (icon) {
        case kAccess:    return mapAccess(p);
        case kLink:      return mapLink(p);
        case kChat:      return mapChat(p);
        case kEdit:      return mapEdit(p);
        case kDownload:  return mapDownload(p);
        case kRemove:    return mapRemove(p);
        case kEye:       return mapEye(p, false);
        case kEyeSlash:  return mapEye(p, true);
        case kExport:    return mapExport(p);
        default:         return mapDuplicate(p);
    }
}

/// How far back the camera sits. Every model is authored to about the same
/// extent, so these barely vary — the pencil needs the most room because it is
/// the only one that is long rather than round.
static float iconDistance(int icon) {
    switch (icon) {
        case kEdit:     return 3.05;
        case kEye:
        case kEyeSlash: return 2.72;
        case kExport:
        case kDuplicate:return 2.66;
        case kChat:     return 2.48;
        default:        return 2.54;
    }
}

static float3 iconNormal(float3 p, int icon) {
    const float2 e = float2(1.0, -1.0) * 0.0015;
    return normalize(e.xyy * mapIcon(p + e.xyy, icon).x +
                     e.yyx * mapIcon(p + e.yyx, icon).x +
                     e.yxy * mapIcon(p + e.yxy, icon).x +
                     e.xxx * mapIcon(p + e.xxx, icon).x);
}

/// One shading model for every icon. Differences between them come out of
/// `Surface` and nowhere else, which is the rule that keeps ten objects
/// looking like they were made by the same shop.
static float3 shadeIcon(float3 n, float3 rd, Surface s) {
    float3 v = -rd;
    float3 lightDir = normalize(kKeyLight);
    float3 fillDir = normalize(kFillLight);

    float diffuse = saturate(dot(n, lightDir));
    // Half-lambert mixed in, so the side facing away goes dim rather than
    // black. A hard terminator on a 20pt object just loses half of it.
    float wrap = saturate(dot(n, lightDir) * 0.5 + 0.5);
    float3 col = s.albedo * (0.22 + 1.05 * mix(diffuse, wrap, 0.35));

    // Fluorescence. A floor of the material's own colour that the lighting
    // cannot take away, which is what real fluorescent pigment does — it
    // re-emits, so its shadowed side stays saturated instead of going to a
    // dark version of itself. Without this a "neon" albedo is just a bright
    // colour with a grey side, and the object reads as painted plastic.
    col += s.albedo * s.emission;

    float3 h = normalize(lightDir + v);
    col += float3(1.0) * pow(saturate(dot(n, h)), s.power) * s.spec;

    // The fill's highlight: broader, cooler, and on the opposite flank, so
    // there is a second place for the eye to catch. Its exponent is a fraction
    // of the key's — a second tight lobe would read as a modelling error.
    float3 hFill = normalize(fillDir + v);
    col += float3(0.42, 0.58, 0.88) * pow(saturate(dot(n, hFill)), s.power * 0.45) * s.spec * 0.22;

    float facing = saturate(dot(n, v));
    float fresnel = mix(s.mirrorFloor, 1.0, pow(1.0 - facing, 4.0));
    col += menuEnvironment(reflect(rd, n)) * s.mirror * fresnel;

    // Edge light, carrying the material's own hue rather than one fixed blue.
    // On the neons this puts a halo of the object's colour around the object,
    // which is most of why they read as lit from within; on the metals it
    // stays near-white and does the job it always did, which is keeping a dark
    // silhouette off a dark menu sheet.
    float3 rimTint = mix(float3(0.42, 0.56, 0.88), s.albedo * 1.5, 0.78);
    col += rimTint * pow(1.0 - facing, 3.0) * 0.60;

    return col;
}

/// March, shade, and return **premultiplied** RGBA. Premultiplied because the
/// result goes straight into a `CGImage` declared that way, and because it is
/// what lets the supersampler below average edge pixels correctly.
static half4 renderIcon(float2 uv, int icon) {
    float3 ro = float3(0.0, 0.0, iconDistance(icon));
    float3 rd = normalize(float3(uv * 0.50, -1.0));

    float t = 0.0;
    float closest = 1e9;
    bool hit = false;
    float material = 0.0;

    for (int i = 0; i < 110; i++) {
        float3 p = ro + rd * t;
        float2 res = mapIcon(p, icon);
        closest = min(closest, res.x);
        if (res.x < 0.0012) { hit = true; material = res.y; break; }
        // 0.85 rather than a full step: several of these fields are built with
        // `max` and scaling, which makes them under-estimates of true distance
        // in places, and a full step overshoots thin parts like the eye's slash.
        t += res.x * 0.85;
        if (t > 8.0) { break; }
    }

    // Closest-approach antialiasing, as the orb and the Access icons do it.
    // It still earns its place under supersampling: it is what keeps a
    // silhouette clean between samples rather than merely between pixels.
    float alpha = hit ? 1.0 : smoothstep(0.016, 0.0, closest);
    if (alpha <= 0.004) { return half4(0.0h); }
    if (!hit) {
        t = max(t, 0.001);
        material = mapIcon(ro + rd * t, icon).y;
    }

    float3 p = ro + rd * t;
    float3 n = iconNormal(p, icon);
    Surface s = surfaceFor(int(material + 0.5));

    float3 col = shadeIcon(n, rd, s);
    // Chroma, not brightness — which is the whole lesson of this pass. Reinhard
    // compresses toward 1.0, so *every* extra lumen drags a colour to white:
    // exposure 1.8 with lit rims and a bright fill turned the neons pastel, the
    // exact opposite of fluorescent. So the light is pulled back below where it
    // started and the saturation push does the work instead, on mid-tones that
    // still have somewhere to go.
    col = glassTonemap(col, 1.46, 1.80);

    return half4(half3(col) * half(alpha), half(alpha));
}

// MARK: - Entry point

/// Samples per axis. 3×3 is affordable exactly once — which is all this runs —
/// and it is the difference between a crisp 20pt object and a ragged one.
constant int kSamples = 3;

kernel void menuIconKernel(texture2d<half, access::write> out [[texture(0)]],
                           constant int &icon [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    uint w = out.get_width();
    uint h = out.get_height();
    if (gid.x >= w || gid.y >= h) { return; }

    float2 size = float2(w, h);
    float half2Extent = min(size.x, size.y) * 0.5;

    half4 sum = half4(0.0h);
    for (int sy = 0; sy < kSamples; sy++) {
        for (int sx = 0; sx < kSamples; sx++) {
            float2 jitter = (float2(sx, sy) + 0.5) / float(kSamples);
            float2 pos = float2(gid) + jitter;
            float2 uv = (pos - size * 0.5) / half2Extent;
            uv.y = -uv.y;                 // model space is y-up, textures are y-down
            sum += renderIcon(uv, icon);
        }
    }

    out.write(sum / half(kSamples * kSamples), gid);
}
