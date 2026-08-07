import SwiftUI
import simd

/// Draws `AdditStructure` — the dot field behind the app icon — from any angle.
///
/// Same projection the icon's SVG is baked with, reimplemented in Canvas:
/// perspective divide, each dot sized from the distance to its own projected
/// neighbours, painter's-algorithm depth sort. Left at its defaults it is the
/// home-screen icon; rotate it and it reads as that surface tilting.
struct StructureView: View {
    var parameters = AdditStructure.iconParameters
    /// Euler angles in radians, applied X → Y → Z.
    var rotation: SIMD3<Float> = AdditStructure.iconRotation
    var framing: Framing = .bleed
    var color: Color = .white
    /// Floor on dot radius so the far field doesn't dissolve into stipple at
    /// small sizes.
    var minimumRadius: CGFloat = 1

    /// How the surface is mapped onto the view.
    enum Framing {
        /// Fixed scale from the flat plane, so the field runs past every edge.
        /// What the icon uses — no border of the plane is ever visible.
        case bleed
        /// Fit the projected silhouette, leaving `fill` of the smaller side.
        /// For showing the surface as a contained object.
        case fitted(fill: CGFloat)
    }

    var body: some View {
        Canvas { context, size in
            let (model, side) = AdditStructure.surface(parameters)
            guard side > 1 else { return }
            let screen = projectAndFrame(model, into: size)

            // Sizing needs a neighbour's *screen* position, so this can't be
            // folded into the projection pass above.
            var dots: [(depth: Float, rect: CGRect)] = []
            dots.reserveCapacity(screen.count)

            for iy in 0..<side {
                for ix in 0..<side {
                    let i = iy * side + ix
                    let p = screen[i].point
                    // Skip what the view will never show. At icon parameters
                    // the plane is ~1700 points and most fall outside.
                    guard p.x > -80, p.x < size.width + 80,
                          p.y > -80, p.y < size.height + 80 else { continue }

                    var gap = CGFloat.greatestFiniteMagnitude
                    if ix + 1 < side { gap = min(gap, distance(p, screen[i + 1].point)) }
                    if ix > 0 { gap = min(gap, distance(p, screen[i - 1].point)) }
                    if iy + 1 < side { gap = min(gap, distance(p, screen[i + side].point)) }
                    if iy > 0 { gap = min(gap, distance(p, screen[i - side].point)) }
                    guard gap < .greatestFiniteMagnitude else { continue }

                    // Height above the plane, 0 flat to 1 at the peak. Sized
                    // off the model's own Z rather than the projected depth so
                    // the bulge keeps its shape as the surface tilts.
                    let peak = parameters.peakHeight
                    let height = peak > 0.000_001 ? CGFloat(model[i].z) / CGFloat(peak) : 0
                    let sized = parameters.dotRatio * gap
                        * AdditStructure.sizeFactor(forHeight: height, parameters)
                    let r = max(min(sized, parameters.maximumFill * gap), minimumRadius)
                    dots.append((screen[i].depth, CGRect(x: p.x - r, y: p.y - r,
                                                        width: r * 2, height: r * 2)))
                }
            }

            dots.sort { $0.depth < $1.depth }        // far first
            let shading = GraphicsContext.Shading.color(color)
            for dot in dots {
                context.fill(Path(ellipseIn: dot.rect), with: shading)
            }
        }
    }

    // MARK: - Projection

