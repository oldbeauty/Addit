import CoreGraphics
import simd

/// The Addit mark: a plane of dots that swells toward one corner.
///
/// The magnification isn't drawn — it falls out of the geometry. The plane is
/// displaced in Z under a dome, and perspective projection makes the raised
/// region both larger and more spread out. Extrude and magnify are the same
/// operation here, which is why the mark stays coherent from any angle and can
/// be rotated live (`StructureView`).
///
/// The app icon is this surface projected head-on with `iconParameters`, baked
/// to SVG by `tools/make_app_icon.py`. That script carries its own copy of the
/// constants and of `height(x:y:)` — change anything here and rerun it, or the
/// home-screen icon and everything drawing `StructureView` stop being the same
/// object.
enum AdditStructure {

    /// One circular bulge in the surface.
    struct Dome: Equatable {
        /// Centre in model coordinates. Far enough from the frame edge that
        /// the rim — the circle where the dome meets the plane — stays visible
        /// the whole way round; push it past the corner and the falloff runs
        /// off the edge and it stops reading as a circle.
        var center: SIMD2<Double>
        /// Peak height in model units. Negative pushes the surface *away* from
        /// the camera instead — a pit rather than a crown. Nothing else in the
        /// pipeline special-cases it; see `StructureView`'s size factor.
        var height: Double = 1.0
        /// Radius at which it returns to the flat plane.
        var radius: Double = 0.66
    }

    /// Everything that defines one instance of the surface.
    struct Parameters: Equatable {
        /// Spacing of the undisplaced lattice, in model units.
        var step: Double = 0.088
        /// Half-width of the generated plane. Deliberately larger than
        /// `visible`: the plane's own border has to stay outside the frame, or
        /// the swell drags a visible edge diagonally across the composition.
        var extent: Double = 2.0
        /// One bulge in each corner, alternating: the two on the leading
        /// diagonal push out, the two on the other pull in. Both diagonals
        /// carry a matched pair, so the composition has 180° rotational
        /// symmetry — which is what lets all four sit this close to the edge
        /// without the icon reading as lopsided.
        var domes: [Dome] = [
            Dome(center: .init(0.60, 0.60), height: 1.00),      // top-right, out
            Dome(center: .init(-0.60, -0.60), height: 1.00),    // bottom-left, out
            Dome(center: .init(-0.60, 0.60), height: -1.15),    // top-left, in
            Dome(center: .init(0.60, -0.60), height: -1.15),    // bottom-right, in
        ]
        /// Largest excursion from the plane in either direction — the
        /// reference the dot-size swell is normalised against. Magnitude, not
        /// signed maximum: a surface of nothing but pits still needs a scale.
        var peakHeight: Double { domes.map { abs($0.height) }.max() ?? 1 }
        /// Eye distance from the origin — far back on purpose. Up close,
        /// perspective drags the raised dots outward from the view axis and
        /// stretches the bulge into a comet shape; this keeps a hint of that
        /// lean for dimension without losing the circle.
        var cameraDistance: Double = 8.0
        /// Base dot radius as a fraction of the distance to the nearest
        /// projected neighbour.
        var dotRatio: CGFloat = 0.16
        /// Extra radius at a dome's peak, as a multiple of `dotRatio`. A pit of
        /// the same depth divides radius by the same amount — see
        /// `sizeFactor(forHeight:)`.
        ///
        /// Size, not displacement, is what makes the bulge read. Perspective
        /// magnification alone is physically right and visually wrong: a
        /// magnifier over a lattice shows *fewer, larger* dots, so the raised
        /// area thins out and reads as a hole rather than as something pushing
        /// forward. Modulating radius by height is how the halftone spheres on
        /// the reference sheet do it.
        var swell: CGFloat = 2.8
        /// Hard ceiling on radius as a fraction of the neighbour gap. Without
        /// it the crown merges into a solid blob.
        var maximumFill: CGFloat = 0.46
        /// Half-extent of the plane that maps to half the view's smaller side.
        /// Above 1.0 zooms out, which is what buys margin between the bulges
        /// and the icon's rounded border.
        var visible: Double = 1.30
    }

