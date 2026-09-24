import CoreGraphics
import Foundation
import simd

// The launch screen's pattern-recognition overlay, CPU half: what the numbers
// on the splash actually are.
//
// The claim this file has to earn is that none of it is staged. Every box,
// line, label and number on that screen is computed from the panel's own cell
// values, sampled off the GPU by `FieldAnalysis.metal` — the same values the
// dots are drawn from. Nothing is keyframed, nothing is a sine wave dressed as
// a measurement, and nothing knows what the water is going to do next. The
// pipeline is the ordinary one a real detector-tracker is built from:
//
//   1. **Adaptive threshold.** A z-score cut, `mean + k·σ`, floored so the
//      field's slow swell can't trip it (`FieldInference.levelFloor`).
//   2. **Connected components**, 8-connectivity, over the cells above that
//      cut. One component is one detection.
//   3. **Moments.** Area, energy-weighted centroid, bounding box, and the 2×2
//      covariance, whose eigenvectors give each detection an orientation and
//      an elongation. A two-split decision stump on (elongation, area) is what
//      prints as the class label.
//   4. **Association and filtering.** Greedy nearest-neighbour matching inside
//      a gate, then a constant-velocity alpha-beta filter per track. Tracks
//      keep their identity across frames, coast when unmatched, and die after
//      `maxMisses` — which is why an ID stays with an arc as it crosses the
//      screen instead of being renumbered every tick.
//   5. **Coupling.** Pearson correlation between each pair of tracks' level
//      histories. That is the graph: two tracks riding the same wavefront
//      genuinely rise and fall together, so a strong edge is real structure in
//      the water and not a line drawn between whatever happens to be near.
//   6. **Model fit.** An algebraic (Kåsa) circle fit to a detection's own
//      cells. The wavefronts *are* circles, so a good fit recovers the point
//      the drop landed — and differentiating the fitted radius measures the
//      propagation speed, which lands on `kWaveSpeed` in `RippleSurface.h`.
//      That last number is the honest self-check: the overlay is reading the
//      generative constant back off the screen, having never been told it.
//
// Every threshold in here was picked off a measured distribution rather than
// by eye; the ones worth knowing carry their numbers. All of it works in
// **cell units** — the panel's own lattice — and only `FieldAnalysisOverlay`
// converts to points, so a box can't land between dots.
//
// Pure value types with no SwiftUI and no Metal: the stages are separable and
// each one is a function you can hand an array to. `FieldSampler` supplies the
// grid; `FieldAnalysisOverlay` draws the result.

// MARK: - Tuning

/// The analysis' own constants, kept together because most of them were
/// measured and the numbers are the argument for them.
enum FieldInference {
    /// Inference rate, in hertz — deliberately unhooked from the display.
    ///
    /// The field renders at 60; the labels snap at 12, and that mismatch is
    /// the effect rather than a compromise. A detector runs its model at
    /// whatever rate it can afford and its overlay visibly lags the picture;
    /// an overlay that moved perfectly with the water would read as part of
    /// the artwork. No easing anywhere in this file or the one that draws it,
    /// for the same reason.
    static let rate: Double = 12
    static var interval: Double { 1 / rate }

    /// Steps in the field's palette — `kPaletteSteps` in `RippleSurface.h`.
    ///
    /// Duplicated here because Swift can't read a Metal constant, and it is
    /// load-bearing twice over: the level histogram has exactly this many bins
    /// (the levels are quantised to these steps, so any other count would
    /// alias one bar against two palette entries), and it is how many ramp
    /// colours are read back to paint them.
    static let paletteSteps = 26

    /// Cut, as a z-score above the frame's own mean.
    static let sigmaGain: Float = 1.25
    /// Floor under that cut, below which nothing is a detection.
    ///
    /// Measured, and load-bearing: undisturbed water sits at level 0.32 and
    /// the slow swell takes it to 0.44 at its highest, so a floor at 0.52
    /// means the swell can never register while a real crest (0.6…1.0)
    /// always does. Without it, the z-score alone finds "structure" in the
    /// swell on the empty field before the first drop has landed.
    static let levelFloor: Float = 0.52

    /// Smallest component that counts as a detection, in cells. Below this the
    /// grid is finding single-cell speckle on the shoulder of a ripple.
    static let minArea = 5
    /// Track budget. Real trackers have one; the overlay needs one anyway,
    /// since the field carries 2 detections at 0.15s and 16 by 1.5s and a
    /// screen with sixteen labelled boxes on it is unreadable.
    static let maxTracks = 9

    /// Association gate, in cells — how far a track may have moved between
    /// ticks and still be the same thing.
    static let gate: Float = 7
    /// Ticks a track may go unmatched before it is dropped.
    static let maxMisses = 3
    /// Ticks before a track stops being provisional, and the quality it also
    /// has to reach to read as locked.
    static let confirmHits = 3
    static let lockHits = 8
    static let lockQuality: Float = 0.62

    /// Alpha-beta filter gains: position, then velocity.
    ///
    /// Low-ish on purpose. The measurement is a centroid of a thresholded
    /// blob, which jitters by a cell or two as the threshold clips its edges,
    /// and a high gain turns that into visible box chatter.
    static let alpha: Float = 0.50
    static let beta: Float = 0.10

    /// Level samples kept per track, and the fewest a correlation may use.
    /// 24 ticks is two seconds at `rate` — about the length of the whole fill.
    static let historyLength = 24
    static let minCorrelationSamples = 8
    /// |r| an edge has to clear, and how many edges any one node may own.
    static let edgeThreshold: Float = 0.55
    static let edgesPerNode = 2
    static let maxEdges = 10

