#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
#include "GlassRoom.h"

using namespace metal;

// The sign-in screen's mark: a house on a patch of lawn, turning on the spot,
// with a party going on inside that you see through the windows and the open
// front door — and the aftermath of it strewn across the grass.
//
// Same family as `PlasmaOrb.metal` and `GlassLogo.metal`: one signed-distance
// field, marched, using the room and film from `GlassRoom.h`. What's different
// is that this shape is deliberately *matte*. The glass ornaments are all
// surface; if these walls reflected like those do, the windows would stop being
// the brightest thing on screen, which is the entire joke.
//
// The interior is not modelled. Marching a hollow shell and bouncing light
// around inside costs a great deal and, at the size this is drawn, resolves to
// a coloured smudge. Instead the party is evaluated in the plane of whichever
// wall a ray hit, so the lights stay pinned to the building as it turns — which
// is what sells them as being inside rather than painted on the front.

// MARK: - Materials

constant int kWall  = 0;
constant int kRoof  = 1;
constant int kWood  = 2;   // porch deck, posts, awning, steps
constant int kGrass = 3;
constant int kBush  = 4;
constant int kCup   = 5;
constant int kKeg   = 6;

// MARK: - Layout
//
// Everything is measured off the lawn's surface, so raising or lowering the
// ground moves the whole scene together instead of leaving the porch floating.

constant float kGroundTop = -0.37;
constant float3 kBody     = float3(0.52, 0.34, 0.42);   // half-extents of the walls
constant float  kBodyY    = kGroundTop + kBody.y;       // centre height of the walls
constant float  kDeckTop  = kGroundTop + 0.13;
constant float  kPorchZ   = kBody.z + 0.16;             // centre of the porch, in front
constant float  kKegHalf  = 0.125;                      // half-height of the keg body
constant float3 kKegPos   = float3(0.66, kGroundTop + kKegHalf, 0.66);

// MARK: - Primitives

static float sdBox(float3 p, float3 b) {
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

static float sdRoundBox(float3 p, float3 b, float r) {
    return sdBox(p, b - r) - r;
}

static float sdSphere(float3 p, float r) {
    return length(p) - r;
}

/// Truncated cone, axis along y, `h` half-height, `rb`/`rt` bottom/top radii.
/// A Solo cup is mostly its taper — a straight cylinder at this size just reads
/// as a red pill.
static float sdCup(float3 p, float h, float rb, float rt) {
    float2 q = float2(length(p.xz), p.y);
    float2 k1 = float2(rt, h);
    float2 k2 = float2(rt - rb, 2.0 * h);
    float2 ca = float2(q.x - min(q.x, (q.y < 0.0) ? rb : rt), abs(q.y) - h);
    float2 cb = q - k1 + k2 * clamp(dot(k1 - q, k2) / dot(k2, k2), 0.0, 1.0);
    float s = (cb.x < 0.0 && ca.y < 0.0) ? -1.0 : 1.0;
    return s * sqrt(min(dot(ca, ca), dot(cb, cb)));
}

/// Upright capped cylinder: `h` is half-height.
static float sdCylinder(float3 p, float r, float h) {
    float2 d = abs(float2(length(p.xz), p.y)) - float2(r, h);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
}

/// A gable roof: an exact convex SDF, built as a 2D triangle extruded in z.
///
/// Intersection of two slanted half-planes and the eave line — exact for a
/// convex shape as long as the plane normals are unit length, cheaper than a
/// generic triangle SDF, and convexity means the marcher never has to creep.
static float sdRoof(float3 p, float halfWidth, float height, float halfDepth) {
    float len = sqrt(height * height + halfWidth * halfWidth);
    float2 n = float2(height, halfWidth) / len;
    float c = halfWidth * height / len;

    float slant = dot(float2(abs(p.x), p.y), n) - c;
    float eave = -p.y;
    float profile = max(slant, eave);

    float depth = abs(p.z) - halfDepth;
    return min(max(profile, depth), 0.0) + length(max(float2(profile, depth), 0.0));
}

static float2 hash22(float2 p) {
    p = float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)));
    return fract(sin(p) * 43758.5453);
}

// MARK: - Scene

