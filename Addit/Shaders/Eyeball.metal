#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
#include "GlassRoom.h"

using namespace metal;

// The tracking button's eyeball, drawn as an anatomical model rather than a
// cartoon: a scleral ball with a separate, bulging cornea over a recessed iris
// that's seen *through* it, refracted — which is why the iris slides against
// the surface as the eye turns, the depth that makes an eye read as real.
// Vessels branch over the sclera, the optic nerve leaves the back, and the
// whole thing is lit by a neutral studio room: colour cast is what makes a
// model read as a toy.
//
// Turned by the library's scroll at the orb's rate (EyeOrnament.swift), via
// `.colorEffect`. Everything is intersected analytically — two spheres and a
// plane — so nothing is marched. Proportions are a real eye's, in units of
// the ball's radius (12 mm): limbus half-angle 29°, cornea radius 7.8 mm.
// `GlassRoom.h` supplies the strips and the tone map, as for every ornament.

// MARK: - Proportions

/// Ball radius on screen, sized to fill its square seen from the camera.
constant float kRadius = 0.97;
constant float kCameraZ = 3.0;
constant float kLens = 0.38;
/// Where the limbus (cornea meets sclera) sits on the ball, unit radius.
constant float kLimbusZ = 0.873;     // cos 29°
/// The cornea: a smaller sphere through the limbus, bulging 0.09 past the ball.
constant float kCorneaR = 0.65;
constant float kCorneaZ = 0.4435;    // its centre on the gaze axis
/// The iris: a flat disc just behind the limbus, under the cornea.
constant float kIrisZ = 0.835;
constant float kIrisR = 0.47;
constant float kPupilR = 0.15;
/// Where the eye looks with no scroll: about 10° to the right.
constant float kRestYaw = 0.17;
constant float kRestPitch = 0.0;

// MARK: - Noise

static float hash3(float3 p) {
    p = fract(p * 0.3183099 + 0.1);
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

static float vnoise(float3 x) {
    float3 i = floor(x), f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(hash3(i + float3(0, 0, 0)), hash3(i + float3(1, 0, 0)), f.x),
                   mix(hash3(i + float3(0, 1, 0)), hash3(i + float3(1, 1, 0)), f.x), f.y),
               mix(mix(hash3(i + float3(0, 0, 1)), hash3(i + float3(1, 0, 1)), f.x),
                   mix(hash3(i + float3(0, 1, 1)), hash3(i + float3(1, 1, 1)), f.x), f.y), f.z);
}

static float fbm(float3 p) {
    float sum = 0.0, amp = 0.5;
    for (int i = 0; i < 4; i++) {
        sum += amp * vnoise(p);
        p = p * 2.03 + 11.7;
        amp *= 0.5;
    }
    return sum;
}

/// A ridge of noise: 1 on the zero line of a signed noise, falling off either
/// side. Raised to a power it becomes a thin line, and over a warped domain
/// those lines branch like vessels.
static inline float ridge(float3 p) {
    return 1.0 - abs(vnoise(p) * 2.0 - 1.0);
}

// MARK: - The room

/// A photographic studio: neutral strips and a hard key, so what colour the
/// eye has is its own.
static float3 studio(float3 d) {
    d = normalize(d);
    float3 col = float3(0.78, 0.81, 0.86) * softbox(d, 1.0, 0.03) * 1.15;
    col += float3(9.0) * pow(saturate(dot(d, normalize(float3(-0.35, 0.88, 0.32)))), 140.0);
    col += float3(1.5, 1.52, 1.6) * pow(saturate(dot(d, normalize(float3(0.62, 0.30, 0.72)))), 40.0);
    return col;
}

// MARK: - Frames

static inline float3 toEye(float3 v, float yaw, float pitch) {
    v.yz = spin2(v.yz, -pitch);
    v.xz = spin2(v.xz, yaw);
    return v;
}

static inline float3 fromEye(float3 v, float yaw, float pitch) {
    v.xz = spin2(v.xz, -yaw);
    v.yz = spin2(v.yz, pitch);
    return v;
}

/// The near hit of a ray on a sphere, or -1.
static inline float hitSphere(float3 ro, float3 rd, float3 centre, float radius) {
    float3 oc = ro - centre;
    float b = dot(oc, rd);
    float h = b * b - (dot(oc, oc) - radius * radius);
    return h < 0.0 ? -1.0 : -b - sqrt(h);
}

// MARK: - Tissues