    /// How close two circle fits' centres have to be to be the same drop, in
    /// cells. Tight, because the centre is the part the fit gets *right*:
    /// checked against the true origins it lands within 0.1–0.6 cells, so
    /// 2.5 admits every fit of one drop and no fit of another.
    static let centreGate: Float = 2.5
    /// Ticks a model hypothesis survives without a fit supporting it.
    static let modelMaxAge = 6
    /// Fits on one crest before its expansion is worth a speed.
    static let minSpeedSamples = 3

    /// Radial profile used to measure the ripple wavelength: samples per ray,
    /// at one-cell steps, and how many rays out of the epicentre.
    ///
    /// 20 cells covers about four wavelengths, which is what a transform needs
    /// to place a peak, and keeps enough rays wholly on screen to average
    /// when the epicentre is near an edge — which it often is.
    static let radialSamples = 20
    static let radialRays = 12

    /// Gates on the circle fit, both measured against the true drop origins.
    ///
    /// A fit whose RMS residual is under 0.7 cells recovered the real
    /// epicentre to within 0.1–0.6 cells every time it was checked; the ones
    /// that failed (off by 5–11 cells) all had residuals above 0.9, so the
    /// residual separates them cleanly. The span gate is the other half: a
    /// short arc is consistent with a huge circle almost anywhere, and it is
    /// the arcs under ~1.6 radians that produced the near-misses.
    static let maxFitResidual: Float = 0.7
    static let minFitSpan: Float = 1.6
    static let minFitArea = 12
}

// MARK: - Input

/// One frame of the panel, as the analyser sees it: the displayed level of
/// every cell, row-major.
struct FieldGrid {
    var levels: [Float]
    var cols: Int
    var rows: Int
    /// Cell size in points — the only thing here that knows about the screen,
    /// and used solely to put the overlay back on top of the dots.
    var cell: CGFloat

    func level(_ col: Int, _ row: Int) -> Float { levels[row * cols + col] }
}

// MARK: - Global statistics

/// What the frame looks like as a distribution, rather than as a picture.
struct FieldStats {
    var mean: Float
    var sigma: Float
    /// The cut this frame ended up using.
    var threshold: Float
    /// Shannon entropy of the level histogram, in bits. Runs from ~0 on a flat
    /// field to log2(26) ≈ 4.7 if every palette step were equally occupied —
    /// so it reads as how much the panel is *saying*, and it climbs as the
    /// field fills.
    var entropy: Float
    /// Occupancy per palette step — `FieldInference.paletteSteps` of them,
    /// for the reason given there.
    var histogram: [Int]
    static func measure(_ grid: FieldGrid) -> FieldStats {
        let levels = grid.levels
        let n = Float(levels.count)
        var sum: Float = 0
        var sumSq: Float = 0
        let bins = FieldInference.paletteSteps
        var histogram = [Int](repeating: 0, count: bins)
        for level in levels {
            sum += level
            sumSq += level * level
            let bin = min(bins - 1, max(0, Int((level * Float(bins - 1)).rounded())))
            histogram[bin] += 1
        }
        let mean = sum / n
        let sigma = max(0, sumSq / n - mean * mean).squareRoot()

        var entropy: Float = 0
        for count in histogram where count > 0 {
            let p = Float(count) / n
            entropy -= p * log2(p)
        }

        return FieldStats(
            mean: mean,
            sigma: sigma,
            threshold: max(FieldInference.levelFloor, mean + FieldInference.sigmaGain * sigma),
            entropy: entropy,
            histogram: histogram
        )
    }

}

// MARK: - Detection

/// What a detection is called, from a two-split decision stump on its own
/// measured shape. Three names because the field genuinely makes three things:
/// long thin arcs of a wavefront, the broad bright body of a crest, and the
/// small hot spot of a fresh impact.
enum FieldClass: String {
    case arc = "ARC"
    case crest = "CRST"
    case peak = "PEAK"

    /// Elongation first, because it is the feature that separates a ring
    /// segment from everything else; area second, to tell a crest's body from
    /// a speck. Both thresholds sit where the measured distributions part.
    static func classify(elongation: Float, area: Int) -> FieldClass {
        if elongation >= 2.4 { return .arc }
        return area >= 24 ? .crest : .peak
    }
}

/// One connected component, with its moments.
struct FieldBlob {
    /// Energy-weighted centroid, in cells.
    var centroid: SIMD2<Float>
    /// Bounding box, in cells — integral, so the overlay's box lands on dot
    /// boundaries.
    var box: (minCol: Int, minRow: Int, maxCol: Int, maxRow: Int)
    var area: Int
    /// Summed excess over the threshold: how much signal, not how many cells.
    var energy: Float
    var peak: Float
    /// Orientation of the major axis, radians, from the covariance's
    /// eigenvectors.
    var axis: Float
    /// √(λmax/λmin) — 1 is a disc, large is a line.
    var elongation: Float
    var kind: FieldClass
    /// The component's own cells, kept for the circle fit.
    var cells: [SIMD2<Float>]
    var weights: [Float]
}