/// Cups and the keg, scattered by domain repetition.
///
/// One primitive evaluation covers every cup on the lawn: the point is folded
/// into a grid cell and the cup is jittered inside it by a hash. Placing a
/// dozen cups as a dozen `min()`s would be a dozen times the cost for a result
/// nobody could tell apart — and cells that would land under the house or the
/// porch simply return a large distance instead of being carved out.
static float sdLitter(float3 p) {
    const float cell = 0.24;
    float2 id = floor(p.xz / cell) + 0.5;
    // Jitter nearly the full cell, and drop a third of the cells outright.
    // At half a cell the cups still sat on a visible lattice — the eye finds
    // the rows long before it notices the offsets.
    float2 jitter = (hash22(id) - 0.5) * cell * 0.92;
    float2 centre = id * cell + jitter;
    if (hash22(id + 1.9).y > 0.74) { return 1e5; }

    // Cull before placing. Repetition is infinite by nature, so without this
    // the lawn is ringed by cups standing in mid-air off the edge of the world
    // — which is exactly what the first render looked like.
    bool offLawn = abs(centre.x) > 0.92 || abs(centre.y) > 0.82;
    bool underHouse = abs(centre.x) < kBody.x + 0.12 && abs(centre.y) < kBody.z + 0.12;
    bool onPath = abs(centre.x) < 0.27 && centre.y > kBody.z;
    if (offLawn || underHouse || onPath) { return 1e5; }

    // Roughly a third are knocked over. Rotation is an isometry, so tipping
    // one costs nothing in field accuracy — and a lawn of neatly upright cups
    // reads as a picnic rather than as the morning after.
    float roll = hash22(id + 7.3).x;
    float3 q = float3(p.x - centre.x, p.y - (kGroundTop + 0.030), p.z - centre.y);
    if (roll > 0.66) {
        float a = 1.5708;                       // on its side
        float ca = cos(a), sa = sin(a);
        q.yz = float2(q.y * ca - q.z * sa, q.y * sa + q.z * ca);
    }
    return sdCup(q, 0.040, 0.022, 0.035);
}

/// A keg: barrelled body, a flared chime at each end, and the valve well on
/// top. Those rims are the whole silhouette — a bare cylinder reads as a bin,
/// and at this size the chimes are the only detail with enough contrast to
/// survive. `p` is local to the keg's centre.
static float sdKeg(float3 p) {
    // Rounded on the long edges, so the body bulges slightly rather than
    // reading as a tin can.
    float body = sdCylinder(p, 0.070, kKegHalf - 0.014) - 0.014;
    float chimeTop = sdCylinder(p - float3(0.0,  kKegHalf - 0.010, 0.0), 0.088, 0.012);
    float chimeBot = sdCylinder(p - float3(0.0, -kKegHalf + 0.010, 0.0), 0.088, 0.012);
    float valve = sdCylinder(p - float3(0.0, kKegHalf + 0.012, 0.0), 0.022, 0.016);
    return min(min(body, valve), min(chimeTop, chimeBot));
}

