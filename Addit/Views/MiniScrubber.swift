import SwiftUI
import UIKit

/// The collapsed pill's scrubber: a single centred waveform strip, drawn and
/// grabbed at the mini bar's scale. The expanded player uses `FullScrubber`
/// instead — the two are different drawings of the same thing, and
/// `MorphSlot` cross-fades between them as the pill opens.
struct MiniScrubber: View {
    let value: TimeInterval
    let duration: TimeInterval
    let accentColor: Color
    let waveformSamples: [Float]
    let onChanged: (TimeInterval) -> Void
    let onEnded: (TimeInterval) -> Void

    private let barHeight: CGFloat = 20
    private let hitAreaHeight: CGFloat = 28
    private let minBarFraction: CGFloat = 0.08

    // Aesthetic targets. If the service hands us more samples than fit at this
    // spacing, we downsample (peak-per-bucket) so nothing ever clips off the
    // right edge.
    private let preferredGap: CGFloat = 3.5
    private let minBarWidth: CGFloat = 1.5
    /// Horizontal half-width (points) of the grabbable area around the
    /// playhead. Touches outside this window fall through to the parent
    /// tap gesture (which opens the full player) instead of scrubbing.
    private let grabRadius: CGFloat = 22

    @State private var lastHapticBar: Int = -1
    @State private var hapticGenerator: UIImpactFeedbackGenerator?
    /// Tracks whether the in-flight drag began close enough to the
    /// playhead to count as a real scrub.
    @State private var isDragActive = false

    private var progress: Double {
        duration > 0 ? value / duration : 0
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width

            Canvas { context, size in
                let rawSamples = waveformSamples.isEmpty
                    ? [Float](repeating: 0.15, count: 120)
                    : waveformSamples
                guard !rawSamples.isEmpty else { return }

                // How many bars fit at the preferred spacing?
                let cellMin = minBarWidth + preferredGap
                let maxFit = max(1, Int((size.width + preferredGap) / cellMin))
                let displayCount = min(rawSamples.count, maxFit)

                // Downsample to displayCount by taking the peak in each bucket
                // so the visual still reflects the loudest moment, not an
                // averaged-down mush.
                let samples: [Float]
                if displayCount == rawSamples.count {
                    samples = rawSamples
                } else {
                    var out = [Float](repeating: 0, count: displayCount)
                    for j in 0..<displayCount {
                        let start = j * rawSamples.count / displayCount
                        let end = (j + 1) * rawSamples.count / displayCount
                        var peak: Float = 0
                        for k in start..<end {
                            peak = max(peak, rawSamples[k])
                        }
                        out[j] = peak
                    }
                    samples = out
                }

                let count = samples.count
                let gap: CGFloat = preferredGap
                let barWidth = max(minBarWidth, (size.width - CGFloat(count - 1) * gap) / CGFloat(count))
                let progressX = size.width * progress

                for i in 0..<count {
                    let x = (barWidth + gap) * CGFloat(i)
                    let amplitude = CGFloat(max(Float(minBarFraction), samples[i]))
                    let h = amplitude * barHeight
                    let y = (barHeight - h) / 2 + (size.height - barHeight) / 2

                    let rect = CGRect(x: x, y: y, width: barWidth, height: h)
                    let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)

                    let isPast = x + barWidth <= progressX
                    let isPartial = x < progressX && x + barWidth > progressX

                    if isPast {
                        context.fill(path, with: .color(accentColor))
                    } else if isPartial {
                        // Split bar at the progress boundary
                        let splitX = progressX - x
                        let filledRect = CGRect(x: x, y: y, width: splitX, height: h)
                        let unfilledRect = CGRect(x: x + splitX, y: y, width: barWidth - splitX, height: h)
                        context.fill(Path(roundedRect: filledRect, cornerRadius: barWidth / 2),
                                     with: .color(accentColor))
                        context.fill(Path(roundedRect: unfilledRect, cornerRadius: barWidth / 2),
                                     with: .color(accentColor.opacity(0.25)))
                    } else {
                        context.fill(path, with: .color(accentColor.opacity(0.25)))
                    }
                }
            }
            .frame(height: hitAreaHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        // First event of the gesture — only engage if the
                        // touch started near the playhead. Otherwise stay
                        // inactive and ignore further events so the tap
                        // falls through to "open full player."
                        if !isDragActive {
                            let playheadX = width * progress
                            guard abs(drag.startLocation.x - playheadX) <= grabRadius else {
                                return
                            }
                            isDragActive = true
                        }

                        let fraction = max(0, min(1, drag.location.x / width))
                        onChanged(fraction * max(duration, 1))

                        // Haptic tick at fixed 40 discrete steps (independent of bar count)
                        let hapticSteps = 40
                        let currentBar = min(hapticSteps - 1, Int(fraction * CGFloat(hapticSteps)))
                        if currentBar != lastHapticBar {
                            if hapticGenerator == nil {
                                hapticGenerator = UIImpactFeedbackGenerator(style: .light)
                                hapticGenerator?.prepare()
                            }
                            hapticGenerator?.impactOccurred(intensity: 0.7)
                            lastHapticBar = currentBar
                        }
                    }
                    .onEnded { drag in
                        if isDragActive {
                            let fraction = max(0, min(1, drag.location.x / width))
                            onEnded(fraction * max(duration, 1))
                        }
                        isDragActive = false
                        lastHapticBar = -1
                        hapticGenerator = nil
                    }
            )
        }
        .frame(height: hitAreaHeight)
    }
}