enum FieldDetector {
    /// Threshold, label, and measure. 8-connectivity throughout.
    ///
    /// No morphological closing before labelling, which was tried and is
    /// wrong: a 3×3 close bridges arcs belonging to *different* drops, and at
    /// 1.5s into the fill it merged six components into one 245-cell blob
    /// spanning half the screen. Keeping the fragments apart is the whole
    /// basis of the tracker and of the circle fit — a blob has to belong to
    /// one ring for its centre to mean anything.
    static func detect(_ grid: FieldGrid, threshold: Float) -> [FieldBlob] {
        var visited = [Bool](repeating: false, count: grid.levels.count)
        var blobs: [FieldBlob] = []
        var stack: [Int] = []

        for seed in 0..<grid.levels.count where !visited[seed] && grid.levels[seed] >= threshold {
            visited[seed] = true
            stack.removeAll(keepingCapacity: true)
            stack.append(seed)

            var cells: [SIMD2<Float>] = []
            var weights: [Float] = []
            var energy: Float = 0
            var peak: Float = 0
            var moment = SIMD2<Float>(repeating: 0)
            var minCol = grid.cols, maxCol = 0, minRow = grid.rows, maxRow = 0

            while let index = stack.popLast() {
                let col = index % grid.cols
                let row = index / grid.cols
                let level = grid.levels[index]
                let weight = level - threshold

                cells.append(SIMD2(Float(col) + 0.5, Float(row) + 0.5))
                weights.append(weight)
                energy += weight
                peak = max(peak, level)
                moment += SIMD2(Float(col) + 0.5, Float(row) + 0.5) * weight
                minCol = min(minCol, col); maxCol = max(maxCol, col)
                minRow = min(minRow, row); maxRow = max(maxRow, row)

                for dRow in -1...1 {
                    for dCol in -1...1 where !(dRow == 0 && dCol == 0) {
                        let nCol = col + dCol, nRow = row + dRow
                        guard nCol >= 0, nCol < grid.cols, nRow >= 0, nRow < grid.rows else { continue }
                        let neighbour = nRow * grid.cols + nCol
                        guard !visited[neighbour], grid.levels[neighbour] >= threshold else { continue }
                        visited[neighbour] = true
                        stack.append(neighbour)
                    }
                }
            }

            guard cells.count >= FieldInference.minArea, energy > 0 else { continue }

            let centroid = moment / energy
            let (axis, elongation) = principalAxis(cells: cells, weights: weights,
                                                   energy: energy, centroid: centroid)
            blobs.append(FieldBlob(
                centroid: centroid,
                box: (minCol, minRow, maxCol, maxRow),
                area: cells.count,
                energy: energy,
                peak: peak,
                axis: axis,
                elongation: elongation,
                kind: FieldClass.classify(elongation: elongation, area: cells.count),
                cells: cells,
                weights: weights
            ))
        }

        return blobs.sorted { $0.energy > $1.energy }
    }

    /// Eigen-decomposition of the weighted 2×2 covariance, closed form.
    ///
    /// Closed form because it is 2×2 — the characteristic polynomial is a
    /// quadratic, so there is nothing to iterate. The half-angle form of the
    /// eigenvector direction (`½·atan2(2σxy, σxx−σyy)`) is used rather than
    /// solving for the vector, since it stays well-behaved when the blob is
    /// round and the axis is genuinely undefined.
    private static func principalAxis(
        cells: [SIMD2<Float>],
        weights: [Float],
        energy: Float,
        centroid: SIMD2<Float>
    ) -> (axis: Float, elongation: Float) {
        var sxx: Float = 0, syy: Float = 0, sxy: Float = 0
        for (index, cell) in cells.enumerated() {
            let d = cell - centroid
            let w = weights[index]
            sxx += w * d.x * d.x
            syy += w * d.y * d.y
            sxy += w * d.x * d.y
        }
        sxx /= energy; syy /= energy; sxy /= energy

        let trace = sxx + syy
        let determinant = sxx * syy - sxy * sxy
        let root = max(0, trace * trace / 4 - determinant).squareRoot()
        let major = trace / 2 + root
        let minor = trace / 2 - root
        let axis = 0.5 * atan2(2 * sxy, sxx - syy)
        // A single-cell-wide blob has a zero minor axis; floor it at the
        // quantisation of the lattice itself rather than at an epsilon, so
        // elongation stays a ratio of real extents.
        let elongation = (major / max(minor, 0.08)).squareRoot()
        return (axis, elongation)
    }
}

// MARK: - Model fitting

/// A circle recovered from an arc, and what it implies.
struct FieldCircle {
    /// Centre in cells — the estimated point the drop landed.
    var centre: SIMD2<Float>
    var radius: Float
    /// RMS distance from the fitted circle, in cells.
    var residual: Float
    /// Angular extent of the arc the fit was made from, radians.
    var span: Float
}

enum FieldModel {
    /// Algebraic (Kåsa) circle fit, weighted by cell energy.
    ///
    /// Rewriting `(x−a)² + (y−b)² = R²` as `x² + y² = 2ax + 2by + c` makes the
    /// unknowns linear, so this is one 3×3 normal-equation solve and no
    /// iteration — which is why it can run on every detection every tick. The
    /// price is the one this method is known for: it is biased toward large
    /// circles when the arc is short, which is exactly what
    /// `FieldInference.minFitSpan` is there to refuse.
    static func fitCircle(cells: [SIMD2<Float>], weights: [Float]) -> FieldCircle? {
        guard cells.count >= 3 else { return nil }

        var sw: Float = 0, sx: Float = 0, sy: Float = 0
        var sxx: Float = 0, syy: Float = 0, sxy: Float = 0
        var sz: Float = 0, sxz: Float = 0, syz: Float = 0
        for (index, cell) in cells.enumerated() {
            let w = weights[index], x = cell.x, y = cell.y
            let z = x * x + y * y
            sw += w; sx += w * x; sy += w * y
            sxx += w * x * x; syy += w * y * y; sxy += w * x * y
            sz += w * z; sxz += w * x * z; syz += w * y * z
        }

        let m = simd_float3x3(rows: [
            SIMD3(sxx, sxy, sx),
            SIMD3(sxy, syy, sy),
            SIMD3(sx, sy, sw),
        ])
        let determinant = m.determinant
        guard abs(determinant) > 1e-6 else { return nil }
        let solution = m.inverse * SIMD3(sxz, syz, sz)

        let centre = SIMD2(solution.x / 2, solution.y / 2)
        let radiusSquared = solution.z + centre.x * centre.x + centre.y * centre.y
        guard radiusSquared > 0 else { return nil }
        let radius = radiusSquared.squareRoot()

        var squaredError: Float = 0
        var angles: [Float] = []
        angles.reserveCapacity(cells.count)
        for cell in cells {
            let d = cell - centre
            let error = simd_length(d) - radius
            squaredError += error * error
            angles.append(atan2(d.y, d.x))
        }

        return FieldCircle(
            centre: centre,
            radius: radius,
            residual: (squaredError / Float(cells.count)).squareRoot(),
            span: angularSpan(angles)
        )
    }