/// The sclera at `o` (unit, eye frame): white, bluish toward the cornea and
/// warmer behind, veined, with the optic nerve leaving the back.
static float3 sclera(float3 o) {
    float a = acos(clamp(o.z, -1.0, 1.0));
    float3 col = mix(float3(0.90, 0.92, 0.95), float3(0.96, 0.93, 0.89), smoothstep(0.6, 2.2, a));
    col *= 0.97 + 0.06 * fbm(o * 6.0);

    // Vessels run meridionally, in from the periphery toward the cornea, the
    // way conjunctival vessels do: ridges of noise read in coordinates that
    // change fast around the gaze axis and slowly along it, so the lines
    // follow the meridians, meandering by a warp. They're thickest out wide
    // and taper to nothing short of the limbus. (Plain 3D ridges close into
    // loops and read as crazed porcelain.)
    float2 around = o.xy / max(length(o.xy), 1e-3);
    float3 warp = float3(fbm(o * 2.2 + 1.7), fbm(o * 2.2 + 4.1), fbm(o * 2.2 + 8.3)) - 0.5;
    float taper = smoothstep(0.55, 1.7, a);
    float trunk = pow(ridge(float3(around * 5.0, a * 1.1) + warp * 1.6), mix(70.0, 16.0, taper));
    float branch = pow(ridge(float3(around * 13.0, a * 2.6) + warp * 2.8 + 5.0), mix(90.0, 34.0, taper));
    float reach = smoothstep(0.62, 1.15, a) * (1.0 - smoothstep(2.45, 2.75, a));
    float3 vessel = mix(float3(0.86, 0.45, 0.45), float3(0.60, 0.07, 0.09), saturate(trunk * 1.3));
    col = mix(col, vessel, saturate(trunk * 0.85 + branch * 0.45) * reach);

    // The optic nerve, slightly nasal of straight back: the cut sheath, its
    // paler core.
    float n = acos(clamp(dot(o, normalize(float3(0.22, 0.04, -1.0))), -1.0, 1.0));
    float3 nerve = mix(float3(0.94, 0.88, 0.78), float3(0.86, 0.72, 0.66), smoothstep(0.08, 0.20, n));
    col = mix(nerve, col, smoothstep(0.20, 0.24, n));
    return col;
}

/// The iris and pupil at `q` on the iris plane (eye frame), and the sclera
/// seen past the iris's edge under the cornea.
static float3 iris(float3 q, float pupilR) {
    float rho = length(q.xy);
    float2 dir = q.xy / max(rho, 1e-4);
    float r = saturate((rho - pupilR) / (kIrisR - pupilR));

    // Stroma: fibres radiating from the pupil (fast with angle, slow with
    // radius), dark blue under lighter blue-grey.
    float fibres = fbm(float3(dir * 22.0, r * 2.2));
    float strands = vnoise(float3(dir * 58.0, r * 4.0 + 2.0));
    const float3 kDeep = float3(0.06, 0.14, 0.30);
    const float3 kMid = float3(0.20, 0.38, 0.64);
    const float3 kPale = float3(0.56, 0.70, 0.88);
    float3 col = mix(kDeep, kMid, smoothstep(0.30, 0.70, fibres));
    col = mix(col, kPale, 0.65 * smoothstep(0.55, 0.85, strands));

    // The collarette: a wavy ring a third of the way out, inside which the
    // pupillary zone is greyer and finer.
    float wave = 0.33 + 0.08 * (vnoise(float3(dir * 7.0, 3.0)) - 0.5);
    col += kPale * 0.28 * exp(-pow((r - wave) / 0.05, 2.0));
    col = r < wave ? mix(col * 0.85, float3(0.30, 0.38, 0.44), 0.22) : col;

    // Crypts: dark pits in the ciliary zone.
    float crypts = smoothstep(0.58, 0.74, fbm(float3(dir * 9.0, r * 5.0) + 3.1))
                 * smoothstep(0.36, 0.45, r) * (1.0 - smoothstep(0.72, 0.86, r));
    col = mix(col, kDeep * 0.55, 0.65 * crypts);

    // The limbal ring darkening the edge, and the pupillary ruff.
    col *= 1.0 - 0.72 * smoothstep(0.78, 1.0, r);
    col = mix(float3(0.07, 0.045, 0.035), col, smoothstep(0.0, 0.07, r));

    // The pupil: nearly black, the faintest red of the fundus.
    col = mix(float3(0.012, 0.006, 0.006), col, smoothstep(pupilR - 0.006, pupilR + 0.004, rho));
    // Past the iris, the sclera at the limbus. The edge is soft and greyed —
    // a real limbus is a blur, and a hard one reads as a sticker.
    float3 past = sclera(normalize(float3(q.xy, kLimbusZ))) * 0.8;
    float edge = smoothstep(kIrisR - 0.025, kIrisR + 0.03, rho);
    return mix(col, mix(float3(0.28, 0.33, 0.40), past, edge), smoothstep(kIrisR - 0.04, kIrisR, rho));
}

// MARK: - Render