/// Distance and material. `x` is the distance, `y` the material id.
static float2 mapScene(float3 p) {
    // Lawn: a rounded slab, so the whole thing reads as a plot of land rather
    // than a house adrift on an infinite plane.
    float2 best = float2(sdRoundBox(p - float3(0.0, kGroundTop - 0.07, 0.0),
                                    float3(1.00, 0.07, 0.90), 0.05), float(kGrass));

    float walls = sdBox(p - float3(0.0, kBodyY, 0.0), kBody);
    if (walls < best.x) { best = float2(walls, float(kWall)); }

    float roof = sdRoof(p - float3(0.0, kGroundTop + 2.0 * kBody.y, 0.0), 0.62, 0.42, 0.50);
    if (roof < best.x) { best = float2(roof, float(kRoof)); }

    // Porch: deck, two posts, a flat awning.
    // Kept shallow and narrower than the wall. A deep porch with a thick
    // awning stops reading as a porch and becomes a lean-to bolted to the side
    // of the house, which is what the first attempt looked like.
    float deck = sdBox(p - float3(0.0, kDeckTop - 0.03, kPorchZ), float3(0.32, 0.03, 0.16));
    float postL = sdBox(p - float3(-0.29, kDeckTop + 0.15, kPorchZ + 0.11), float3(0.018, 0.15, 0.018));
    float postR = sdBox(p - float3( 0.29, kDeckTop + 0.15, kPorchZ + 0.11), float3(0.018, 0.15, 0.018));
    // Spans from the wall out to the posts. A slab floating clear of the house
    // is what made the first porch read as a shed parked alongside it.
    float awningBack = kBody.z - 0.02;
    float awningFront = kPorchZ + 0.17;
    float awning = sdBox(p - float3(0.0, kDeckTop + 0.30, (awningBack + awningFront) * 0.5),
                         float3(0.34, 0.016, (awningFront - awningBack) * 0.5));

    // Two steps down to the grass.
    float step1 = sdBox(p - float3(0.0, kGroundTop + 0.080, kPorchZ + 0.20), float3(0.20, 0.028, 0.048));
    float step2 = sdBox(p - float3(0.0, kGroundTop + 0.028, kPorchZ + 0.29), float3(0.20, 0.028, 0.048));

    float wood = min(min(min(deck, awning), min(postL, postR)), min(step1, step2));
    if (wood < best.x) { best = float2(wood, float(kWood)); }

    // Bushes: overlapping spheres, so each clump has a silhouette rather than
    // reading as a ball.
    float bush = sdSphere(p - float3(-0.74, kGroundTop + 0.06, 0.34), 0.135);
    bush = min(bush, sdSphere(p - float3(-0.62, kGroundTop + 0.04, 0.48), 0.100));
    bush = min(bush, sdSphere(p - float3( 0.76, kGroundTop + 0.06, 0.30), 0.125));
    bush = min(bush, sdSphere(p - float3(-0.80, kGroundTop + 0.05, -0.42), 0.115));
    if (bush < best.x) { best = float2(bush, float(kBush)); }

    float cups = sdLitter(p);
    if (cups < best.x) { best = float2(cups, float(kCup)); }

    // The keg, on its own — one object, and it wants a specific spot.
    float keg = sdKeg(p - kKegPos);
    if (keg < best.x) { best = float2(keg, float(kKeg)); }

    return best;
}

static float mapDist(float3 p) { return mapScene(p).x; }

static float3 sceneNormal(float3 p) {
    // Tetrahedral gradient — four taps instead of six, and no axis bias.
    const float2 k = float2(1.0, -1.0);
    const float h = 0.0015;
    return normalize(k.xyy * mapDist(p + k.xyy * h) +
                     k.yyx * mapDist(p + k.yyx * h) +
                     k.yxy * mapDist(p + k.yxy * h) +
                     k.xxx * mapDist(p + k.xxx * h));
}

// MARK: - Windows and door

/// Rounded-rectangle coverage, soft-edged. `soft` is in wall units, so the edge
/// stays a constant world width and the panes don't turn to mush as the house
/// turns away.
static float windowRect(float2 p, float2 centre, float2 halfSize, float soft) {
    float2 q = abs(p - centre) - halfSize;
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
    return 1.0 - smoothstep(-soft, soft, d);
}

/// Openings on a given wall, in that wall's own 2D coordinates.
///
/// The broad ±z faces carry a 2×2 grid; the narrow ends carry the same panes
/// stacked, so the storeys line up all the way round. The front face — and only
/// the front — also gets the doorway, which is why the caller passes the sign
/// of the face rather than just its axis.
static float openings(float2 wall, bool broadFace, bool isFront, float soft) {
    float m = 0.0;
    if (broadFace) {
        m = max(m, windowRect(wall, float2(-0.27, -0.14), float2(0.105, 0.080), soft));
        m = max(m, windowRect(wall, float2( 0.27, -0.14), float2(0.105, 0.080), soft));
        m = max(m, windowRect(wall, float2(-0.27,  0.13), float2(0.105, 0.080), soft));
        m = max(m, windowRect(wall, float2( 0.27,  0.13), float2(0.105, 0.080), soft));
        if (isFront) {
            // The door is open — it's a hole with the party behind it, not a
            // panel. Reaching the floor is what makes it read as a doorway
            // rather than a fifth window.
            m = max(m, windowRect(wall, float2(0.0, -0.215), float2(0.098, 0.155), soft));
        }
    } else {
        m = max(m, windowRect(wall, float2(0.0, -0.14), float2(0.105, 0.080), soft));
        m = max(m, windowRect(wall, float2(0.0,  0.13), float2(0.105, 0.080), soft));
    }
    return m;
}