    /// How much of the circle the arc actually covers.
    ///
    /// A full turn minus the largest gap between neighbouring angles, which is
    /// the wrap-safe way to do it: taking `max − min` would call an arc
    /// straddling ±π a full circle, and that arc is the one most in need of
    /// being refused.
    private static func angularSpan(_ angles: [Float]) -> Float {
        guard angles.count > 1 else { return 0 }
        let sorted = angles.sorted()
        var largestGap = sorted[0] + 2 * .pi - sorted[sorted.count - 1]
        for index in 1..<sorted.count {
            largestGap = max(largestGap, sorted[index] - sorted[index - 1])
        }
        return max(0, 2 * .pi - largestGap)
    }
}

// MARK: - Tracks

enum FieldTrackState: String {
    /// Seen, not yet confirmed — a detection that might be noise.
    case acquiring = "ACQ"
    case tracking = "TRK"
    case locked = "LOCK"
}

/// One thing the analyser believes is out there, across frames.
struct FieldTrack: Identifiable {
    let id: Int
    /// Filtered position and velocity, in cells and cells per second.
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    /// Last box, carried along by the filter while the track is coasting so it
    /// stays on the thing it is tracking rather than sitting where it was
    /// last seen.
    var box: CGRect
    var area: Int
    var peak: Float
    var axis: Float
    var elongation: Float
    var kind: FieldClass
    var hits: Int
    var misses: Int
    /// A heuristic score in 0…1, not a probability: how consistently this
    /// track has been matched, weighted by how far above the cut it sits.
    var quality: Float
    /// Level history, oldest first — what the correlation is computed over.
    var history: [Float]

    var state: FieldTrackState {
        if hits >= FieldInference.lockHits && quality >= FieldInference.lockQuality { return .locked }
        return hits >= FieldInference.confirmHits ? .tracking : .acquiring
    }

    var speed: Float { simd_length(velocity) }
}

/// A measured coupling between two tracks.
struct FieldEdge: Identifiable {
    var a: Int
    var b: Int
    /// Pearson correlation of the two level histories over their overlap.
    /// Signed: a negative edge is two crests in antiphase, which happens where
    /// rings cross, and it is drawn dashed rather than thrown away.
    var r: Float
    var samples: Int

    var id: Int { a << 16 | b }
}

/// The published model: a circle fit that passed its gates, tracked across
/// ticks, plus the two constants measured from it.
///
/// Both of those measurements are the overlay's whole claim to not being
/// decoration — they are the numbers that generated the water, read back off
/// the screen by something that was never told them. See
/// `FieldAnalyzer.fitModel` for how, and `tools/fieldprobe` for how close they
/// land.
struct FieldEpicentre {
    var circle: FieldCircle
    /// Source track, so the label can name what the model came from.
    var trackID: Int
    /// Observations of the watched crest that the speed is regressed over —
    /// so it reads as how much the speed estimate rests on, and drops back to
    /// a couple whenever the crest is re-acquired.
    var samples: Int
    /// Propagation speed in screen widths per second, from a least-squares
    /// regression of one crest's radius against time. `nil` until
    /// `FieldInference.minSpeedSamples` observations of that crest.
    ///
    /// Compare `kWaveSpeed` in `RippleSurface.h`: 0.42.
    var speed: Float?
    /// Ripple frequency in cycles per screen width, from the averaged radial
    /// periodogram about this centre. `nil` when too few rays out of the
    /// epicentre stay on screen to average.
    ///
    /// Compare `kWaveNumber` in `RippleSurface.h`: 46 radians per width, which
    /// is 46/2π = 7.32 cycles.
    var cycles: Float?
}

// MARK: - The frame

/// One tick's output — everything the overlay draws, and nothing else.
struct FieldFrame {
    var cols: Int
    var rows: Int
    var cell: CGFloat
    /// Field time this frame was sampled at, seconds since the launch began.
    var time: Double
    var tick: Int
    /// Wall-clock cost of this tick — sample, read back and analyse. Printed
    /// on the overlay because it is the one number there that is about the
    /// analyser rather than the water.
    var latency: Double
    var stats: FieldStats
    var detections: Int
    var tracks: [FieldTrack]
    var edges: [FieldEdge]
    var epicentre: FieldEpicentre?
}

// MARK: - The pipeline

/// Holds what has to survive between ticks: the tracks, their IDs, and the
/// last accepted model fit.
///
/// A `struct` with a `mutating` step rather than an observable object — the
/// state is small, the stages are pure, and the thing that owns it
/// (`FieldAnalysisRunner`) is what SwiftUI watches.
struct FieldAnalyzer {
    private var tracks: [FieldTrack] = []
    private var nextID = 1
    private var tick = 0
    private var lastTime: Double?
    /// Standing epicentre hypotheses — see `ModelHypothesis`.
    private var hypotheses: [ModelHypothesis] = []
    /// Last successful radial wavelength measurement, kept because it is what
    /// sizes the crest-association gate on subsequent ticks.
    private var measuredCycles: Float?

