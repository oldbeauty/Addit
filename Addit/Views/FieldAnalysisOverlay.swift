import SwiftUI

/// The launch screen's pattern-recognition layer: boxes, tracks, a graph and
/// the numbers behind all three, drawn over the water.
///
/// Every mark here is a `FieldFrame` — see `FieldAnalysis.swift` for what each
/// number is and how it was measured. This file's only job is to put them on
/// the glass, and its rules are what keep it from reading as decoration:
///
/// - **Everything is in cell units until it is drawn.** The analysis works on
///   the panel's own lattice, so a box lands on dot boundaries and visibly
///   *contains* whole emitters. A box that split dots down the middle would
///   read as a sticker over the picture rather than as a machine reading it.
/// - **Nothing is animated.** No transitions, no easing, no interpolation
///   between ticks. The overlay snaps at 12 Hz over water running at 60, which
///   is what a detector looks like and is the single strongest tell that these
///   are measurements. Smoothing the labels' travel would be the one change
///   that makes the whole thing look staged.
/// - **The colour is off the colorway on purpose.** `Colorways.h` lights the
///   water and the wordmark together so they read as one surface under one
///   light; this layer is the *other* system in the picture — the thing
///   looking at the water — so it takes the app's own display ice
///   (`Phosphor.lit`) and owes the palette nothing. Neon green is the one
///   accent, and it only ever means a state: a track the tracker has locked,
///   and the model it fitted off that lock. Green rather than the amber this
///   was, and it has to be a *lime* green — the water's own ramp climbs
///   through an emerald at `high`, so an accent anywhere near that hue stops
///   reading as the instrument and starts reading as a bright patch of field.
/// - **Text is `Font.readout`** — the display layer's bitmap face, monospaced,
///   so a number that changes doesn't change width and the columns hold still.
///
/// One `Canvas`, so the whole layer is a single drawing pass no matter how
/// many tracks are up. Text is the expensive part of it (each label is a
/// `resolve`), which is the real reason the track budget is nine.
struct FieldAnalysisOverlay: View {
    let frame: FieldFrame
    /// Clearance for the notch and the home indicator. The field itself bleeds
    /// under both — it's water — but a label that runs under the sensor
    /// housing is a label you can't read.
    var safeTop: CGFloat = 0
    var safeBottom: CGFloat = 0

    /// Structure and type: the instrument's own light.
    private static let ink = Phosphor.lit
    /// State only — a locked track, and the model fitted off it.
    private static let lock = Color(red: 0.22, green: 1.0, blue: 0.08)

