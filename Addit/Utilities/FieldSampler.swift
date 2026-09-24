import CoreGraphics
import Foundation
import Metal
import SwiftUI

/// The analyser's read of the panel: dispatches `FieldAnalysis.metal` over the
/// cell lattice and hands back the levels.
///
/// A compute kernel and a buffer read rather than a Swift copy of the wave,
/// which is the point — `RippleSurface.h` is the only place the water is
/// defined, and both the picture and the analysis of it come from there. The
/// alternative was porting `surfaceAt` to Swift, which would have worked
/// exactly once: the first edit to either copy and the overlay's boxes would
/// be describing water that isn't on screen.
///
/// Asynchronous, and deliberately not waited on. `waitUntilCompleted` inside
/// the tick would stall the main thread on the GPU mid-frame; a completion
/// handler means the analysis lands a fraction of a frame after the picture it
/// describes, which is what a real inference pipeline does anyway and is
/// invisible at this rate.
@MainActor
final class FieldSampler {
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    /// Reused across ticks — the lattice only changes when the screen does.
    private var buffer: MTLBuffer?
    private var capacity = 0

    /// Mirrors `FieldSampleArgs` in `FieldAnalysis.metal`. Field order and
    /// types have to match; Metal's `float2` is 8-byte aligned and so is
    /// `SIMD2<Float>`, which is what makes the two layouts agree without
    /// padding either side.
    private struct Args {
        var size: SIMD2<Float>
        var cell: Float
        var time: Float
        var seed: Float
        var cols: UInt32
        var rows: UInt32
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "fieldSampleKernel"),
              let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }
        self.queue = queue
        self.pipeline = pipeline
    }

    /// The lattice the panel is drawn on, for a given screen and cell size.
    ///
    /// Columns divide the width exactly (`PixelRippleField.fittedCell` sees to
    /// that) and the last row is allowed to hang off the bottom, which is what
    /// the dots do — so the analyser's grid is the panel's grid including its
    /// partial row, rather than a tidied version of it.
    /// `nonisolated` because it is arithmetic on two sizes and touches
    /// nothing else — which also lets `tools/fieldprobe` index the same grid
    /// off the main actor instead of keeping its own copy of the rule.
    nonisolated static func lattice(size: CGSize, cell: CGFloat) -> (cols: Int, rows: Int) {
        guard cell > 0 else { return (0, 0) }
        return (
            max(1, Int((size.width / cell).rounded())),
            max(1, Int((size.height / cell).rounded(.up)))
        )
    }

    func sample(size: CGSize, cell: CGFloat, time: Double, seed: Float) async -> FieldGrid? {
        let (cols, rows) = Self.lattice(size: size, cell: cell)
        let count = cols * rows
        guard count > 0 else { return nil }

        if capacity < count || buffer == nil {
            buffer = pipeline.device.makeBuffer(
                length: count * MemoryLayout<Float>.stride,
                options: .storageModeShared
            )
            capacity = count
        }
        guard let buffer,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder()
        else { return nil }

        var args = Args(
            size: SIMD2(Float(size.width), Float(size.height)),
            cell: Float(cell),
            time: Float(time),
            seed: seed,
            cols: UInt32(cols),
            rows: UInt32(rows)
        )
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setBytes(&args, length: MemoryLayout<Args>.stride, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: cols, height: rows, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1)
        )
        encoder.endEncoding()

        await withCheckedContinuation { continuation in
            commands.addCompletedHandler { _ in continuation.resume() }
            commands.commit()
        }

        let levels = buffer.contents().withMemoryRebound(to: Float.self, capacity: count) {
            Array(UnsafeBufferPointer(start: $0, count: count))
        }
        return FieldGrid(levels: levels, cols: cols, rows: rows, cell: cell)
    }
}

