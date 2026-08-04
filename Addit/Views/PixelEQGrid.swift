import SwiftUI

/// An "LED pixel" spectrum meter. Each column is a frequency band lighting up
/// bottom-to-top with level; lit pixels run a green→red spectrum by height
/// (classic LED meter), unlit pixels stay grey so the whole grid is always
/// visible.
///
/// Used at two very different sizes: `side: 6` at 20pt beside the currently
/// playing track in the album view, and `side: 16` filling the full player's EQ
/// page. Everything about a cell — gap, corner radius, bloom — is expressed as
/// a ratio of the cell itself, so the two read as the same object at different
/// scales rather than as a small tidy grid and a large sparse one.
///
/// Data comes from `AudioAnalyzerService`'s existing FFT tap. Registration is
/// consumer-counted, so several grids can coexist without stealing the tap
/// from each other.
struct PixelEQGrid: View {
    /// When false (track paused) all pixels render grey — the grid itself
    /// still marks which row is the current track.
    let isPlaying: Bool

    /// Fixed square size, or `nil` to fill whatever space the parent gives it.
    /// The grid assumes that space is square; it doesn't enforce it.
    var size: CGFloat? = 20

    /// Cells per side. 16 lines up exactly with the analyzer's 16 bands — one
    /// band per column, no folding.
    var side: Int = 6

    @Environment(AudioAnalyzerService.self) private var analyzer
    @Environment(\.colorScheme) private var colorScheme
    /// Unique per grid instance so two coexisting grids can never
    /// register/unregister under the same consumer key.
    @State private var consumerId = UUID().uuidString

    /// Gap as a fraction of cell size. Chosen to reproduce the original 6×6
    /// metrics exactly — at 20pt across, `20 / (6 + 5 × 0.4)` is a 2.5pt cell
    /// with a 1pt gap, which is what that grid has always drawn — so scaling
    /// the grid up doesn't quietly restyle the small one.
    private static let gapRatio: CGFloat = 0.4

    /// Green (bottom row) → red (top row).
    private static func rowColors(side: Int) -> [Color] {
        (0..<side).map { row in
            let t = Double(row) / Double(max(1, side - 1))
            return Color(hue: 0.33 * (1 - t), saturation: 0.85, brightness: 0.95)
        }
    }

    var body: some View {
        // Read bands in the body (not just inside the Canvas closure) so
        // Observation registers the dependency and re-renders as FFT frames
        // land (~10 Hz from the analyzer's buffer size).
        let bands = analyzer.bands
        let glow = colorScheme == .dark
        let colors = Self.rowColors(side: side)

        Canvas { context, canvasSize in
            let n = side
            // Solve total = n·cell + (n-1)·gap with gap = ratio·cell.
            let cell = canvasSize.width / (CGFloat(n) + CGFloat(n - 1) * Self.gapRatio)
            let gap = cell * Self.gapRatio
            guard cell > 0 else { return }

            func cellRect(col: Int, row: Int) -> CGRect {
                CGRect(
                    x: CGFloat(col) * (cell + gap),
                    // row 0 = bottom of the canvas
                    y: canvasSize.height - cell - CGFloat(row) * (cell + gap),
                    width: cell,
                    height: cell
                )
            }

            let litCounts = (0..<n).map { isPlaying ? litRows(bands: bands, column: $0) : 0 }

            // Phosphor bloom pass: one blurred layer under all lit cells so
            // they read as emitting light (Phosphor language; dark mode only).
            // Blur and spread scale with the cell — at the ratios the 2.5pt
            // cell was tuned with — or the bloom vanishes at 16×16.
            if glow {
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: cell * 0.64))
                    for col in 0..<n {
                        for row in 0..<litCounts[col] {
                            layer.fill(
                                Path(cellRect(col: col, row: row).insetBy(dx: -cell * 0.2, dy: -cell * 0.2)),
                                with: .color(colors[row].opacity(0.65))
                            )
                        }
                    }
                }
            }

            // Crisp pixel pass.
            for col in 0..<n {
                for row in 0..<n {
                    let color = row < litCounts[col] ? colors[row] : Color.gray.opacity(0.3)
                    context.fill(
                        Path(roundedRect: cellRect(col: col, row: row), cornerRadius: cell * 0.25),
                        with: .color(color)
                    )
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear { analyzer.addConsumer(consumerId) }
        .onDisappear { analyzer.removeConsumer(consumerId) }
        // If the grid appeared before the engine was producing audio (tap
        // install is skipped then), retry once playback actually starts —
        // addConsumer is idempotent.
        .onChange(of: isPlaying) { _, playing in
            if playing { analyzer.addConsumer(consumerId) }
        }
    }

    /// Fold the analyzer's 16 bands into `side` columns (taking each group's
    /// max so transient peaks still pop at small sizes) and convert the 0–1
    /// level into a lit-pixel count. At `side: 16` each column is exactly one
    /// band and the fold is a no-op.
    private func litRows(bands: [Float], column: Int) -> Int {
        let total = bands.count
        guard total > 0 else { return 0 }
        let lo = column * total / side
        let hi = max(lo + 1, (column + 1) * total / side)
        let level = bands[lo..<min(hi, total)].max() ?? 0
        return min(side, Int((CGFloat(level) * CGFloat(side)).rounded()))
    }
}