    private struct Projected {
        let point: CGPoint
        let depth: Float
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private func projectAndFrame(_ model: [SIMD3<Float>], into size: CGSize) -> [Projected] {
        let camera = Float(parameters.cameraDistance)
        var raw: [(CGPoint, Float)] = []
        raw.reserveCapacity(model.count)
        for vertex in model {
            let r = rotate(vertex, by: rotation)
            let denominator = camera - r.z
            // Guard the divide: a point at the eye plane would blow up.
            let f = CGFloat(camera / (abs(denominator) < 0.001 ? 0.001 : denominator))
            raw.append((CGPoint(x: CGFloat(r.x) * f, y: CGFloat(-r.y) * f), r.z))
        }

        switch framing {
        case .bleed:
            // Nothing is fitted — the swell is free to push dots off-canvas,
            // which is the point.
            let scale = (min(size.width, size.height) / 2) / CGFloat(parameters.visible)
            return raw.map {
                Projected(point: CGPoint(x: size.width / 2 + $0.0.x * scale,
                                         y: size.height / 2 + $0.0.y * scale),
                          depth: $0.1)
            }

        case .fitted(let fill):
            let xs = raw.map(\.0.x), ys = raw.map(\.0.y)
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max() else { return [] }
            // Fitting *after* projection, not by scaling the model: the
            // silhouette's bounding box changes as the surface turns, and
            // fitting the model instead would make it visibly pulse.
            let target = min(size.width, size.height) * fill
            let scale = target / max(max(maxX - minX, maxY - minY), 0.0001)
            let cx = (maxX + minX) / 2, cy = (maxY + minY) / 2
            return raw.map {
                Projected(point: CGPoint(x: size.width / 2 + ($0.0.x - cx) * scale,
                                         y: size.height / 2 + ($0.0.y - cy) * scale),
                          depth: $0.1)
            }
        }
    }

    private func rotate(_ p: SIMD3<Float>, by r: SIMD3<Float>) -> SIMD3<Float> {
        var (x, y, z) = (p.x, p.y, p.z)
        let (cx, sx) = (cos(r.x), sin(r.x))
        (y, z) = (y * cx - z * sx, y * sx + z * cx)
        let (cy, sy) = (cos(r.y), sin(r.y))
        (x, z) = (x * cy + z * sy, -x * sy + z * cy)
        let (cz, sz) = (cos(r.z), sin(r.z))
        (x, y) = (x * cz - y * sz, x * sz + y * cz)
        return SIMD3<Float>(x, y, z)
    }
}

/// `StructureView` tilting under its own power — the icon's surface caught
/// moving. `TimelineView(.animation)` rather than a repeating `withAnimation`
/// because the motion is continuous and unbounded: there's no keyframe to
/// animate between, just a clock.
struct RotatingStructureView: View {
    var parameters = AdditStructure.iconParameters
    /// Peak tilt in radians about X and Y. A full tumble sends the plane
    /// edge-on twice a cycle, where it collapses to a line — so this rocks
    /// through a shallow arc instead of spinning.
    var amplitude: SIMD2<Float> = .init(0.30, 0.38)
    /// Seconds per cycle on each axis. Deliberately non-commensurate, so the
    /// pair never returns to the same pose and the motion doesn't visibly loop.
    var period: SIMD2<Float> = .init(11, 17)
    var framing: StructureView.Framing = .bleed
    var color: Color = .white

    /// Elapsed time is measured from here rather than from a reference date.
    /// `timeIntervalSinceReferenceDate` is ~7.7e8, and `Float` carries about
    /// seven significant digits — the fractional part would quantise to steps
    /// coarser than a frame and the motion would visibly stutter.
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = Float(timeline.date.timeIntervalSince(start))
            StructureView(
                parameters: parameters,
                rotation: SIMD3<Float>(
                    amplitude.x * sin(2 * .pi * t / period.x),
                    amplitude.y * sin(2 * .pi * t / period.y),
                    0
                ),
                framing: framing,
                color: color
            )
        }
    }
}

#Preview("Icon angle") {
    StructureView()
        .frame(width: 240, height: 240)
        .background(Color(red: 0.055, green: 0.055, blue: 0.059))
}

#Preview("Tilting") {
    RotatingStructureView()
        .frame(width: 240, height: 240)
        .background(Color(red: 0.055, green: 0.055, blue: 0.059))
}

#Preview("Contained object") {
    StructureView(framing: .fitted(fill: 0.9))
        .frame(width: 240, height: 240)
        .background(Color(red: 0.055, green: 0.055, blue: 0.059))
}
