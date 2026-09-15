// The launch screen, offscreen — a development tool, nothing here ships.
//
// Both shipping shaders are `#include`d whole rather than copied, so what this
// renders is the launch screen and not a reconstruction of it. That is the
// entire reason `renderRipple` and `renderWordmark` exist as plain functions
// next to their `[[stitchable]]` entry points: SwiftUI's entry points can only
// be called by SwiftUI, and the colorway has to be an argument here where the
// app wants it to be a constant.
//
// The two files share a translation unit here and don't in the app. They have
// no symbols in common — worth knowing before adding a helper to either.

#include <metal_stdlib>
using namespace metal;

#include "PixelRipple.metal"
#include "Wordmark.metal"

struct PreviewArgs {
    /// The screen, in points — the units both shaders think in.
    float2 size;
    /// Cell size, already fitted to the width the way `PixelRippleField` does
    /// it. Fitted on the Swift side so the tool and the app round identically.
    float cell;
    float time;
    /// Pixels per point. Only resampling sharpness: every soft edge in either
    /// shader is measured in points, so the drawing is the same at any scale.
    float scale;
    /// The wordmark's canvas in points — `size × kViewUnits`, which is wider
    /// and taller than the letters because the halo falls off inside it.
    float2 markCanvas;
    float markLift;
    /// Which field colorway, and which of the mark's own surface palettes.
    int way;
    int markWay;
    /// Top-left of the window being rendered, in points. The whole screen for
    /// a phone-sized sheet, a band around the letters for a mark sheet — the
    /// surface of a 46pt cap height is not judgeable at 46pt on a contact
    /// sheet nine cells wide.
    float2 origin;
};

kernel void ripplePreviewKernel(texture2d<float, access::write> out [[texture(0)]],
                                constant PreviewArgs &args [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
    float2 position = args.origin + (float2(gid) + 0.5) / args.scale;

    float3 col = float3(renderRipple(position, args.size, args.cell,
                                     args.time, args.way).rgb);

    // The mark, centred, composited premultiplied — which is what SwiftUI does
    // with the `ZStack` in `LoadingSplashView` and why `renderWordmark`
    // returns premultiplied in the first place.
    float2 markOrigin = (args.size - args.markCanvas) * 0.5;
    float2 p = position - markOrigin;
    if (all(p >= 0.0) && all(p < args.markCanvas)) {
        float2 q = (p / args.markCanvas - 0.5) * kViewUnits;
        q.y = -q.y;                     // SwiftUI is y-down; the mark is y-up.
        half4 mark = renderWordmark(q, args.time, args.markLift,
                                    kViewUnits.x / args.markCanvas.x,
                                    colorwayAt(args.way),
                                    markPaletteAt(args.markWay));
        col = float3(mark.rgb) + col * (1.0 - float(mark.a));
    }

    out.write(float4(col, 1.0), gid);
}