    static let iconParameters = Parameters()

    /// The camera the icon is drawn from — dead head-on. Rotating away from
    /// this reads as the icon's own surface tilting.
    static let iconRotation = SIMD3<Float>(0, 0, 0)

    /// Summed height of every dome at a point.
    ///
    /// Each dome is a raised cosine: zero slope at both its peak and its rim.
    /// A Gaussian was the first thing tried and it tears — its flanks are
    /// steep enough that projection rarefies them into a visible void in the
    /// middle of the field. This settles back into the plane smoothly, so the
    /// surface swells without ever pulling apart.
    ///
    /// Summing rather than taking the max stays well-defined if two domes are
    /// ever moved close enough to overlap. At the shipped offsets they don't
    /// reach each other, so the sum is only ever one dome or flat plane.
    static func height(x: Double, y: Double, _ p: Parameters = iconParameters) -> Double {
        var total = 0.0
        for dome in p.domes {
            let dx = x - dome.center.x
            let dy = y - dome.center.y
            let d = (dx * dx + dy * dy).squareRoot()
            guard d < dome.radius else { continue }
            total += dome.height * 0.5 * (1 + cos(.pi * d / dome.radius))
        }
        return total
    }

    /// How much bigger or smaller a dot is than its flat-plane size, given its
    /// height normalised against `peakHeight` (+1 crown, -1 pit).
    ///
    /// Crowns multiply and pits divide, so the two are exact inverses. The
    /// obvious `1 + swell * h` can't be used: past `h = -1/swell` it goes
    /// negative, which is meaningless as a radius, and clamping it at zero
    /// flattens the whole floor of a pit into one dead value instead of
    /// keeping the gradient that makes it read as a depression.
    static func sizeFactor(forHeight h: CGFloat, _ p: Parameters = iconParameters) -> CGFloat {
        h >= 0 ? 1 + p.swell * h : 1 / (1 + p.swell * -h)
    }

    /// Memo of the last build.
    ///
    /// `StructureView` asks for the surface from inside its `Canvas` closure,
    /// so a rotating instance rebuilt ~1700 points — a `cos` per dome each —
    /// on every frame, for a lattice that depends on nothing but `Parameters`.
    /// Rotation changes the projection, never the surface. One entry covers it:
    /// in practice every caller wants `iconParameters`.
    ///
    /// Safe as mutable static because the module builds with
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so this and `surface` are
    /// already main-actor isolated. Do not add an explicit `@MainActor` — it is
    /// redundant, and it makes `surface`'s default argument evaluate in a
    /// nonisolated context that can't reach `iconParameters`.
    private static var cached: (key: Parameters, points: [SIMD3<Float>], side: Int)?

    /// The lattice as points, row-major over a `side` × `side` grid so a
    /// point's neighbours are `±1` and `±side` away — `StructureView` needs
    /// that adjacency to size each dot.
    static func surface(_ p: Parameters = iconParameters) -> (points: [SIMD3<Float>], side: Int) {
        if let cached, cached.key == p { return (cached.points, cached.side) }
        let built = buildSurface(p)
        cached = (p, built.points, built.side)
        return built
    }

    private static func buildSurface(_ p: Parameters) -> (points: [SIMD3<Float>], side: Int) {
        let side = Int((2 * p.extent / p.step).rounded()) + 1
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(side * side)
        for iy in 0..<side {
            for ix in 0..<side {
                let x = -p.extent + p.step * Double(ix)
                let y = -p.extent + p.step * Double(iy)
                points.append(SIMD3<Float>(Float(x), Float(y), Float(height(x: x, y: y, p))))
            }
        }
        return (points, side)
    }
}
