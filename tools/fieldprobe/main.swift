// The launch screen's analysis, run off-device and printed — a development
// tool, nothing here ships.
//
// `tools/ripplepreview` answers "what does the field look like"; this answers
// "is the overlay's arithmetic true". It compiles the shipping
// `FieldAnalysis.swift` (not a copy of it) against the shipping
// `FieldAnalysis.metal` and steps the real pipeline through a launch at the
// real inference rate, printing every tick.
//
// The two lines to read are at the bottom. The overlay measures the water's
// propagation speed by differentiating a fitted circle's radius, and its
// spatial frequency by transforming a row — and `RippleSurface.h` generated
// that water from `kWaveSpeed = 0.42` widths/second and `kWaveNumber = 46`
// radians/width, which is 46/2π = 7.32 cycles/width. Nothing in the pipeline
// is told either number. If the measurements don't land on them, the overlay
// is decoration and this is where that shows up.
//
//   cd tools/fieldprobe && ./probe.sh
//
// Named `main.swift` because it is top-level code and Swift only allows that
// in a file with this name — the shipping sources are compiled alongside it.

import CoreGraphics
import Foundation
import Metal
import simd

let args = CommandLine.arguments
let libraryPath = args.count > 1 ? args[1] : "Probe.metallib"
let until = args.count > 2 ? Double(args[2])! : 2.4
/// Which field to step through. 0 is the one this was tuned on and the one the
/// numbers below were checked against, so it is the default — the app picks a
/// random seed per launch, and passing one here is how to confirm the
/// measurements hold on a field nobody tuned against.
let seed = args.count > 3 ? Float(args[3])! : 0

/// The phone, in points: iPhone 17 — the same size `ripplepreview` uses, so
/// the two tools are describing one screen.
let screen = CGSize(width: 402, height: 874)
/// `PixelRippleField.pixelSize`, then its own rounding.
let pixelTarget: CGFloat = 12
let columns = max(1, Int((screen.width / pixelTarget).rounded()))
let cell = screen.width / CGFloat(columns)

/// Mirrors `FieldSampleArgs` in the kernel, and `FieldSampler.Args` in the app.
struct Args {
    var size: SIMD2<Float>
    var cell: Float
    var time: Float
    var seed: Float
    var cols: UInt32
    var rows: UInt32
}

guard let device = MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue(),
      let library = try? device.makeLibrary(URL: URL(fileURLWithPath: libraryPath)),
      let function = library.makeFunction(name: "fieldSampleKernel"),
      let pipeline = try? device.makeComputePipelineState(function: function)
else { fatalError("no Metal device or library at \(libraryPath)") }

let (cols, rows) = FieldSampler.lattice(size: screen, cell: cell)
let count = cols * rows
guard let buffer = device.makeBuffer(
    length: count * MemoryLayout<Float>.stride, options: .storageModeShared
) else { fatalError("no buffer") }

func sample(at time: Double) -> FieldGrid {
    var args = Args(
        size: SIMD2(Float(screen.width), Float(screen.height)),
        cell: Float(cell), time: Float(time), seed: seed,
        cols: UInt32(cols), rows: UInt32(rows)
    )
    let commands = queue.makeCommandBuffer()!
    let encoder = commands.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(buffer, offset: 0, index: 0)
    encoder.setBytes(&args, length: MemoryLayout<Args>.stride, index: 1)
    encoder.dispatchThreads(
        MTLSize(width: cols, height: rows, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1)
    )
    encoder.endEncoding()
    commands.commit()
    commands.waitUntilCompleted()

    let levels: [Float] = buffer.contents()
        .withMemoryRebound(to: Float.self, capacity: count) { pointer in
            Array(UnsafeBufferPointer(start: pointer, count: count))
        }
    return FieldGrid(levels: levels, cols: cols, rows: rows, cell: cell)
}

print("seed \(Int(seed))")
print("lattice \(cols)x\(rows)  cell \(String(format: "%.3f", cell))pt  "
      + "rate \(Int(FieldInference.rate))Hz  screen \(Int(screen.width))x\(Int(screen.height))")
print("")
print("   t   det trk edg   tau    lambda   state          epicentre         rms   span   v-hat")
print("  ---- --- --- ---  -----  -------  -------  ------------------- ------ ------ -------")

/// Column padding, since `String(format:)`'s `%s` wants a C string and
/// handing it a Swift or Foundation string is undefined behaviour.
func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
    let spaces = String(repeating: " ", count: max(0, width - text.count))
    return left ? spaces + text : text + spaces
}

var analyzer = FieldAnalyzer()
var speeds: [Float] = []
var cycles: [Float] = []
var firstLock: Double?
var ticks = 0
let interval = FieldInference.interval

var time = 0.0
while time <= until + 1e-9 {
    let began = Date()
    let grid = sample(at: time)
    let frame = analyzer.ingest(grid, time: time, latency: Date().timeIntervalSince(began))
    ticks += 1
    if let c = frame.epicentre?.cycles { cycles.append(c) }

    let states = frame.tracks.map(\.state)
    let state = states.contains(.locked) ? "LOCK"
        : (states.contains(.tracking) ? "TRK" : (frame.tracks.isEmpty ? "—" : "ACQ"))
    if states.contains(.locked), firstLock == nil { firstLock = time }

    var model = pad("", 41)
    if let epicentre = frame.epicentre {
        let speed = epicentre.speed
        if let speed, speed > 0 { speeds.append(speed) }
        let speedText = speed.map { String(format: "%.3f", $0) } ?? "—"
        model = String(
            format: "(%5.1f,%5.1f) R%5.1f %6.2f %6.2f",
            epicentre.circle.centre.x, epicentre.circle.centre.y,
            epicentre.circle.radius, epicentre.circle.residual, epicentre.circle.span
        ) + "  " + pad(speedText, 7, left: true)
    }

    print(String(format: "  %4.2f %3d %3d %3d  %.3f  %5.1f    ",
                 time, frame.detections, frame.tracks.count, frame.edges.count,
                 frame.stats.threshold, frame.epicentre?.cycles ?? 0)
          + pad(state, 7) + "  " + model)
    time += interval
}

func mean(_ xs: [Float]) -> Float { xs.isEmpty ? 0 : xs.reduce(0, +) / Float(xs.count) }

print("")
print("  ticks \(ticks)   first lock "
      + (firstLock.map { String(format: "%.2fs", $0) } ?? "never"))
print(String(format: "  v-hat   mean %.3f W/s over %d ticks   |   kWaveSpeed  0.420   error %+.1f%%",
             mean(speeds), speeds.count,
             speeds.isEmpty ? 0 : (mean(speeds) / 0.42 - 1) * 100))
print(String(format: "  lambda  mean %.2f c/W over %d ticks   |   kWaveNumber 7.32    error %+.1f%%",
             mean(cycles), cycles.count, (mean(cycles) / 7.32 - 1) * 100))
