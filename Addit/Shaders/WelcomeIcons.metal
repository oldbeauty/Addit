#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
#include "GlassRoom.h"

using namespace metal;

// Two ornaments for the welcome cards: a folder with a record rising out of it
// ("folders in the cloud are albums"), and the record itself ("add a folder and
// it arrives as an album").
//
// The other two cards reuse ornaments the app already owns — the plasma orb for
// the welcome, the chrome chain for sharing — so only the ideas with no mark
// yet are modelled here.
//
// Both are lit from the shared rig in GlassRoom.h, so they sit in the same room
// as the Access sheet's set rather than looking like clip art borrowed in.
//
// Their camera distances are not chosen by eye. The welcome cards put these
// beside the plasma orb, which fills 79% of its box, and anything appreciably
// smaller reads as an undersized icon rather than a different object. The
// distances below were set by rendering all four and measuring the ink, then
// scaling — the bounding-sphere arithmetic badly overestimates a rocking box,
// so measuring is the only honest way to match them.

// MARK: - Shared

static float sdRoundBox(float3 p, float3 b, float r) {
    float3 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - r;
}

/// Cylinder with its axis along Y.
static float sdCylinderY(float3 p, float radius, float halfHeight) {
    float2 d = float2(length(p.xz) - radius, abs(p.y) - halfHeight);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
}

/// The room these two live in: warm key, cool fill, hard white highlight.
static float3 welcomeEnvironment(float3 d) {
    d = normalize(d);
    float3 col = mix(float3(0.05, 0.06, 0.09), float3(0.62, 0.68, 0.80),
                     saturate(d.y * 0.5 + 0.5));
    col *= softbox(d, 1.05, 0.10) * 1.35;
    col += float3(1.10, 0.78, 0.42) * pow(saturate(dot(d, normalize(float3(-0.55, 0.55, 0.60)))), 6.0) * 0.55;
    col += float3(6.0) * pow(saturate(dot(d, normalize(float3(-0.40, 0.86, 0.32)))), 120.0);
    return col;
}

static void welcomeCamera(float2 uv, float dist, thread float3 &ro, thread float3 &rd) {
    ro = float3(0.0, 0.0, dist);
    rd = normalize(float3(uv * 0.52, -1.0));
}

/// Rock and tilt shared by both — they read as objects being turned over, not
/// as spinning icons. Same rule the library's brand marks follow.
static void rockCamera(thread float3 &ro, thread float3 &rd, float spin,
                       float yawAmount, float pitchBase) {
    float yaw = yawAmount * sin(spin);
    float pitch = pitchBase + 0.10 * sin(spin * 0.77 + 0.9);
    float cy = cos(yaw), sy = sin(yaw);
    ro.xz = float2(ro.x * cy - ro.z * sy, ro.x * sy + ro.z * cy);
    rd.xz = float2(rd.x * cy - rd.z * sy, rd.x * sy + rd.z * cy);
    float cp = cos(pitch), sp = sin(pitch);
    ro.yz = float2(ro.y * cp - ro.z * sp, ro.y * sp + ro.z * cp);
    rd.yz = float2(rd.y * cp - rd.z * sp, rd.y * sp + rd.z * cp);
}

// MARK: - Folder with a record in it

/// Materials: 1 back panel, 2 front panel, 3 record.
static float2 mapFolder(float3 p) {
    // Back panel, with the tab standing proud of its top-left corner.
    float back = sdRoundBox(p - float3(0.0, 0.0, -0.10), float3(0.62, 0.44, 0.045), 0.05);
    float tab  = sdRoundBox(p - float3(-0.36, 0.47, -0.10), float3(0.22, 0.075, 0.045), 0.035);
    back = min(back, tab);

    // The record, sandwiched between the panels so only its upper arc shows.
    float3 r = p - float3(0.06, 0.16, 0.0);
    float record = sdCylinderY(float3(r.x, r.z, r.y), 0.40, 0.022);

    // Front panel, shorter than the back so the record clears its rim.
    float front = sdRoundBox(p - float3(0.0, -0.07, 0.12), float3(0.62, 0.37, 0.04), 0.05);

    float2 best = float2(back, 1.0);
    if (record < best.x) { best = float2(record, 3.0); }
    if (front < best.x)  { best = float2(front, 2.0); }
    return best;
}

static float3 folderNormal(float3 p) {
    const float2 e = float2(1.0, -1.0) * 0.0015;
    return normalize(e.xyy * mapFolder(p + e.xyy).x +
                     e.yyx * mapFolder(p + e.yyx).x +
                     e.yxy * mapFolder(p + e.yxy).x +
                     e.xxx * mapFolder(p + e.xxx).x);
}