    mutating func ingest(_ grid: FieldGrid, time: Double, latency: Double) -> FieldFrame {
        let stats = FieldStats.measure(grid)
        let blobs = FieldDetector.detect(grid, threshold: stats.threshold)
        // First tick has no interval to filter over; treat it as one nominal
        // step rather than dividing by zero in the velocity update.
        let dt = Float(max(0.001, time - (lastTime ?? time - FieldInference.interval)))
        lastTime = time
        tick += 1

        let matches = associate(blobs: blobs, dt: dt)
        // `update` hands back the association re-keyed by *track ID*, and
        // everything downstream uses that. Passing `matches` on instead was a
        // crash: its keys are indices into `tracks`, `update` drops dead
        // tracks out of that array, and by the time the model fit subscripted
        // it the indices could be off the end — or, no better, name a
        // different track than the one that was matched. Indices are only
        // valid either side of a mutation if nothing was removed, and
        // something is removed here whenever a track ages out.
        let matched = update(
            blobs: blobs, matches: matches, threshold: stats.threshold,
            dt: dt, cell: grid.cell
        )
        let edges = correlate()
        let epicentre = fitModel(grid: grid, blobs: blobs, matched: matched, time: time)

        return FieldFrame(
            cols: grid.cols,
            rows: grid.rows,
            cell: grid.cell,
            time: time,
            tick: tick,
            latency: latency,
            stats: stats,
            detections: blobs.count,
            tracks: tracks,
            edges: edges,
            epicentre: epicentre
        )
    }

    // MARK: Association

    /// Greedy nearest-neighbour matching against each track's *predicted*
    /// position, returning blob index per track index.
    ///
    /// Greedy rather than optimal (Hungarian/JV), and worth being straight
    /// about: with a hard gate and at most nine tracks, the two disagree
    /// rarely, and when they do it costs one tick's mismatch that the filter
    /// absorbs. Sorting every candidate pair by distance and taking them in
    /// order is what makes it behave — matching in track order instead lets
    /// the first track claim a detection that was a much better fit for the
    /// second.
    private func associate(blobs: [FieldBlob], dt: Float) -> [Int: Int] {
        guard !tracks.isEmpty, !blobs.isEmpty else { return [:] }

        var candidates: [(distance: Float, track: Int, blob: Int)] = []
        for (trackIndex, track) in tracks.enumerated() {
            let predicted = track.position + track.velocity * dt
            for (blobIndex, blob) in blobs.enumerated() {
                let distance = simd_distance(predicted, blob.centroid)
                guard distance <= FieldInference.gate else { continue }
                candidates.append((distance, trackIndex, blobIndex))
            }
        }
        candidates.sort { $0.distance < $1.distance }

        var matches: [Int: Int] = [:]
        var claimedBlobs = Set<Int>()
        for candidate in candidates {
            guard matches[candidate.track] == nil, !claimedBlobs.contains(candidate.blob) else { continue }
            matches[candidate.track] = candidate.blob
            claimedBlobs.insert(candidate.blob)
        }
        return matches
    }

    // MARK: Filtering

    /// Returns blob index → the **ID** of the track that claimed it, for the
    /// stages that run after this one. IDs rather than indices because this
    /// function removes elements from `tracks`, which invalidates every index
    /// into it past the first removal.
    @discardableResult
    private mutating func update(
        blobs: [FieldBlob],
        matches: [Int: Int],
        threshold: Float,
        dt: Float,
        cell: CGFloat
    ) -> [Int: Int] {
        var matched: [Int: Int] = [:]
        for index in tracks.indices {
            let predicted = tracks[index].position + tracks[index].velocity * dt

            guard let blobIndex = matches[index] else {
                // Coasting: run the prediction forward, carry the box with it,
                // and let the quality decay so a track that has lost its
                // detection stops claiming to be locked.
                let drift = predicted - tracks[index].position
                tracks[index].position = predicted
                tracks[index].box.origin.x += CGFloat(drift.x) * cell
                tracks[index].box.origin.y += CGFloat(drift.y) * cell
                tracks[index].misses += 1
                tracks[index].quality *= 0.75
                appendHistory(&tracks[index], level: tracks[index].peak * 0.9)
                continue
            }

            let blob = blobs[blobIndex]
            // Constant-velocity alpha-beta filter. One residual drives both
            // states: position takes `alpha` of it, velocity takes `beta` of
            // it per unit time.
            let residual = blob.centroid - predicted
            tracks[index].position = predicted + FieldInference.alpha * residual
            tracks[index].velocity += (FieldInference.beta / dt) * residual
            tracks[index].box = boxRect(blob.box, cell: cell)
            tracks[index].area = blob.area
            tracks[index].peak = blob.peak
            tracks[index].axis = blob.axis
            tracks[index].elongation = blob.elongation
            tracks[index].kind = blob.kind
            tracks[index].hits += 1
            tracks[index].misses = 0
            tracks[index].quality = quality(
                of: tracks[index], peak: blob.peak, threshold: threshold
            )
            appendHistory(&tracks[index], level: blob.peak)
            // Recorded here, where the index is still meaningful.
            matched[blobIndex] = tracks[index].id
        }

        tracks.removeAll { $0.misses > FieldInference.maxMisses }

        // Unclaimed detections become new tracks, strongest first, up to the
        // budget. A new track starts with zero velocity rather than a guess:
        // one observation says where something is and nothing about where it
        // is going.
        let claimed = Set(matches.values)
        for (blobIndex, blob) in blobs.enumerated() where !claimed.contains(blobIndex) {
            guard tracks.count < FieldInference.maxTracks else { break }
            tracks.append(FieldTrack(
                id: nextID,
                position: blob.centroid,
                velocity: .zero,
                box: boxRect(blob.box, cell: cell),
                area: blob.area,
                peak: blob.peak,
                axis: blob.axis,
                elongation: blob.elongation,
                kind: blob.kind,
                hits: 1,
                misses: 0,
                quality: 0.25,
                history: [blob.peak]
            ))
            nextID += 1
        }

        return matched
    }

