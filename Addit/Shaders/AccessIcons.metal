#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
#include "GlassRoom.h"

using namespace metal;

// The three ornaments on the Access sheet: a turning globe for "anyone with the
// link", a hazard plate for "restricted", and a chrome chain for the link
// itself.
//
// One file because they're a set — they sit in one list, at one size, and have
// to read as three objects lit in the same room. They borrow `softbox` and
// `glassTonemap` from GlassRoom.h for exactly that reason, and each still
// writes its own `environment`, since a planet, a warning sign and polished
// steel are not made of the same thing.
//
// All three are ~32pt, so a few thousand pixels each. The globe and the chain
// are analytic intersections rather than marched fields; only the hazard plate
// needs a loop.

// MARK: - Shared

/// Cheap 3D value noise. Not a great noise — good enough for coastlines at a
/// size where a continent is nine pixels across.
static float hash31(float3 p) {
    p = fract(p * 0.3183099 + float3(0.71, 0.113, 0.419));
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

static float valueNoise(float3 x) {
    float3 i = floor(x);
    float3 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(hash31(i + float3(0, 0, 0)), hash31(i + float3(1, 0, 0)), f.x),
                   mix(hash31(i + float3(0, 1, 0)), hash31(i + float3(1, 1, 0)), f.x), f.y),
               mix(mix(hash31(i + float3(0, 0, 1)), hash31(i + float3(1, 0, 1)), f.x),
                   mix(hash31(i + float3(0, 1, 1)), hash31(i + float3(1, 1, 1)), f.x), f.y), f.z);
}

static float fbm(float3 p) {
    float sum = 0.0, amp = 0.5;
    for (int i = 0; i < 5; i++) {
        sum += amp * valueNoise(p);
        p *= 2.03;
        amp *= 0.5;
    }
    return sum;
}

/// Nearest hit of a ray with a sphere at the origin, or -1.
static float sphereHit(float3 ro, float3 rd, float radius) {
    float b = dot(ro, rd);
    float c = dot(ro, ro) - radius * radius;
    float h = b * b - c;
    if (h < 0.0) { return -1.0; }
    return -b - sqrt(h);
}

/// Camera ray for a square icon. `uv` is -1…1 with y up.
static void iconCamera(float2 uv, float dist, thread float3 &ro, thread float3 &rd) {
    ro = float3(0.0, 0.0, dist);
    rd = normalize(float3(uv * 0.52, -1.0));
}

/// Spin a point about Y.
static float3 spinY(float3 p, float a) {
    float c = cos(a), s = sin(a);
    return float3(p.x * c - p.z * s, p.y, p.x * s + p.z * c);
}

// MARK: - Globe

/// A silver-blue room. The globe is mostly lit rather than mirrored, so this
/// only has to supply the ocean's reflection and the rim.
static float3 globeEnvironment(float3 d) {
    d = normalize(d);
    float3 col = mix(float3(0.06, 0.10, 0.18), float3(0.55, 0.72, 0.95), saturate(d.y * 0.5 + 0.5));
    col *= softbox(d, 0.85, 0.25);
    col += float3(3.0) * pow(saturate(dot(d, normalize(float3(-0.45, 0.75, 0.48)))), 90.0);
    return col;
}