/// The party. Three coloured spots sweeping the wall plane, plus a beat.
static float3 discoLight(float2 wall, float t) {
    float3 col = float3(0.0);

    // Non-commensurate speeds, so the three never lock into a pattern the eye
    // can predict and the loop never visibly repeats.
    float2 a = float2(cos(t * 1.70), sin(t * 1.21)) * 0.34;
    float2 b = float2(cos(t * -1.13 + 2.1), sin(t * 1.57 + 0.7)) * 0.30;
    float2 c = float2(cos(t * 0.87 + 4.0), sin(t * -1.39 + 1.9)) * 0.36;

    // Tight falloff, so each stays a distinct beam sweeping past an opening
    // rather than three washes summing into one flat pink.
    col += float3(2.30, 0.12, 1.40) / (1.0 + 42.0 * dot(wall - a, wall - a));
    col += float3(0.12, 1.30, 2.20) / (1.0 + 48.0 * dot(wall - b, wall - b));
    col += float3(1.90, 1.15, 0.10) / (1.0 + 36.0 * dot(wall - c, wall - c));

    // A floor, so an opening never goes fully dark between passes — an unlit
    // window reads as a hole punched in the wall rather than as a dim room.
    col += float3(0.16, 0.05, 0.22);

    // Beat. Cubed so it snaps rather than breathes: it's a party, and a plain
    // sine reads as a sleeping pet.
    float beat = 0.62 + 0.38 * pow(0.5 + 0.5 * sin(t * 5.4), 3.0);
    return col * beat;
}

// MARK: - Entry point