/// The eye at `position` in a `size` square. Plain, beside the stitchable
/// entry point, so a tool can render it off the phone.
static half4 renderEyeball(float2 position, float2 size, float spin, float twist) {
    float2 uv = (position - size * 0.5) / (min(size.x, size.y) * 0.5);
    uv.y = -uv.y;

    float yaw = kRestYaw + spin;
    float pitch = kRestPitch + 0.55 * twist;
    float pupilR = kPupilR + 0.05 * min(abs(twist), 1.0);   // a flick dilates it

    // Everything below is in the eye's frame, in units of the ball's radius.
    float3 ro = toEye(float3(0.0, 0.0, kCameraZ / kRadius), yaw, pitch);
    float3 rd = toEye(normalize(float3(uv * kLens, -1.0)), yaw, pitch);
    float3 corneaC = float3(0.0, 0.0, kCorneaZ);
    float aa = 0.7 * (2.0 * kLens * kCameraZ) / (min(size.x, size.y) * kRadius);

    // Coverage: the ball's silhouette, and the cornea's where it stands proud
    // of it (in profile). A grazing miss gets partial coverage — the
    // antialiasing, as in the orb.
    float3 nearBall = ro - rd * dot(ro, rd);
    float coverBall = 1.0 - smoothstep(1.0 - aa, 1.0, length(nearBall));
    float3 nearCornea = ro + rd * dot(corneaC - ro, rd);
    float coverCornea = nearCornea.z > kLimbusZ
        ? 1.0 - smoothstep(kCorneaR - aa, kCorneaR, length(nearCornea - corneaC)) : 0.0;
    float alpha = max(coverBall, coverCornea);
    if (alpha <= 0.002) { return half4(0.0h); }

    // The surface: ball behind the limbus, cornea in front of it, whichever
    // the ray meets first; or, for a grazing miss, the nearest silhouette.
    float tBall = hitSphere(ro, rd, float3(0.0), 1.0);
    float tCornea = hitSphere(ro, rd, corneaC, kCorneaR);
    bool ball = tBall > 0.0 && (ro + rd * tBall).z < kLimbusZ;
    bool cornea = tCornea > 0.0 && (ro + rd * tCornea).z >= kLimbusZ;
    if (ball && cornea) { ball = tBall < tCornea; cornea = !ball; }
    float3 p, n;
    if (cornea || (!ball && coverCornea > coverBall)) {
        p = cornea ? ro + rd * tCornea : corneaC + normalize(nearCornea - corneaC) * kCorneaR;
        cornea = true;
        n = normalize(p - corneaC);
    } else {
        p = ball ? ro + rd * tBall : normalize(nearBall);
        n = normalize(p);
    }

    float3 key = toEye(normalize(float3(-0.35, 0.88, 0.32)), yaw, pitch);
    float3 fill = toEye(normalize(float3(0.62, 0.30, 0.72)), yaw, pitch);
    float3 mirror = reflect(rd, n);
    float facing = saturate(dot(n, -rd));
    // Water and cornea both reflect about 2.5% head on.
    float fresnel = mix(0.025, 1.0, pow(1.0 - facing, 5.0));
    float3 reflected = studio(fromEye(mirror, yaw, pitch));

    float3 col;
    if (cornea) {
        // Through the cornea to the iris, bent once on the way in.
        float3 bent = refract(rd, n, 1.0 / 1.376);
        float t = (kIrisZ - p.z) / min(bent.z, -1e-3);
        float3 q = p + bent * t;
        float3 albedo = iris(q, pupilR);
        // The iris faces down the gaze; lit through the cornea, softly.
        float lit = 0.45 + 0.85 * saturate(key.z * 0.6 + 0.4) + 0.25 * saturate(fill.z);
        col = albedo * lit * 1.9;
        col = mix(col, reflected, fresnel);
    } else {
        float lit = 0.42 + 0.80 * saturate(dot(n, key) * 0.6 + 0.4) + 0.25 * saturate(dot(n, fill));
        col = sclera(p) * lit * 1.9;
        col = mix(col, reflected, fresnel * 0.8);
    }

    // Specular on a wet surface: the catchlight is what makes it alive. The
    // cornea's is the sharpest thing in the picture.
    float sharp = cornea ? 700.0 : 260.0;
    col += float3(cornea ? 3.4 : 1.4) * pow(saturate(dot(mirror, key)), sharp);
    col += float3(1.1, 1.12, 1.2) * pow(saturate(dot(mirror, fill)), cornea ? 160.0 : 70.0);

    col = glassTonemap(col, 1.0, 1.05);
    return half4(half3(col) * half(alpha), half(alpha));
}

[[ stitchable ]] half4 eyeball(float2 position,
                               half4 currentColor,
                               float2 size,
                               float spin,
                               float twist) {
    return renderEyeball(position, size, spin, twist);
}
