#include <metal_stdlib>
#include "RippleSurface.h"

using namespace metal;

// The launch screen's analysis overlay, GPU half: one sample per panel cell,
// handed back to the CPU for detection, tracking and model fitting.
//
// This is the overlay's *camera*, and it is pointed at the panel rather than
// at the water. Every line here mirrors what `PixelRipple.metal` does to
// decide a cell's colour and dot size — the same `surfaceAt` at the same cell
// centre, the same `rampLevel`, the same `quantiseLevel` — so what comes back
// is the value the emitter is actually displaying, palette steps and all, not
// the continuous height underneath it. That distinction is the whole
// conceit: the analysis is reading a screen, so it sees what the screen shows.
// It is also what makes the overlay's boxes land on dot boundaries, which is
// the detail that stops them looking like decals floating over the picture.
//
// Cheap on purpose. One `surfaceAt` per cell is a fraction of what the
// fragment shader already pays twice per pixel, and it runs at
// `FieldInference.rate` rather than per frame, which is what a real detector
// does and is also why nothing here needs to be clever.
//
// Called from `FieldSampler.swift`.

struct FieldSampleArgs {
    /// The panel, in points — the units `PixelRipple.metal` thinks in.
    float2 size;
    /// Cell size, already fitted to the width by `PixelRippleField.fittedCell`.
    /// Passed in rather than derived so the analyser's lattice is the panel's
    /// lattice and not a rounding of it.
    float cell;
    float time;
    /// Which field this launch is showing — see `surfaceAt`. Has to be the
    /// same value `PixelRipple.metal` was handed, or the analysis would be
    /// describing water that isn't on screen; `PixelRippleField` owns the one
    /// copy and gives it to both.
    float seed;
    /// Lattice extent. Columns divide the width exactly; the last row may hang
    /// off the bottom of the panel, exactly as the dots do.
    uint cols;
    uint rows;
};

/// One cell's displayed level, row-major into `out`.
kernel void fieldSampleKernel(device float *out [[buffer(0)]],
                              constant FieldSampleArgs &args [[buffer(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= args.cols || gid.y >= args.rows) { return; }

    // Normalise by width alone so a cell stays square: y runs 0…aspect, not
    // 0…1 — the renderer's convention, and the rings are circles only in it.
    float aspect = args.size.y / args.size.x;
    float2 centre = (float2(gid) + 0.5) * args.cell;
    float2 cellUV = centre / args.size.x;

    float level = quantiseLevel(
        rampLevel(surfaceAt(cellUV, aspect, args.time, args.seed).x)
    );
    out[gid.y * args.cols + gid.x] = level;
}