/// The inference loop: samples the panel at `FieldInference.rate`, runs the
/// pipeline, and publishes the frame the overlay draws.
///
/// Its own loop rather than work hung off the render's `TimelineView`, for
/// three reasons. The rates are different and meant to be. The analysis is
/// asynchronous, and a view body can't await. And a body that mutated the
/// tracker would be running the detector once per *frame* of the field —
/// sixty times a second, five times more often than anything reads the result.
///
/// Not in `Services/`, and so not injected: it has no app state, it is alive
/// only while the splash is on screen, and two splashes would each want their
/// own tracker. `PixelRippleField` owns one as `@State`.
@MainActor
@Observable
final class FieldAnalysisRunner {
    /// The latest completed tick. `nil` before the first one lands, which is
    /// what keeps the overlay off the screen for the frame or two before there
    /// is anything to say.
    private(set) var frame: FieldFrame?

    @ObservationIgnored private var analyzer = FieldAnalyzer()
    /// `nil` on a device that can't build the pipeline, which is what
    /// leaves the splash as the field alone rather than failing.
    @ObservationIgnored private let sampler: FieldSampler? = FieldSampler()
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// What the running loop was started for, so a re-layout can be told from
    /// a redraw and only the former restarts anything.
    @ObservationIgnored private var lattice: (size: CGSize, cell: CGFloat)?

    /// Start — or restart, if the panel's geometry changed — the loop.
    ///
    /// `start` is the field's own clock, the same `Date` `PixelRippleField`
    /// hands the shader, so the analysis is looking at the frame the panel is
    /// showing rather than at its own idea of the time.
    func run(size: CGSize, cell: CGFloat, start: Date, seed: Float) {
        guard sampler != nil else { return }
        if let lattice, lattice.size == size, lattice.cell == cell, loop != nil { return }
        lattice = (size, cell)
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let began = Date()
                await self.step(
                    size: size, cell: cell,
                    time: began.timeIntervalSince(start), seed: seed
                )
                // Fixed rate, absorbing its own cost: sleep the remainder of
                // the interval rather than the whole of it, so the tick rate
                // is the rate and not the rate minus however long a tick took.
                let remaining = FieldInference.interval - Date().timeIntervalSince(began)
                if remaining > 0 {
                    try? await Task.sleep(for: .seconds(remaining))
                }
            }
        }
    }

    /// The still the field holds under Reduce Motion: step the pipeline up to
    /// that frame as fast as the GPU will answer, publish the last tick, stop.
    ///
    /// Stepping rather than analysing the held frame once, which is what this
    /// did first and which sells the accessible version short. A detector has
    /// no state on its first tick — every box is provisional, every quality is
    /// its seed value, no track has a history to correlate and no crest has
    /// been seen twice, so the still came out saying the analyser had found
    /// nothing. Walking the same frames the animated version would have seen
    /// leaves the tracker in the state it would genuinely be in at that
    /// moment. Nothing is fabricated and nothing moves: the field holds one
    /// frame, and the overlay holds a real analysis of it.
    func runStill(size: CGSize, cell: CGFloat, upTo end: Double, seed: Float) {
        loop?.cancel()
        lattice = nil
        loop = Task { [weak self] in
            var time = 0.0
            while time <= end, !Task.isCancelled {
                guard let self else { return }
                await self.step(
                    size: size, cell: cell, time: time, seed: seed,
                    publish: time + FieldInference.interval > end
                )
                time += FieldInference.interval
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        lattice = nil
    }

    /// One tick. `publish: false` runs the pipeline for its state without
    /// showing the result — what the Reduce Motion run-up needs, since
    /// publishing each of those would flicker a whole launch's worth of
    /// overlays across a field that is holding still.
    private func step(
        size: CGSize,
        cell: CGFloat,
        time: Double,
        seed: Float,
        publish: Bool = true
    ) async {
        let began = Date()
        guard let sampler else { return }
        guard let grid = await sampler.sample(size: size, cell: cell, time: time, seed: seed)
        else { return }
        let analysed = analyzer.ingest(
            grid, time: time, latency: Date().timeIntervalSince(began)
        )
        if publish { frame = analysed }
    }
}
