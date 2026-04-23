import SwiftUI
import UIKit

/// A drop-in replacement for the album-cover image that, when tapped,
/// kicks off a visible pixel-by-pixel shear sort of the cover (sorted by
/// luminance). Tapping again after it's fully sorted replays the swap
/// log in reverse to animate back to the original image.
///
/// The underlying album-art data is never touched — this view works on a
/// downsampled pixel buffer it builds on its first tap. The "grid" is an
/// N×N lattice (default 96) of colored cells; each frame we apply a batch
/// of pairwise swaps from an odd-even transposition pass and re-render
/// the grid as a UIImage. At the end of the sort the image looks like a
/// snake-ordered luminance gradient of the cover — dark in the top-left,
/// bright in the bottom-right, with banding that still reads as the
/// original cover's color palette.
///
/// Reverse animation is cheap: a swap is its own inverse, so we just
/// walk the recorded `swapLog` backward and re-apply each pair. It's an
/// iterative array traversal — no recursion, no call-stack growth.
struct PixelSortCoverView: View {
    let image: UIImage
    let size: CGFloat
    let cornerRadius: CGFloat

    /// Grid resolution. 96 keeps each cell ~2–3 pt on a typical cover
    /// tile: coarse enough to watch individual cells migrate, fine enough
    /// that the final gradient still looks like the album.
    private let gridSize = 96
    /// How many pairwise comparisons to apply per animation frame.
    /// Forward and reverse run at the same rate so the cycle feels
    /// symmetric — same "speed of pixel migration" either direction.
    private let forwardSwapsPerTick = 400
    private let reverseSwapsPerTick = 400

    @State private var mode: Mode = .idle
    @State private var renderedImage: UIImage?

    // Pixel-grid state. Allocated on the first tap.
    @State private var sourceColors: [UInt32] = []   // RGBA, length gridSize²
    @State private var luminance: [Float] = []       // parallel array
    @State private var perm: [Int32] = []            // perm[i] = original idx now at position i
    @State private var swapLog: [SwapPair] = []

    // Forward-sort scheduler state.
    @State private var phaseIdx = 0
    @State private var pendingPairs: [(Int32, Int32)] = []

    // Reverse-sort scheduler state.
    @State private var reverseCursor = 0

    // Drives the animation. One DisplayLink tick per 1/60 s.
    @State private var displayLink: CADisplayLink?
    @State private var linkTarget: DisplayLinkTarget?

    private enum Mode {
        case idle              // original image, tap → begin sorting
        case sorting           // running forward swaps, tap → pauseMidSort
        case pausedMidSort     // paused while sorting, tap → begin revert
        case sorted            // fully sorted, tap → begin revert
        case reverting         // replaying log backward, tap → pauseMidRevert
        case pausedMidRevert   // paused while reverting, tap → resume revert
    }