[[ stitchable ]] half4 welcomeFolder(float2 position,
                                     half4 currentColor,
                                     float2 size,
                                     float spin) {
    float2 uv = (position - size * 0.5) / (min(size.x, size.y) * 0.5);
    uv.y = -uv.y;

    float3 ro, rd;
    welcomeCamera(uv, 1.59, ro, rd);
    rockCamera(ro, rd, spin, 0.48, -0.20);

    float t = 0.0, closest = 1e9, material = 0.0;
    bool hit = false;
    for (int i = 0; i < 88; i++) {
        float3 p = ro + rd * t;
        float2 m = mapFolder(p);
        closest = min(closest, m.x);
        if (m.x < 0.0016) { hit = true; material = m.y; break; }
        t += m.x * 0.90;
        if (t > 6.0) { break; }
    }
    float alpha = hit ? 1.0 : smoothstep(0.02, 0.0, closest);
    if (alpha <= 0.004) { return half4(0.0h); }
    if (!hit) { t = max(t, 0.001); }

    float3 p = ro + rd * t;
    float3 n = folderNormal(p);
    float3 v = -rd;

    // Kraft card for the folder, near-black vinyl for the record.
    float3 albedo;
    if (material > 2.5) {
        albedo = float3(0.055, 0.05, 0.06);
        // Grooves: rings in the record's own plane.
        float rings = 0.5 + 0.5 * sin(length((p - float3(0.06, 0.16, 0.0)).xy) * 150.0);
        albedo += rings * 0.035;
        // Label.
        if (length((p - float3(0.06, 0.16, 0.0)).xy) < 0.14) {
            albedo = float3(0.72, 0.30, 0.20);
        }
    } else {
        albedo = material > 1.5 ? float3(0.86, 0.66, 0.32) : float3(0.72, 0.53, 0.25);
    }

    float3 lightDir = normalize(float3(-0.45, 0.72, 0.62));
    float diffuse = saturate(dot(n, lightDir));
    float3 col = albedo * (0.26 + 0.95 * diffuse);

    float3 mirror = reflect(rd, n);
    // Vinyl is glossy; card is not.
    float gloss = material > 2.5 ? 0.30 : 0.06;
    col += welcomeEnvironment(mirror) * gloss;
    float3 h = normalize(lightDir + v);
    col += float3(1.0) * pow(saturate(dot(n, h)), material > 2.5 ? 90.0 : 24.0)
         * (material > 2.5 ? 0.75 : 0.18);

    col = glassTonemap(col, 1.5, 1.20);
    return half4(half3(col) * half(alpha), half(alpha));
}

// MARK: - The record on its own

static float sdRecord(float3 p) {
    float disc = sdCylinderY(p, 0.80, 0.030);
    // Spindle hole.
    float hole = sdCylinderY(p, 0.055, 0.20);
    return max(disc, -hole);
}

static float3 recordNormal(float3 p) {
    const float2 e = float2(1.0, -1.0) * 0.0014;
    return normalize(e.xyy * sdRecord(p + e.xyy) +
                     e.yyx * sdRecord(p + e.yyx) +
                     e.yxy * sdRecord(p + e.yxy) +
                     e.xxx * sdRecord(p + e.xxx));
}

[[ stitchable ]] half4 welcomeRecord(float2 position,
                                     half4 currentColor,
                                     float2 size,
                                     float spin) {
    float2 uv = (position - size * 0.5) / (min(size.x, size.y) * 0.5);
    uv.y = -uv.y;

    float3 ro, rd;
    welcomeCamera(uv, 1.98, ro, rd);
    // Steeper tilt than the folder: a record seen edge-on is a line, and seen
    // flat-on is a circle. The interesting read is between the two.
    rockCamera(ro, rd, spin, 0.30, -0.95);

    float t = 0.0, closest = 1e9;
    bool hit = false;
    for (int i = 0; i < 80; i++) {
        float3 p = ro + rd * t;
        float d = sdRecord(p);
        closest = min(closest, d);
        if (d < 0.0015) { hit = true; break; }
        t += d * 0.92;
        if (t > 6.0) { break; }
    }
    float alpha = hit ? 1.0 : smoothstep(0.018, 0.0, closest);
    if (alpha <= 0.004) { return half4(0.0h); }
    if (!hit) { t = max(t, 0.001); }

    float3 p = ro + rd * t;
    float3 n = recordNormal(p);
    float3 v = -rd;

    float radius = length(p.xz);
    float3 albedo = float3(0.05, 0.045, 0.055);
    // Grooves, only on the faces — the edge is smooth.
    float faceness = smoothstep(0.55, 0.92, abs(n.y));
    albedo += (0.5 + 0.5 * sin(radius * 210.0)) * 0.045 * faceness;
    // Label, and the run-out groove that separates it from the music.
    if (radius < 0.30) { albedo = mix(float3(0.78, 0.32, 0.22), float3(0.86, 0.45, 0.28),
                                      smoothstep(0.0, 0.30, radius)); }
    if (radius > 0.295 && radius < 0.315) { albedo = float3(0.03); }

    float3 lightDir = normalize(float3(-0.42, 0.78, 0.55));
    float3 col = albedo * (0.22 + 0.95 * saturate(dot(n, lightDir)));

    float3 mirror = reflect(rd, n);
    col += welcomeEnvironment(mirror) * 0.26 * faceness;
    // The long specular sweep across the grooves is what makes vinyl vinyl.
    float3 h = normalize(lightDir + v);
    col += float3(1.0, 0.96, 0.90) * pow(saturate(dot(n, h)), 60.0) * 0.9;

    col = glassTonemap(col, 1.55, 1.15);
    return half4(half3(col) * half(alpha), half(alpha));
}