[[ stitchable ]] half4 discoHouse(float2 position,
                                  half4 currentColor,
                                  float2 size,
                                  float spin,
                                  float time) {
    float2 uv = (position - size * 0.5) / (min(size.x, size.y) * 0.5);
    uv.y = -uv.y;                       // SwiftUI is y-down; the field is y-up.

    // The camera is rotated into the object's frame rather than the object into
    // the world's. Costs the same, and the hit point arrives already in the
    // scene's own coordinates — which is what the wall mapping and the litter
    // grid both need.
    float3 ro = float3(0.0, 0.02, 3.20);
    float3 rd = normalize(float3(uv * 0.44, -1.0));

    // Negative tilt looks *down* on the scene. Positive put the camera under
    // the lawn, which hid the grass entirely — the thing the litter is on.
    const float tilt = -0.34;
    float ct = cos(tilt), st = sin(tilt);
    ro.yz = float2(ro.y * ct - ro.z * st, ro.y * st + ro.z * ct);
    rd.yz = float2(rd.y * ct - rd.z * st, rd.y * st + rd.z * ct);

    float cs = cos(spin), ss = sin(spin);
    ro.xz = float2(ro.x * cs - ro.z * ss, ro.x * ss + ro.z * cs);
    rd.xz = float2(rd.x * cs - rd.z * ss, rd.x * ss + rd.z * cs);

    float t = 0.0;
    float closest = 1e9;
    float material = 0.0;
    for (int i = 0; i < 110; i++) {
        float3 p = ro + rd * t;
        float2 hit = mapScene(p);
        closest = min(closest, hit.x);
        material = hit.y;
        if (hit.x < 0.0007) { break; }
        t += hit.x;
        if (t > 7.0) { break; }
    }

    // Closest-approach antialiasing, same scheme as the orb: rays that only
    // grazed get partial coverage. These SDFs are exact, so `closest` is
    // already in world units and needs no rescaling.
    float aa = 0.9 * (2.0 * 0.44 * 3.20) / min(size.x, size.y);
    float alpha = 1.0 - smoothstep(0.0, aa, closest);
    if (alpha <= 0.002) { return half4(0.0h); }

    float3 p = ro + rd * t;
    float3 n = sceneNormal(p);
    int mat = int(material + 0.5);

    // Ambient from the shared room, plus one key light. Deliberately restrained
    // across the board: everything here is matte, and the openings have to stay
    // the brightest thing on screen.
    float key = saturate(dot(n, normalize(float3(-0.40, 0.85, 0.45))));
    float ambient = softbox(n, 0.75, 0.34);

    float3 albedo;
    switch (mat) {
        case kRoof:  albedo = float3(0.085, 0.090, 0.115); break;
        case kWood:  albedo = float3(0.230, 0.180, 0.140); break;
        case kGrass: albedo = float3(0.085, 0.205, 0.095); break;
        case kBush:  albedo = float3(0.105, 0.260, 0.120); break;
        case kCup:   albedo = float3(0.850, 0.090, 0.090); break;
        case kKeg:   albedo = float3(0.620, 0.650, 0.690); break;
        default:     albedo = float3(0.135, 0.140, 0.165); break;   // walls
    }

    // Keg detailing. Flat grey reads as plastic; stainless needs the rims to
    // catch light while the recessed top stays dark, which is most of what
    // tells you it's a keg and not a bin.
    if (mat == kKeg) {
        float3 local = p - kKegPos;
        float rim = 1.0 - smoothstep(0.006, 0.020, abs(abs(local.y) - (kKegHalf - 0.010)));
        albedo = mix(albedo, float3(0.860, 0.885, 0.930), rim * 0.85);
        // The well the valve sits in.
        if (local.y > kKegHalf - 0.004 && length(local.xz) < 0.058) {
            albedo = float3(0.185, 0.200, 0.225);
        }
    }

    // The white lining. A Solo cup is red outside and white in, and the opening
    // is most of what you see of one lying on grass — so the cap face gets the
    // liner. The cup's own axis is rebuilt from the same hash that placed it,
    // since a tipped cup's opening points along world -z rather than up.
    if (mat == kCup) {
        const float cell = 0.24;   // must match sdLitter
        float2 id = floor(p.xz / cell) + 0.5;
        bool tipped = hash22(id + 7.3).x > 0.66;
        float3 axis = tipped ? float3(0.0, 0.0, -1.0) : float3(0.0, 1.0, 0.0);
        if (dot(n, axis) > 0.5) { albedo = float3(0.900, 0.890, 0.870); }
    }

    // Grass gets a per-blade-ish break-up so the lawn isn't a flat green shape.
    if (mat == kGrass) {
        float2 g = hash22(floor(p.xz * 150.0));
        albedo *= 0.78 + 0.44 * g.x;
    }

    float3 col = albedo * (ambient * 0.55 + key * 0.85);

    // One sharp highlight, metals only. Without it the keg is a grey shape the
    // same brightness from every angle, which is exactly what plastic does.
    if (mat == kKeg) {
        float3 mirror = reflect(rd, n);
        col += float3(1.0) * pow(saturate(dot(mirror, normalize(float3(-0.40, 0.85, 0.45)))), 42.0) * 0.65;
    }

    // Openings, and the light coming through them. Only the walls carry these.
    float3 party = discoLight(float2(0.0), time);
    if (mat == kWall) {
        bool broadFace = abs(n.z) > abs(n.x);
        bool isFront = broadFace && n.z > 0.0;
        float2 wall = broadFace ? float2(p.x, p.y - kBodyY) : float2(p.z, p.y - kBodyY);
        float vertical = 1.0 - smoothstep(0.55, 0.85, abs(n.y));   // 0 on the cap

        party = discoLight(wall, time);
        float pane = openings(wall, broadFace, isFront, 0.010) * vertical;
        // The same field, blurred, is the light spilling onto the wall around
        // each opening. Reusing it rather than adding a separate glow is what
        // keeps the spill attached to the frame as the house turns.
        float spill = openings(wall, broadFace, isFront, 0.085) * vertical;

        col += party * spill * 0.16;
        col = mix(col, party * 0.85, pane);
        // A hot core just inside each opening, so the brightest thing on screen
        // is unambiguously coming from inside the building.
        col += party * pane * pane * 0.55;
    } else {
        // Everything outside catches a little of the doorway. A single point
        // just past the threshold, falling off with distance — enough to tie
        // the porch and the nearest grass to the party without pretending to
        // be a real light bounce.
        float3 doorway = float3(0.0, kGroundTop + 0.16, kBody.z + 0.02);
        float3 toDoor = p - doorway;
        float fall = 1.0 / (1.0 + 18.0 * dot(toDoor, toDoor));
        // Only surfaces facing the door, so the back of the house stays dark.
        float facing = saturate(dot(n, normalize(-toDoor)));
        col += party * fall * facing * 0.30;
    }

    col = glassTonemap(col, 1.35, 1.30);
    return half4(half3(col) * half(alpha), half(alpha));
}