    var body: some View {
        ZStack {
            if mode == .idle || renderedImage == nil {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            } else if let rendered = renderedImage {
                Image(uiImage: rendered)
                    .resizable()
                    // Nearest-neighbor so each grid cell stays crisply
                    // rectangular instead of smearing into a blurry
                    // upsample. That sharpness is most of the charm.
                    .interpolation(.none)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onTapGesture { handleTap() }
        .onDisappear { tearDownDisplayLink() }
    }

    // MARK: - Tap handling

    private func handleTap() {
        switch mode {
        case .idle:
            // First tap kicks off the sort from scratch.
            beginSort()

        case .sorting:
            // Freeze the sort in place. Next tap will start a revert
            // from exactly the current position (since `reverseCursor`
            // is derived from `swapLog.count` at that moment).
            mode = .pausedMidSort
            stopDisplayLink()

        case .pausedMidSort, .sorted:
            // From either "paused mid-sort" or "fully sorted", tapping
            // begins a revert. The swap log already represents every
            // swap we've made so far, so replaying it backward cleanly
            // retraces our steps — whether we got all the way to sorted
            // or stopped halfway.
            beginRevert()

        case .reverting:
            // Freeze the revert. `reverseCursor` stays where it is; the
            // next tap will pick up from exactly this point.
            mode = .pausedMidRevert
            stopDisplayLink()

        case .pausedMidRevert:
            // Resume the revert from where we stopped — NOT restart the
            // sort. Per spec: pausing during a revert keeps reverting on
            // the next tap.
            mode = .reverting
            startDisplayLink()
        }
    }

    // MARK: - Forward sort

    private func beginSort() {
        // Downsample the source image into an N×N buffer on a background
        // queue, then start the animation loop on the main actor.
        let gridSize = self.gridSize
        let src = image
        Task.detached(priority: .userInitiated) {
            let (colors, lumas) = Self.downsample(src, to: gridSize)
            await MainActor.run {
                self.sourceColors = colors
                self.luminance = lumas
                self.perm = (0..<Int32(gridSize * gridSize)).map { $0 }
                self.swapLog = []
                self.swapLog.reserveCapacity(80_000)
                self.phaseIdx = 0
                self.pendingPairs = []
                self.mode = .sorting
                self.renderCurrentState()
                self.startDisplayLink()
            }
        }
    }

    private func advanceSort() {
        var swapsThisTick = 0
        while swapsThisTick < forwardSwapsPerTick {
            if pendingPairs.isEmpty {
                // Finished the previous subpass — queue up the next one.
                if !queueNextPhase() {
                    // No more phases: we're sorted.
                    renderCurrentState()
                    mode = .sorted
                    stopDisplayLink()
                    return
                }
            }

            // Drain a chunk of this subpass's comparisons.
            let remaining = forwardSwapsPerTick - swapsThisTick
            let take = min(remaining, pendingPairs.count)
            for i in 0..<take {
                let (a, b) = pendingPairs[i]
                if compareAndSwap(a, b) {
                    swapLog.append(SwapPair(a: a, b: b))
                }
            }
            pendingPairs.removeFirst(take)
            swapsThisTick += take
        }
        renderCurrentState()
    }

    /// Shear sort phases: alternating row-sorts and column-sorts, log₂(n)+1
    /// rounds of each. Rows are sorted in snake order (even rows ascending,
    /// odd rows descending) so the final column-sort converges to a clean
    /// gradient. `queueNextPhase` lays down all (a,b) comparison pairs for
    /// one odd-or-even subpass and returns false when we've run the full
    /// shear-sort schedule.
    private func queueNextPhase() -> Bool {
        let n = gridSize
        let totalRounds = Int(ceil(log2(Double(n)))) + 1
        // Each round = row-odd, row-even, col-odd, col-even  (4 subpasses)
        let totalSubpasses = totalRounds * 4
        if phaseIdx >= totalSubpasses { return false }

        let round = phaseIdx / 4
        let kind = phaseIdx % 4
        _ = round
        var pairs: [(Int32, Int32)] = []
        pairs.reserveCapacity(n * n / 2)

        switch kind {
        case 0, 1:
            // Row subpass. kind 0 = even pair start (0,1)(2,3)…,
            //              kind 1 = odd pair start (1,2)(3,4)…
            let startOffset = kind
            for row in 0..<n {
                var col = startOffset
                while col + 1 < n {
                    let a = Int32(row * n + col)
                    let b = Int32(row * n + col + 1)
                    pairs.append((a, b))
                    col += 2
                }
            }
        default:
            // Column subpass. kind 2 = even, kind 3 = odd.
            let startOffset = kind - 2
            for col in 0..<n {
                var row = startOffset
                while row + 1 < n {
                    let a = Int32(row * n + col)
                    let b = Int32((row + 1) * n + col)
                    pairs.append((a, b))
                    row += 2
                }
            }
        }

        pendingPairs = pairs
        phaseIdx += 1
        return true
    }

    /// Returns true if the pair was actually swapped (so the caller can
    /// record it to the log). Uses the sort key of whichever original
    /// pixel currently sits at each position.
    private func compareAndSwap(_ a: Int32, _ b: Int32) -> Bool {
        let origA = Int(perm[Int(a)])
        let origB = Int(perm[Int(b)])
        let lumA = luminance[origA]
        let lumB = luminance[origB]

        // Snake order on row subpasses: odd rows sort DESCENDING so that
        // when we do the column pass, every column already has its
        // smallest value at the top. This is what makes shear sort
        // converge. `a` and `b` are adjacent within a row (row subpass)
        // or adjacent within a column (column subpass); work out which.
        let n = gridSize
        let rowA = Int(a) / n
        let rowB = Int(b) / n
        let isRowSubpass = rowA == rowB
        let ascending: Bool
        if isRowSubpass {
            ascending = (rowA % 2 == 0)
        } else {
            ascending = true
        }

        let outOfOrder = ascending ? (lumA > lumB) : (lumA < lumB)
        if outOfOrder {
            perm.swapAt(Int(a), Int(b))
            return true
        }
        return false
    }

    // MARK: - Reverse

    private func beginRevert() {
        reverseCursor = swapLog.count - 1
        mode = .reverting
        startDisplayLink()
    }

    private func advanceRevert() {
        var applied = 0
        while applied < reverseSwapsPerTick && reverseCursor >= 0 {
            let entry = swapLog[reverseCursor]
            perm.swapAt(Int(entry.a), Int(entry.b))
            reverseCursor -= 1
            applied += 1
        }
        renderCurrentState()

        if reverseCursor < 0 {
            stopDisplayLink()
            swapLog.removeAll(keepingCapacity: false)
            perm.removeAll(keepingCapacity: false)
            sourceColors.removeAll(keepingCapacity: false)
            luminance.removeAll(keepingCapacity: false)
            renderedImage = nil
            mode = .idle
        }
    }

    // MARK: - Rendering

    private func renderCurrentState() {
        guard !sourceColors.isEmpty else { return }
        let n = gridSize
        var pixelBuffer = [UInt32](repeating: 0, count: n * n)
        pixelBuffer.withUnsafeMutableBufferPointer { dest in
            perm.withUnsafeBufferPointer { pPtr in
                sourceColors.withUnsafeBufferPointer { srcPtr in
                    for i in 0..<(n * n) {
                        dest[i] = srcPtr[Int(pPtr[i])]
                    }
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // UInt32 pixel layout is RGBA8 little-endian (R in low byte),
        // which matches `.byteOrder32Little | .premultipliedLast` in
        // CoreGraphics parlance.
        let bitmapInfo: UInt32 =
            CGImageAlphaInfo.premultipliedLast.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = pixelBuffer.withUnsafeMutableBytes({ raw -> CGContext? in
            guard let base = raw.baseAddress else { return nil }
            return CGContext(
                data: base,
                width: n,
                height: n,
                bitsPerComponent: 8,
                bytesPerRow: n * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )
        }) else { return }

        guard let cg = context.makeImage() else { return }
        renderedImage = UIImage(cgImage: cg)
    }

    // MARK: - Downsampling

    /// Draws the source image into an N×N RGBA buffer and pulls out
    /// colors + luminance. Running on a background task keeps the first
    /// tap from stuttering on large cover photos.
    nonisolated private static func downsample(
        _ image: UIImage,
        to gridSize: Int
    ) -> (colors: [UInt32], luminance: [Float]) {
        let n = gridSize
        var buffer = [UInt32](repeating: 0, count: n * n)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 =
            CGImageAlphaInfo.premultipliedLast.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue

        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base,
                    width: n,
                    height: n,
                    bitsPerComponent: 8,
                    bytesPerRow: n * 4,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ),
                  let cg = image.cgImage else {
                return
            }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        }

        var lumas = [Float](repeating: 0, count: n * n)
        for i in 0..<(n * n) {
            let px = buffer[i]
            let r = Float((px >> 0) & 0xff)
            let g = Float((px >> 8) & 0xff)
            let b = Float((px >> 16) & 0xff)
            // Rec. 709 luminance — the standard for "how bright does
            // this pixel read to a human." Using this (vs. a flat RGB
            // average) keeps colored bands from collapsing into each
            // other in a way that looks wrong.
            lumas[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        return (buffer, lumas)
    }

    // MARK: - Display link

    private func startDisplayLink() {
        tearDownDisplayLink()
        let target = DisplayLinkTarget { [self] in tick() }
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.fire))
        link.add(to: .main, forMode: .common)
        self.linkTarget = target
        self.displayLink = link
    }

    private func stopDisplayLink() {
        tearDownDisplayLink()
    }

    private func tearDownDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        linkTarget = nil
    }

    private func tick() {
        switch mode {
        case .sorting: advanceSort()
        case .reverting: advanceRevert()
        case .idle, .sorted, .pausedMidSort, .pausedMidRevert:
            // Paused / terminal states — nothing to advance, and the
            // display link should already be stopped. Belt-and-suspenders.
            stopDisplayLink()
        }
    }
}

/// Fixed-size swap record. `Int32` is enough for any sensible grid size
/// and keeps the log at 8 bytes per entry.
private struct SwapPair {
    let a: Int32
    let b: Int32
}

/// CADisplayLink needs an `@objc` target; wrap the Swift closure so the
/// SwiftUI view doesn't have to be an NSObject.
private final class DisplayLinkTarget: NSObject {
    let callback: () -> Void
    init(callback: @escaping () -> Void) {
        self.callback = callback
    }
    @objc func fire() { callback() }
}
