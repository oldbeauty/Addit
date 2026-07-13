import SwiftUI

/// A tiny 6×6 "LED pixel" spectrum meter shown beside the currently playing
/// track in the album view (replaces the static speaker glyph). Each column
/// is a frequency band lighting up bottom-to-top with level; lit pixels run
/// a green→red spectrum by height (classic LED meter), unlit pixels stay
/// grey so the full 36-pixel grid is always visible.
///
/// Data comes from `AudioAnalyzerService`'s existing FFT tap. Registration
/// is consumer-counted, so this grid and the full player's EQ page can
/// coexist without stealing the tap from each other.
struct MiniEQGrid: View {
    /// When false (track paused) all pixels render grey — the grid itself
    /// still marks which row is the current track.
    let isPlaying: Bool
    var size: CGFloat = 20

    @Environment(AudioAnalyzerService.self) private var analyzer
    @Environment(\.colorScheme) private var colorScheme
    /// Unique per grid instance so two coexisting grids can never
    /// register/unregister under the same consumer key.
    @State private var consumerId = UUID().uuidString

    private static let gridSide = 6

    /// Green (bottom row) → red (top row), precomputed once.
    private static let rowColors: [Color] = (0..<gridSide).map { row in
        let t = Double(row) / Double(gridSide - 1)
        return Color(hue: 0.33 * (1 - t), saturation: 0.85, brightness: 0.95)
    }

    var body: some View {
        // Read bands in the body (not just inside the Canvas closure) so
        // Observation registers the dependency and re-renders as FFT frames
        // land (~10 Hz from the analyzer's buffer size).
        let bands = analyzer.bands
        let glow = colorScheme == .dark
        Canvas { context, canvasSize in
            let n = Self.gridSide
            let gap: CGFloat = 1
            let cell = (canvasSize.width - gap * CGFloat(n - 1)) / CGFloat(n)

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
            if glow {
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 1.6))
                    for col in 0..<n {
                        for row in 0..<litCounts[col] {
                            layer.fill(
                                Path(cellRect(col: col, row: row).insetBy(dx: -0.5, dy: -0.5)),
                                with: .color(Self.rowColors[row].opacity(0.65))
                            )
                        }
                    }
                }
            }

            // Crisp pixel pass.
            for col in 0..<n {
                for row in 0..<n {
                    let color = row < litCounts[col] ? Self.rowColors[row] : Color.gray.opacity(0.3)
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

    /// Fold the analyzer's 16 bands into 6 columns (taking each group's max
    /// so transient peaks still pop at this size) and convert the 0–1 level
    /// into a lit-pixel count.
    private func litRows(bands: [Float], column: Int) -> Int {
        let total = bands.count
        guard total > 0 else { return 0 }
        let lo = column * total / Self.gridSide
        let hi = max(lo + 1, (column + 1) * total / Self.gridSide)
        let level = bands[lo..<min(hi, total)].max() ?? 0
        return min(Self.gridSide, Int((CGFloat(level) * CGFloat(Self.gridSide)).rounded()))
    }
}