[[ stitchable ]] half4 accessGlobe(float2 position,
                                   half4 currentColor,
                                   float2 size,
                                   float spin) {
    float2 uv = (position - size * 0.5) / (min(size.x, size.y) * 0.5);
    uv.y = -uv.y;

    // 2.28 is the near limit, not a look. The edge ray leaves the camera at
    // atan(0.52) and passes the origin at `dist * 0.4613`, so anything closer
    // than ~2.17 puts the sphere's own silhouette outside the frame and the
    // globe renders as a square with its corners rounded off. This leaves just
    // enough for the atmosphere too.
    float3 ro, rd;
    iconCamera(uv, 2.28, ro, rd);

    const float radius = 1.0;
    float t = sphereHit(ro, rd, radius);

    // Atmosphere: a soft shell outside the surface, so the planet has an edge
    // that glows rather than one that simply stops.
    float d2 = length(cross(ro, rd));          // ray's closest approach to centre
    float halo = smoothstep(radius * 1.03, radius * 0.99, d2);

    if (t < 0.0) {
        float3 air = float3(0.16, 0.46, 0.95) * halo * 0.55;
        float alpha = halo * 0.55;
        if (alpha <= 0.003) { return half4(0.0h); }
        return half4(half3(glassTonemap(air, 1.5, 1.2)) * half(alpha), half(alpha));
    }

    float3 p = ro + rd * t;
    float3 n = normalize(p);

    // Sample the land in the globe's own frame, so the continents turn with it
    // instead of the light sliding over a fixed map.
    float3 sp = spinY(n, -spin);

    // Two octave sets: a low one that decides where continents are at all, and
    // a higher one that roughens the coast. Squashing y slightly makes
    // landmasses run east-west, which is what stops it reading as lichen.
    float land = fbm(sp * 1.85 + float3(0.0, 0.0, 4.2)) * 0.75
               + fbm(sp * float3(4.3, 3.1, 4.3)) * 0.25;
    float isLand = smoothstep(0.452, 0.492, land);

    // Ice at the poles, following the same coastline so it doesn't look painted
    // on in a straight band.
    float ice = smoothstep(0.74, 0.93, abs(sp.y) + land * 0.10);

    const float3 kOcean    = float3(0.02, 0.11, 0.40);
    const float3 kShallows = float3(0.05, 0.28, 0.62);
    const float3 kGreen    = float3(0.20, 0.53, 0.19);
    const float3 kArid     = float3(0.62, 0.51, 0.22);

    // Ocean stays close to uniform. Letting the continent noise show through
    // the water is what made the first pass read as mould rather than sea.
    float3 sea = mix(kShallows, kOcean, smoothstep(0.36, 0.46, land));
    float3 ground = mix(kGreen, kArid, smoothstep(0.50, 0.63, land));
    float3 albedo = mix(sea, ground, isLand);
    albedo = mix(albedo, float3(0.92, 0.95, 0.99), ice);

    // One key light, so there's a terminator. A globe lit flat from the camera
    // is a circle with a pattern on it.
    float3 lightDir = normalize(float3(-0.55, 0.62, 0.62));
    float diffuse = saturate(dot(n, lightDir));
    float wrap = saturate(dot(n, lightDir) * 0.5 + 0.5);   // softened terminator

    float3 col = albedo * (0.16 + 1.25 * mix(diffuse, wrap, 0.45));

    // Water is the only shiny part; land stays matte or the whole thing looks
    // shrink-wrapped.
    float3 mirror = reflect(rd, n);
    float gloss = (1.0 - isLand) * (1.0 - ice);
    col += globeEnvironment(mirror) * 0.14 * gloss;
    col += float3(1.5, 1.7, 1.8) * pow(saturate(dot(mirror, lightDir)), 90.0) * gloss;

    // Atmosphere over the limb, and a warmer scatter where the light grazes.
    float facing = saturate(dot(n, -rd));
    float rim = pow(1.0 - facing, 3.2);
    col += float3(0.20, 0.48, 1.00) * rim * 0.95;
    col += float3(0.30, 0.50, 0.95) * halo * 0.14;

    col = glassTonemap(col, 1.45, 1.22);
    return half4(half3(col), 1.0h);
}

// MARK: - Hazard plate

/// 2D equilateral triangle, rounded by `r`.
static float sdTriangle2D(float2 p, float size) {
    const float k = 1.7320508;             // sqrt(3)
    p.x = abs(p.x) - size;
    p.y = p.y + size / k;
    if (p.x + k * p.y > 0.0) {
        p = float2(p.x - k * p.y, -k * p.x - p.y) / 2.0;
    }
    p.x -= clamp(p.x, -2.0 * size, 0.0);
    return -length(p) * sign(p.y);
}

/// The plate: a rounded triangle extruded in z.
static float sdHazard(float3 p, float bevel) {
    float d2 = sdTriangle2D(p.xy, 0.86) - bevel;
    float2 w = float2(d2, abs(p.z) - 0.17);
    return min(max(w.x, w.y), 0.0) + length(max(w, 0.0)) - 0.05;
}

static float3 hazardNormal(float3 p, float bevel) {
    const float2 e = float2(1.0, -1.0) * 0.0016;
    return normalize(e.xyy * sdHazard(p + e.xyy, bevel) +
                     e.yyx * sdHazard(p + e.yyx, bevel) +
                     e.yxy * sdHazard(p + e.yxy, bevel) +
                     e.xxx * sdHazard(p + e.xxx, bevel));
}