    /// Match consistency, scaled by signal strength, smoothed.
    ///
    /// Deliberately not called a probability anywhere it is shown: there is no
    /// model of what a false detection looks like here, so this is a score.
    /// The two halves are the two ways a track earns trust — it keeps being
    /// re-found (`support`), and what it is re-found as sits well above the
    /// cut (`strength`).
    private func quality(of track: FieldTrack, peak: Float, threshold: Float) -> Float {
        let support = Float(track.hits) / Float(track.hits + 2 * track.misses + 2)
        let headroom = max(0.001, 1 - threshold)
        let strength = min(1, max(0, (peak - threshold) / headroom))
        let target = 0.55 * support + 0.45 * strength
        return track.quality + 0.35 * (target - track.quality)
    }

    private func appendHistory(_ track: inout FieldTrack, level: Float) {
        track.history.append(level)
        if track.history.count > FieldInference.historyLength {
            track.history.removeFirst(track.history.count - FieldInference.historyLength)
        }
    }

    private func boxRect(
        _ box: (minCol: Int, minRow: Int, maxCol: Int, maxRow: Int),
        cell: CGFloat
    ) -> CGRect {
        CGRect(
            x: CGFloat(box.minCol) * cell,
            y: CGFloat(box.minRow) * cell,
            width: CGFloat(box.maxCol - box.minCol + 1) * cell,
            height: CGFloat(box.maxRow - box.minRow + 1) * cell
        )
    }

    // MARK: Coupling

    /// Pearson correlation over every pair of confirmed tracks, thinned to the
    /// strongest few edges per node.
    ///
    /// The thinning is presentational and the only such decision in this file:
    /// nine tracks make up to 36 pairs, and a complete graph over a phone
    /// screen is a grey wash. Keeping each node's strongest
    /// `edgesPerNode` is the k-nearest-neighbour graph of the same matrix —
    /// the structure survives, the wash doesn't.
    private func correlate() -> [FieldEdge] {
        let eligible = tracks.enumerated().filter {
            $0.element.hits >= FieldInference.confirmHits
                && $0.element.history.count >= FieldInference.minCorrelationSamples
        }
        guard eligible.count > 1 else { return [] }

        var all: [FieldEdge] = []
        for i in 0..<eligible.count {
            for j in (i + 1)..<eligible.count {
                let a = eligible[i].element, b = eligible[j].element
                let overlap = min(a.history.count, b.history.count)
                guard overlap >= FieldInference.minCorrelationSamples else { continue }
                let r = Self.pearson(
                    Array(a.history.suffix(overlap)),
                    Array(b.history.suffix(overlap))
                )
                guard abs(r) >= FieldInference.edgeThreshold else { continue }
                all.append(FieldEdge(a: a.id, b: b.id, r: r, samples: overlap))
            }
        }

        all.sort { abs($0.r) > abs($1.r) }
        var degree: [Int: Int] = [:]
        var kept: [FieldEdge] = []
        for edge in all {
            guard kept.count < FieldInference.maxEdges else { break }
            let da = degree[edge.a] ?? 0, db = degree[edge.b] ?? 0
            // *Both* ends must have room. Accepting an edge when either end
            // did — which is what this first said — caps nothing: one
            // well-correlated track ends up the far end of every edge in the
            // graph, and nine tracks come back as a fan of long lines from one
            // point. A strict cap is also what the k-nearest-neighbour
            // thinning below actually means.
            guard da < FieldInference.edgesPerNode, db < FieldInference.edgesPerNode
            else { continue }
            degree[edge.a] = da + 1
            degree[edge.b] = db + 1
            kept.append(edge)
        }
        return kept
    }

    /// Sample Pearson correlation. Returns 0 if either series is constant,
    /// where r is undefined rather than zero — but an edge is the wrong place
    /// to argue about that, and 0 is below every threshold.
    static func pearson(_ a: [Float], _ b: [Float]) -> Float {
        let n = Float(min(a.count, b.count))
        guard n > 1 else { return 0 }
        var sa: Float = 0, sb: Float = 0
        for i in 0..<Int(n) { sa += a[i]; sb += b[i] }
        let ma = sa / n, mb = sb / n
        var cov: Float = 0, va: Float = 0, vb: Float = 0
        for i in 0..<Int(n) {
            let da = a[i] - ma, db = b[i] - mb
            cov += da * db
            va += da * da
            vb += db * db
        }
        guard va > 1e-9, vb > 1e-9 else { return 0 }
        return cov / (va * vb).squareRoot()
    }

    // MARK: Model fit

