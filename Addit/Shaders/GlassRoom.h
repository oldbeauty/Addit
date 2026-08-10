#pragma once

#include <metal_stdlib>
using namespace metal;

// The lighting rig every raymarched glass ornament in the app shares.
//
// Nothing in here knows about shape — it is the *room* and the film, which is
// the part that has to agree between ornaments or the toolbar looks like two
// different apps. Each shader still writes its own `environment`, because the
// colour of the room is that ornament's identity; what it borrows from here is
// how the room is *structured* (strips, not a wash) and how the result is
// rolled off.
//
// Included by PlasmaOrb.metal and GlassLogo.metal. Every function is `inline`
// and shape-agnostic on purpose: no state, no textures, nothing to keep in
// sync at runtime.

/// Rotate `p` by `a` radians.
static inline float2 spin2(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2(p.x * c - p.y * s, p.x * s + p.y * c);
}

/// Softbox strips for direction `d`, in `floorLevel...1`.
///
/// This is the part that makes a mirrored surface legible: a smoothly lit room
/// reflects as an even wash and the eye reads it as flat paint, while strips
/// reflect as the streaks that trace out where the surface is bending.
///
/// `frequency` scales how many strips wrap the sphere of directions. Busy is
/// right for a shape you are meant to just look at and wrong for one you are
/// meant to *recognise* — a mark wants a few broad strips, so its silhouette
/// stays the loudest thing about it.
static inline float softbox(float3 d, float frequency, float floorLevel) {
    float bands = sin((d.y * 4.20 + d.x * 1.10 - d.z * 0.80) * frequency);
    return mix(floorLevel, 1.00, smoothstep(-0.22, 0.60, bands));
}

/// Thin-film sheen over a surface facing the camera by `facing`.
///
/// Keyed low and shallow on purpose: a strong band keyed to the view angle
/// draws contour rings centred on the middle of the object, which reads as a
/// topographic map rather than as glass. `strength` is how much of the band
/// survives — brand-coloured glass wants less of it than a free-for-all blob,
/// since the film shifts hues the mark is not allowed to lose.
static inline float3 iridescence(float facing, float strength) {
    float3 band = 0.5 + 0.5 * cos(6.28318 * (facing * 0.85 + float3(0.00, 0.30, 0.62)));
    return mix(float3(1.0), band, strength);
}

/// Reinhard, then a lift and a saturation push.
///
/// The lights in these rooms overshoot 1.0 by design, and a plain clamp would
/// flatten every one of them to the same white; rolling them off keeps the hot
/// cores while the mid-tones — which is most of the object — stay where the
/// colour actually lives.
static inline float3 glassTonemap(float3 col, float exposure, float saturation) {
    col *= exposure;
    col = col / (1.0 + col);
    col = pow(saturate(col), float3(0.80));
    return saturate(mix(float3(dot(col, float3(0.299, 0.587, 0.114))), col, saturation));
}