/// The glyph, in plate coordinates: a fat exclamation mark inside a black
/// border that follows the triangle. Drawn as a mask rather than cut out of the
/// field — a hole in an SDF costs another CSG term and reads no better at 32pt.
static float hazardGlyphMask(float2 q) {
    // Border: a band just inside the edge. Both ramps run the same direction
    // and are SUBTRACTED — multiplying two open-ended ramps selects everything
    // deeper than the shallower one, which is the entire interior, not a band.
    float edge = sdTriangle2D(q, 0.86);
    float border = smoothstep(-0.125, -0.150, edge) - smoothstep(-0.235, -0.260, edge);

    // Bar of the exclamation, tapering toward the top with the triangle.
    float2 b = q - float2(0.0, 0.30);
    float barW = mix(0.115, 0.082, saturate((b.y + 0.27) / 0.54));
    float bar = smoothstep(0.012, 0.0, max(abs(b.x) - barW, abs(b.y) - 0.27));

    // Dot, kept clear of the border band below it.
    float dot1 = smoothstep(0.012, 0.0, length(q - float2(0.0, -0.13)) - 0.105);

    return saturate(max(border, max(bar, dot1)));
}

[[ stitchable ]] half4 accessHazard(float2 position,
                                    half4 currentColor,
                                    float2 size,
                                    float spin) {
    float2 uv = (position - size * 0.5) / (min(size.x, size.y) * 0.5);
    uv.y = -uv.y;

    float3 ro, rd;
    iconCamera(uv, 2.78, ro, rd);

    // Rocked, not spun — the same rule the library's brand marks follow. A sign
    // that turns edge-on disappears, and a warning that vanishes is a poor one.
    float yaw = 0.55 * sin(spin);
    float pitch = 0.16 * sin(spin * 0.73 + 1.1);

    float cy = cos(yaw), sy = sin(yaw);
    ro.xz = float2(ro.x * cy - ro.z * sy, ro.x * sy + ro.z * cy);
    rd.xz = float2(rd.x * cy - rd.z * sy, rd.x * sy + rd.z * cy);
    float cp = cos(pitch), sp2 = sin(pitch);
    ro.yz = float2(ro.y * cp - ro.z * sp2, ro.y * sp2 + ro.z * cp);
    rd.yz = float2(rd.y * cp - rd.z * sp2, rd.y * sp2 + rd.z * cp);

    const float bevel = 0.055;
    float t = 0.0;
    float closest = 1e9;
    bool hit = false;
    for (int i = 0; i < 72; i++) {
        float3 p = ro + rd * t;
        float d = sdHazard(p, bevel);
        closest = min(closest, d);
        if (d < 0.0016) { hit = true; break; }
        t += d * 0.92;
        if (t > 6.0) { break; }
    }

    // Closest-approach antialiasing, same trick as the orb.
    float alpha = hit ? 1.0 : smoothstep(0.02, 0.0, closest);
    if (alpha <= 0.004) { return half4(0.0h); }
    if (!hit) { t = max(t, 0.001); }

    float3 p = ro + rd * t;
    float3 n = hazardNormal(p, bevel);
    float3 v = -rd;

    // Faces get the glyph; the bevel and the rim keep the plate colour, which is
    // what gives the sign its moulded edge.
    float faceness = smoothstep(0.55, 0.90, abs(n.z));
    float glyph = hazardGlyphMask(p.xy) * faceness;

    const float3 kYellow = float3(1.00, 0.78, 0.05);
    const float3 kBlack  = float3(0.05, 0.045, 0.04);
    float3 albedo = mix(kYellow, kBlack, glyph);

    float3 lightDir = normalize(float3(-0.42, 0.72, 0.68));
    float diffuse = saturate(dot(n, lightDir));
    float3 col = albedo * (0.30 + 0.95 * diffuse);

    // Hard plastic: one tight highlight and one broad fill, plus a bright top
    // edge. This is the 2000s part — the look comes from an obvious specular
    // rather than from any real roughness model.
    float3 h = normalize(lightDir + v);
    col += float3(1.0) * pow(saturate(dot(n, h)), 68.0) * 0.85 * (1.0 - glyph * 0.75);
    col += float3(0.55, 0.42, 0.16) * pow(saturate(dot(n, normalize(float3(0.6, -0.3, 0.7)))), 6.0) * 0.35;
    col += kYellow * pow(saturate(1.0 - abs(dot(n, v))), 3.0) * 0.55;

    col = glassTonemap(col, 1.5, 1.35);
    return half4(half3(col) * half(alpha), half(alpha));
}

// MARK: - Chain

/// A chrome room: neutral, high contrast, strips rather than a wash — without
/// the strips a mirrored torus is a grey doughnut.
static float3 chromeEnvironment(float3 d) {
    d = normalize(d);
    float3 col = mix(float3(0.06, 0.07, 0.10), float3(1.05, 1.12, 1.26), saturate(d.y * 0.5 + 0.5));
    col *= softbox(d, 1.35, 0.04) * 2.15;
    col += float3(0.35, 0.42, 0.58) * pow(saturate(dot(d, normalize(float3(0.65, 0.25, 0.70)))), 5.0);
    col += float3(7.0) * pow(saturate(dot(d, normalize(float3(-0.40, 0.85, 0.35)))), 130.0);
    return col;
}