    /// A standing hypothesis: one drop, and the crest of it being watched.
    ///
    /// Persistent across ticks, which the first version of this wasn't — it
    /// published whichever fit had the lowest residual that tick, and since
    /// that is a different blob almost every tick, the crosshair hopped
    /// between drops and the speed estimate was assembled from unrelated
    /// radii. Holding hypotheses and associating fits into them is what makes
    /// the number a measurement of one thing.
    private struct ModelHypothesis {
        /// Refined by averaging every fit that associates here — the one
        /// quantity several fits of the same drop genuinely agree on.
        var centre: SIMD2<Float>
        var radius: Float
        var residual: Float
        var span: Float
        var trackID: Int
        /// Fits that have landed in this hypothesis. Ranks it against the
        /// others: a hypothesis a dozen fits agree on describes the screen
        /// better than a tighter circle seen once.
        var associations: Int
        var lastTick: Int
        /// Observations of the crest being watched — (time, radius) — capped,
        /// and cleared whenever the crest is lost. The speed is regressed over
        /// exactly these.
        var observations: [(time: Float, radius: Float)] = []
        /// Tick of the last accepted growth, which is what says whether this
        /// front is still moving or has died and is only being kept alive by
        /// fits landing on its inner rings.
        var lastGrowthTick: Int
        var cycles: Float?

        /// Record one observation of the watched crest.
        ///
        /// A gap clears the window first. That is the fix for a real error in
        /// the first version, which regressed over every observation the
        /// hypothesis had ever made: a front is only *followed* on the ticks
        /// its crest is actually re-found, and the stretches in between — where
        /// the fit was landing on some other ring, or the blob was too ragged
        /// to fit — are not slow growth, they are no measurement at all.
        /// Averaging them in read as a wave moving at half speed.
        mutating func observe(time: Double, radius: Float, tick: Int, interval: Double) {
            if let last = observations.last, Double(time) - Double(last.time) > interval * 2.5 {
                observations.removeAll(keepingCapacity: true)
            }
            observations.append((Float(time), radius))
            if observations.count > 8 { observations.removeFirst() }
            lastGrowthTick = tick
        }

        /// Whether this front is still expanding, as opposed to being a spent
        /// ring that fits keep associating into.
        func isAdvancing(at tick: Int) -> Bool {
            tick - lastGrowthTick <= 3
        }

        /// Least-squares slope of radius against time, in cells per second.
        ///
        /// A regression rather than differencing the last two observations:
        /// the radius of a thresholded crest jitters by a fraction of a cell,
        /// which over one 12 Hz interval is the same size as the real growth.
        var growth: Float? {
            guard observations.count >= FieldInference.minSpeedSamples else { return nil }
            let n = Float(observations.count)
            var sumT: Float = 0, sumR: Float = 0, sumTT: Float = 0, sumTR: Float = 0
            for sample in observations {
                sumT += sample.time
                sumR += sample.radius
                sumTT += sample.time * sample.time
                sumTR += sample.time * sample.radius
            }
            let denominator = n * sumTT - sumT * sumT
            guard abs(denominator) > 1e-6 else { return nil }
            return (n * sumTR - sumT * sumR) / denominator
        }
    }

    /// Fit a circle to every tracked detection, sort the fits into standing
    /// hypotheses, and publish the best-established one.
    ///
    /// Only blobs an established track claimed are offered to the fit, so a
    /// model inherits the tracker's noise rejection and can be labelled with
    /// the track it came from. The association arrives keyed by track ID and
    /// nothing here indexes `tracks` — see `update`, whose return value exists
    /// for that reason.
    ///
    /// The crest association is the subtle part. Every crest of one drop
    /// shares its centre, so centre proximity says *which drop* a fit belongs
    /// to but not *which ring* — and the rings are what have to be kept apart,
    /// since jumping from one to the next would read as a jump in radius that
    /// the water never made. A fit is therefore only taken as the next
    /// observation of the watched crest if the radius grew by less than half
    /// the measured crest spacing. Every crest of a travelling wave moves at
    /// the wave's speed, so watching any one of them measures the same thing.
    ///
    /// That gate is an association rule and not the answer: it says "one ring
    /// at a time", which bounds how fast the estimate can *appear* to move
    /// without saying what it is. Using the known wave speed to decide would
    /// make the whole measurement circular.
    private mutating func fitModel(
        grid: FieldGrid,
        blobs: [FieldBlob],
        matched: [Int: Int],
        time: Double
    ) -> FieldEpicentre? {
        // Half a crest spacing, from the last successful radial measurement.
        // Floored, and with a fallback for the ticks before there has been
        // one: early on there is nothing to derive it from, and a zero gate
        // would reject every observation there is.
        let spacing = measuredCycles.map { Float(grid.cols) / $0 }
        let growthGate = max(1.5, (spacing ?? 4.6) * 0.5)

        for (blobIndex, trackID) in matched {
            let blob = blobs[blobIndex]
            guard blob.area >= FieldInference.minFitArea,
                  let circle = FieldModel.fitCircle(cells: blob.cells, weights: blob.weights),
                  circle.residual <= FieldInference.maxFitResidual,
                  circle.span >= FieldInference.minFitSpan
            else { continue }

            guard let index = hypotheses.firstIndex(where: {
                simd_distance($0.centre, circle.centre) <= FieldInference.centreGate
            }) else {
                var fresh = ModelHypothesis(
                    centre: circle.centre,
                    radius: circle.radius,
                    residual: circle.residual,
                    span: circle.span,
                    trackID: trackID,
                    associations: 1,
                    lastTick: tick,
                    lastGrowthTick: tick
                )
                fresh.observe(
                    time: time, radius: circle.radius,
                    tick: tick, interval: FieldInference.interval
                )
                hypotheses.append(fresh)
                continue
            }

            // The centre is what several fits of one drop agree on, so it is
            // averaged; everything else describes the fit that arrived.
            hypotheses[index].centre += 0.3 * (circle.centre - hypotheses[index].centre)
            hypotheses[index].residual = circle.residual
            hypotheses[index].span = circle.span
            hypotheses[index].trackID = trackID
            hypotheses[index].associations += 1
            hypotheses[index].lastTick = tick

            let grew = circle.radius - hypotheses[index].radius
            if grew > 0 && grew <= growthGate {
                hypotheses[index].radius = circle.radius
                hypotheses[index].observe(
                    time: time, radius: circle.radius,
                    tick: tick, interval: FieldInference.interval
                )
            }
        }

        hypotheses.removeAll { tick - $0.lastTick > FieldInference.modelMaxAge }

        // Advancing first, then best established. Both halves are there for
        // something that went wrong without them: ranking on the fit's
        // residual alone made the crosshair hop between drops every tick, and
        // ranking on associations alone pinned it to the *first* drop
        // forever — a spent ring goes on collecting fits from its inner
        // crests long after its front has died, so it wins a popularity
        // contest it has no business being in. A front that is still moving is
        // the one the screen is currently about.
        guard var best = hypotheses.enumerated().max(by: {
            (
                $0.element.isAdvancing(at: tick) ? 1 : 0,
                $0.element.associations,
                -$0.element.residual
            ) < (
                $1.element.isAdvancing(at: tick) ? 1 : 0,
                $1.element.associations,
                -$1.element.residual
            )
        }) else { return nil }

        // Wavelength, measured about this centre. Re-measured every tick the
        // hypothesis is published, and kept when a tick can't see enough rays.
        if let cycles = Self.radialCycles(grid: grid, centre: best.element.centre) {
            hypotheses[best.offset].cycles = cycles
            best.element.cycles = cycles
            measuredCycles = cycles
        }

        return FieldEpicentre(
            circle: FieldCircle(
                centre: best.element.centre,
                radius: best.element.radius,
                residual: best.element.residual,
                span: best.element.span
            ),
            trackID: best.element.trackID,
            samples: best.element.observations.count,
            // Cells per second → screen widths per second, the unit
            // `kWaveSpeed` is written in and so the one that makes them
            // comparable.
            speed: best.element.growth.map { $0 / Float(grid.cols) },
            cycles: best.element.cycles
        )
    }