    private static let hudSize: CGFloat = 9
    private static let labelSize: CGFloat = 8

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            // One tight dark shadow under the entire layer, in a single
            // offscreen pass rather than per mark.
            //
            // Not a style choice — a necessity this screen makes obvious. The
            // field runs from near-black to a blown-out white crest, so an
            // unbacked hairline or a 9pt number is invisible wherever it
            // happens to land on a bright ring, and where it lands is decided
            // by the water. A compositing pipeline putting an overlay over
            // live video does exactly this and for exactly this reason. The
            // alternative — a translucent plate behind each label — buys the
            // same legibility by hiding the thing being analysed.
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.75), radius: 1.5, x: 0, y: 0.5))
                draw(&layer, size: size)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        drawGraticule(&context, size: size)
        drawEdges(&context, canvas: size)
        for track in frame.tracks { drawTrack(&context, track: track, size: size) }
        drawEpicentre(&context, size: size)
    }

    // MARK: Geometry

    /// The band labels are kept inside; geometry ignores it entirely.
    ///
    /// It used to be the gap between the header's readout block and the
    /// footer's, because a name landing on either took the readout with it.
    /// With both blocks gone there is no chrome left to collide with, so what
    /// is left to stay clear of is the hardware: the notch and the home
    /// indicator. Still a clamp on labels *only* — a box or a crosshair goes
    /// where the measurement puts it, including under the notch, because
    /// moving geometry to keep it tidy is the overlay lying about where
    /// something is.
    private var labelBandTop: CGFloat { safeTop + 4 }
    private func labelBandBottom(_ size: CGSize) -> CGFloat { size.height - safeBottom - 4 }

    /// Cells → points. The lattice is the panel's, so this is the only
    /// conversion in the file and everything above it stays in cells.
    private func point(_ cell: SIMD2<Float>) -> CGPoint {
        CGPoint(x: CGFloat(cell.x) * frame.cell, y: CGFloat(cell.y) * frame.cell)
    }

    private func track(_ id: Int) -> FieldTrack? {
        frame.tracks.first { $0.id == id }
    }

    // MARK: Layers

    /// Ruler ticks down the left edge and across the top, every five cells.
    ///
    /// Faint, and not a full grid: the dots already describe the lattice, so a
    /// drawn grid would be a second one slightly out of register with it. What
    /// the ticks add is the sense that the lattice is being *indexed* by
    /// something — a scale on an instrument, not a mesh over a picture.
    private func drawGraticule(_ context: inout GraphicsContext, size: CGSize) {
        var path = Path()
        for col in stride(from: 0, through: frame.cols, by: 5) {
            let x = CGFloat(col) * frame.cell
            let long = col % 10 == 0
            path.move(to: CGPoint(x: x, y: safeTop))
            path.addLine(to: CGPoint(x: x, y: safeTop + (long ? 5 : 2.5)))
        }
        for row in stride(from: 0, through: frame.rows, by: 5) {
            let y = CGFloat(row) * frame.cell
            guard y > safeTop + 12, y < size.height - safeBottom - 12 else { continue }
            let long = row % 10 == 0
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: long ? 5 : 2.5, y: y))
        }
        context.stroke(path, with: .color(Self.ink.opacity(0.22)), lineWidth: 1)
    }

    /// The graph: one line per measured correlation.
    ///
    /// Dashed for a negative r — two crests in antiphase, which is a real
    /// relationship and the wrong thing to throw away — solid for positive.
    /// Opacity carries |r|, so the strength of a coupling is legible before
    /// any number is read, and only the three strongest are labelled: the
    /// numbers are the least legible thing on the screen at this size and
    /// putting one on every edge buys nothing.
    private func drawEdges(_ context: inout GraphicsContext, canvas: CGSize) {
        for (index, edge) in frame.edges.enumerated() {
            guard let a = track(edge.a), let b = track(edge.b) else { continue }
            let from = point(a.position), to = point(b.position)
            var path = Path()
            path.move(to: from)
            path.addLine(to: to)
            let strength = min(1, abs(Double(edge.r)))
            context.stroke(
                path,
                with: .color(Self.ink.opacity(0.18 + 0.42 * strength)),
                style: StrokeStyle(
                    lineWidth: 1,
                    dash: edge.r < 0 ? [2, 3] : []
                )
            )

            guard index < 3 else { continue }
            let midpoint = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
            text(
                &context,
                String(format: "r%+.2f", edge.r),
                at: CGPoint(x: midpoint.x, y: midpoint.y - 2),
                size: Self.labelSize - 1,
                opacity: 0.55,
                anchor: .bottom,
                within: canvas
            )
        }
    }

    /// One track: its box, its name, where it is going, and — once locked —
    /// the axis its own covariance says it lies along.
    private func drawTrack(_ context: inout GraphicsContext, track: FieldTrack, size: CGSize) {
        let locked = track.state == .locked
        let colour = locked ? Self.lock : Self.ink
        let box = track.box.insetBy(dx: -1, dy: -1)

        switch track.state {
        case .acquiring:
            // Provisional, and drawn as such: a dotted box for something that
            // might be noise, so a detection that dies after two ticks never
            // looked like a claim.
            context.stroke(
                Path(box),
                with: .color(colour.opacity(0.45)),
                style: StrokeStyle(lineWidth: 1, dash: [1.5, 2.5])
            )
        case .tracking:
            context.stroke(Path(box), with: .color(colour.opacity(0.75)), lineWidth: 1)
        case .locked:
            // Corner brackets, which is the convention for a confirmed lock
            // and also the more readable mark: the box's sides are what
            // collide with a neighbouring track's, and the corners are what
            // actually communicate an extent.
            let arm = min(box.width, box.height) * 0.28
            var path = Path()
            for corner in [
                (CGPoint(x: box.minX, y: box.minY), CGPoint(x: 1, y: 1)),
                (CGPoint(x: box.maxX, y: box.minY), CGPoint(x: -1, y: 1)),
                (CGPoint(x: box.minX, y: box.maxY), CGPoint(x: 1, y: -1)),
                (CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: -1, y: -1)),
            ] {
                let (origin, direction) = corner
                path.move(to: CGPoint(x: origin.x + direction.x * arm, y: origin.y))
                path.addLine(to: origin)
                path.addLine(to: CGPoint(x: origin.x, y: origin.y + direction.y * arm))
            }
            context.stroke(path, with: .color(colour), lineWidth: 1.2)
        }

        // The label goes above the box, or below it when there is no room up
        // there — the flip a real overlay does to keep a name on screen. Both
        // ends have to be considered, and then the result clamped into the
        // band, so a track riding the top or bottom edge of the panel keeps a
        // readable name instead of one sliced by the hardware.
        let centroid = point(track.position)
        let lineHeight = Self.labelSize + 3
        let fitsAbove = box.minY - 3 - lineHeight >= labelBandTop
        let fitsBelow = box.maxY + 3 + lineHeight <= labelBandBottom(size)
        let above = fitsAbove || !fitsBelow
        let labelTop = min(
            max(above ? box.minY - 3 - lineHeight : box.maxY + 3, labelBandTop),
            labelBandBottom(size) - lineHeight
        )
        text(
            &context,
            String(format: "%@%02d %@ %.2f", track.state == .acquiring ? "?" : "T",
                   track.id, track.kind.rawValue, track.quality),
            at: CGPoint(x: box.minX, y: labelTop),
            size: Self.labelSize,
            opacity: locked ? 1 : 0.78,
            colour: colour,
            anchor: .topLeading,
            within: size
        )

        // Where the filter thinks it is going: the velocity state, drawn as
        // the distance it would cover in a third of a second. Below a floor
        // it isn't drawn at all — a stationary arc with a jittering arrow on
        // it would be the overlay inventing motion.
        if track.speed > 1.5 {
            let lead = point(track.position + track.velocity * 0.33)
            var path = Path()
            path.move(to: centroid)
            path.addLine(to: lead)
            let heading = atan2(lead.y - centroid.y, lead.x - centroid.x)
            for wing in [heading + .pi * 0.82, heading - .pi * 0.82] {
                path.move(to: lead)
                path.addLine(to: CGPoint(
                    x: lead.x + cos(wing) * 4,
                    y: lead.y + sin(wing) * 4
                ))
            }
            context.stroke(path, with: .color(colour.opacity(0.85)), lineWidth: 1)
        }

        // The major axis of the blob's own covariance, at the length its
        // eigenvalue implies. Locked tracks only — on every track it is one
        // more line in a picture that already has enough of them.
        if locked {
            let half = CGFloat((Float(track.area).squareRoot() * 0.5)) * frame.cell
                * CGFloat(min(2.5, max(1, track.elongation))) * 0.5
            let axis = CGFloat(track.axis)
            var path = Path()
            path.move(to: CGPoint(
                x: centroid.x - cos(axis) * half,
                y: centroid.y - sin(axis) * half
            ))
            path.addLine(to: CGPoint(
                x: centroid.x + cos(axis) * half,
                y: centroid.y + sin(axis) * half
            ))
            context.stroke(path, with: .color(colour.opacity(0.5)), lineWidth: 1)
        }
    }

    /// The model: the circle fitted to an arc, and the point it says the drop
    /// landed on.
    ///
    /// Drawn only when the fit passed its gates, so its absence is
    /// information — early in the fill there is no arc long enough to place a
    /// centre, and nothing is drawn rather than the overlay guessing one.
    private func drawEpicentre(_ context: inout GraphicsContext, size: CGSize) {
        guard let epicentre = frame.epicentre else { return }
        let centre = point(epicentre.circle.centre)
        let radius = CGFloat(epicentre.circle.radius) * frame.cell
        // A fit can be legitimate and enormous; there is nothing to show if
        // the circle is three screens wide.
        guard radius < size.width * 3 else { return }

        context.stroke(
            Path(ellipseIn: CGRect(
                x: centre.x - radius, y: centre.y - radius,
                width: radius * 2, height: radius * 2
            )),
            with: .color(Self.lock.opacity(0.42)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 5])
        )

        var crosshair = Path()
        crosshair.move(to: CGPoint(x: centre.x - 7, y: centre.y))
        crosshair.addLine(to: CGPoint(x: centre.x + 7, y: centre.y))
        crosshair.move(to: CGPoint(x: centre.x, y: centre.y - 7))
        crosshair.addLine(to: CGPoint(x: centre.x, y: centre.y + 7))
        context.stroke(crosshair, with: .color(Self.lock.opacity(0.9)), lineWidth: 1)

        // Clamped into the same band the track names are: a fitted centre is
        // often near an edge of the panel — several of the drops land there —
        // and the crosshair belongs at the centre wherever that is, while its
        // name still has to be readable.
        let labelY = min(max(centre.y - 1, labelBandTop + 4), labelBandBottom(size) - 4)
        text(
            &context,
            String(format: "EPI T%02d  R%.1f", epicentre.trackID, epicentre.circle.radius),
            at: CGPoint(x: centre.x + 10, y: labelY),
            size: Self.labelSize,
            opacity: 0.9,
            colour: Self.lock,
            anchor: .leading,
            within: size
        )
    }

    /// Draw one run of type, nudged back on screen if it would hang off an
    /// edge.
    ///
    /// Only the *labels* are moved, and never the geometry they name. A box, a
    /// crosshair or a fitted circle is a measurement and is drawn where the
    /// measurement says, half off the screen if that is where the thing is —
    /// clamping those would be drawing a different number than the one that
    /// was computed. A label is an annotation of a measurement, so pulling it
    /// back into the readable band costs nothing true and is what every real
    /// overlay does. The clamp is what fixed track names on detections at the
    /// screen's left edge being cut off mid-word.
    ///
    /// `bounds` is the full canvas: text is kept inside it horizontally with a
    /// margin, and left alone vertically, since the callers already decide
    /// which side of a box a name goes on.
    private func text(
        _ context: inout GraphicsContext,
        _ string: String,
        at point: CGPoint,
        size: CGFloat,
        opacity: Double,
        colour: Color = FieldAnalysisOverlay.ink,
        anchor: UnitPoint = .topLeading,
        within bounds: CGSize? = nil
    ) {
        let resolved = context.resolve(
            Text(string)
                .font(.readout(size))
                .foregroundStyle(colour.opacity(opacity))
        )

        var origin = point
        if let bounds {
            let measured = resolved.measure(
                in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)
            )
            let margin: CGFloat = 4
            // Where the run's left edge lands, given the anchor it is drawn with.
            let left = point.x - measured.width * anchor.x
            let shifted = min(max(left, margin), bounds.width - measured.width - margin)
            origin.x += shifted - left
        }

        context.draw(resolved, at: origin, anchor: anchor)
    }
}