/// Torus lying in XZ with its axis along Y.
static float sdTorus(float3 p, float2 t) {
    float2 q = float2(length(p.xz) - t.x, p.y);
    return length(q) - t.y;
}

/// Two interlocking links. The second is the first with y and z swapped, which
/// stands its ring up perpendicular to the first — that is the whole trick.
static float sdChain(float3 p) {
    const float2 ring = float2(0.50, 0.155);
    float a = sdTorus(p - float3(-0.40, 0.0, 0.0), ring);
    float3 q = p - float3(0.40, 0.0, 0.0);
    float b = sdTorus(float3(q.x, q.z, q.y), ring);
    return min(a, b);
}

static float3 chainNormal(float3 p) {
    const float2 e = float2(1.0, -1.0) * 0.0014;
    return normalize(e.xyy * sdChain(p + e.xyy) +
                     e.yyx * sdChain(p + e.yyx) +
                     e.yxy * sdChain(p + e.yxy) +
                     e.xxx * sdChain(p + e.xxx));
}

[[ stitchable ]] half4 accessChain(float2 position,
                                   half4 currentColor,
                                   float2 size,
                                   float spin) {
    float2 uv = (position - size * 0.5) / (min(size.x, size.y) * 0.5);
    uv.y = -uv.y;

    float3 ro, rd;
    iconCamera(uv, 2.34, ro, rd);

    // Rocking again, and tilted so both links are seen at an angle — square on,
    // two interlocking rings read as a flat figure-of-eight.
    float yaw = 0.62 * sin(spin) + 0.30;
    float pitch = -0.42 + 0.12 * sin(spin * 0.81 + 0.6);

    float cy = cos(yaw), sy = sin(yaw);
    ro.xz = float2(ro.x * cy - ro.z * sy, ro.x * sy + ro.z * cy);
    rd.xz = float2(rd.x * cy - rd.z * sy, rd.x * sy + rd.z * cy);
    float cp = cos(pitch), sp2 = sin(pitch);
    ro.yz = float2(ro.y * cp - ro.z * sp2, ro.y * sp2 + ro.z * cp);
    rd.yz = float2(rd.y * cp - rd.z * sp2, rd.y * sp2 + rd.z * cp);

    // Roll, so the chain runs corner to corner. Two links side by side are a
    // wide, short shape; left level they leave the top and bottom of a square
    // icon empty and end up smaller than everything beside them.
    const float roll = 0.62;
    float cr = cos(roll), sr = sin(roll);
    ro.xy = float2(ro.x * cr - ro.y * sr, ro.x * sr + ro.y * cr);
    rd.xy = float2(rd.x * cr - rd.y * sr, rd.x * sr + rd.y * cr);

    float t = 0.0;
    float closest = 1e9;
    bool hit = false;
    for (int i = 0; i < 90; i++) {
        float3 p = ro + rd * t;
        float d = sdChain(p);
        closest = min(closest, d);
        if (d < 0.0014) { hit = true; break; }
        t += d * 0.90;
        if (t > 6.5) { break; }
    }

    float alpha = hit ? 1.0 : smoothstep(0.018, 0.0, closest);
    if (alpha <= 0.004) { return half4(0.0h); }
    if (!hit) { t = max(t, 0.001); }

    float3 p = ro + rd * t;
    float3 n = chainNormal(p);
    float3 v = -rd;
    float facing = saturate(dot(n, v));

    // Chrome is almost pure mirror; the Fresnel floor is high because polished
    // steel reflects strongly even head-on.
    float fresnel = mix(0.62, 1.0, pow(1.0 - facing, 4.0));
    float3 mirror = reflect(rd, n);
    float3 col = chromeEnvironment(mirror) * fresnel;

    // A dark steel body under the reflection, so the links have mass where the
    // room happens to be dim.
    col += float3(0.16, 0.17, 0.20) * (0.30 + 0.70 * saturate(dot(n, normalize(float3(-0.3, 0.8, 0.5)))));

    col += float3(1.7, 1.72, 1.75) * pow(saturate(dot(mirror, normalize(float3(-0.40, 0.85, 0.35)))), 200.0);
    col *= iridescence(facing, 0.06);

    col = glassTonemap(col, 1.9, 1.02);
    return half4(half3(col) * half(alpha), half(alpha));
}