    /// The ripple wavelength, from the averaged radial periodogram about a
    /// fitted epicentre.
    ///
    /// Radially, and that is the whole point. The first version transformed a
    /// *row* of the panel and came back 40% low, for a reason worth keeping
    /// written down: a row crosses a ring obliquely, so it stretches the
    /// wavelength by the secant of the crossing angle, and the wave is only
    /// about one and a half cycles wide inside its own envelope anyway — so
    /// what the row's spectrum actually peaked on was the envelope, not the
    /// ripple. Out from the epicentre there is no obliquity and the profile is
    /// the wave itself.
    ///
    /// Averaged over rays (a periodogram average, the standard cure for a
    /// single spectrum's variance) and then parabolically interpolated about
    /// the peak bin, because 20 samples put the bins 1.7 cycles apart and the
    /// answer sits between two of them. Rays that leave the panel are dropped
    /// rather than zero-padded: a ray half full of zeros has a step in it, and
    /// a step has energy everywhere.
    private static func radialCycles(grid: FieldGrid, centre: SIMD2<Float>) -> Float? {
        let length = FieldInference.radialSamples
        var power = [Float](repeating: 0, count: length / 2 + 1)
        var rays = 0

        for ray in 0..<FieldInference.radialRays {
            let angle = 2 * Float.pi * Float(ray) / Float(FieldInference.radialRays)
            let step = SIMD2(cos(angle), sin(angle))
            var profile = [Float](repeating: 0, count: length)
            var complete = true
            for sample in 0..<length {
                let at = centre + step * Float(sample)
                let col = Int(at.x), row = Int(at.y)
                guard col >= 0, col < grid.cols, row >= 0, row < grid.rows else {
                    complete = false
                    break
                }
                profile[sample] = grid.level(col, row)
            }
            guard complete else { continue }

            let mean = profile.reduce(0, +) / Float(length)
            for sample in 0..<length {
                let hann = 0.5 - 0.5 * cos(2 * .pi * Float(sample) / Float(length - 1))
                profile[sample] = (profile[sample] - mean) * hann
            }
            for k in 1...(length / 2) {
                var re: Float = 0
                var im: Float = 0
                for sample in 0..<length {
                    let phase = -2 * Float.pi * Float(k) * Float(sample) / Float(length)
                    re += profile[sample] * cos(phase)
                    im += profile[sample] * sin(phase)
                }
                power[k] += re * re + im * im
            }
            rays += 1
        }
        guard rays >= 2 else { return nil }

        // From bin 2: bin 1 is one cycle across the whole profile, which is
        // the decay envelope rather than the ripple, and it would otherwise
        // win on every ray.
        var peak = 2
        for k in 2...(length / 2) where power[k] > power[peak] { peak = k }
        guard power[peak] > 0 else { return nil }

        // Quadratic interpolation on the three bins about the peak — the
        // standard sub-bin estimate, and worth it here: without it the answer
        // can only be a multiple of 1.7 cycles.
        var refined = Float(peak)
        if peak > 1 && peak < length / 2 {
            let left = power[peak - 1], middle = power[peak], right = power[peak + 1]
            let denominator = left - 2 * middle + right
            if abs(denominator) > 1e-9 {
                refined += 0.5 * (left - right) / denominator
            }
        }
        // Cycles across `length` cells → cycles across the panel's width.
        return refined * Float(grid.cols) / Float(length)
    }
}
