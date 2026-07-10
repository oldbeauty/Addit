import SwiftUI

/// Spotify-style marquee for a single-line title that may overflow its
/// container. When the text fits, it renders as plain static text (no fades,
/// no motion). When it overflows, it rests truncated with a trailing fade,
/// then slowly scrolls back and forth so the whole title can be read.
///
/// The edge fades are *state indicators*, not decoration — a fade on a side
/// means "there is hidden text in that direction":
///   - at rest at the start: trailing fade only
///   - the moment forward scrolling begins: leading fade joins
///   - arrived at the end: trailing fade drops out (tail fully visible), pause
///   - the moment reverse scrolling begins: trailing fade returns
///   - arrived back at the start: leading fade drops out, pause, repeat
///
/// Font and foreground style are inherited from the environment, so callers
/// style `MarqueeText` exactly like a `Text`. `alignment` only matters when
/// the text fits (e.g. keep a short title centered in the full player).
///
/// Used in the mini player and full player ONLY — album/track lists keep the
/// static `.fadingTruncation()` (a whole list of marquees would be noise).
struct MarqueeText: View {
    let text: String
    var alignment: Alignment = .leading

    var body: some View {
        // `.id(text)` gives each distinct title a brand-new core with virgin
        // state. This is the crux of correctness across track changes: the
        // old title's scroll offset, fade flags, and — critically — its
        // in-flight animations are all destroyed with the old view, instead
        // of racing an imperative "reset" (task cancellation only lands at
        // the next await, so a cancelled cycle could otherwise still fire
        // one last stale withAnimation after the reset).
        MarqueeCore(text: text, alignment: alignment)
            .id(text)
    }
}

private struct MarqueeCore: View {
    let text: String
    let alignment: Alignment

    /// Matches `fadingTruncation`'s fade so rest state looks identical.
    private let fadeWidth: CGFloat = 18
    private let pointsPerSecond: CGFloat = 25
    private let endPause: TimeInterval = 1.75
    private let fadeToggle: TimeInterval = 0.2

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offsetX: CGFloat = 0
    @State private var leadingFade = false
    @State private var trailingFade = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }

    /// The offset actually drawn — clamped to the legal range so no
    /// transient state (mid-measurement, mid-restart) can ever fling the
    /// text outside its track. Third layer of defense after fresh identity
    /// and cancellation checks.
    private var renderedOffset: CGFloat { min(0, max(offsetX, -overflow)) }

    var body: some View {
        // Scroll-disabled ScrollView: same trick as `fadingTruncation` — it
        // takes the width the parent offers and clips the oversized text
        // without propagating the intrinsic width back up the layout.
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .onGeometryChange(for: CGFloat.self, of: \.size.width) {
                    textWidth = $0
                }
                // When the text fits, pad out to the container so `alignment`
                // takes effect; when it overflows, the frame grows to the text.
                .frame(minWidth: containerWidth, alignment: alignment)
                .offset(x: renderedOffset)
        }
        .scrollDisabled(true)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) {
            containerWidth = $0
        }
        .mask(fadeMask)
        // Text identity is handled by `.id(text)` above; this only restarts
        // the cycle when the *measurements* change (first layout landing,
        // rotation, bar resize).
        .task(id: "\(Int(textWidth))|\(Int(containerWidth))") {
            await runMarquee()
        }
    }

    /// One gradient whose end-stop colors animate between opaque (no fade)
    /// and clear (fade). Animating stop colors — rather than swapping mask
    /// shapes — is what lets each fade slide in/out smoothly.
    private var fadeMask: some View {
        let w = max(containerWidth, 1)
        let f = min(fadeWidth / w, 0.45)
        return LinearGradient(
            stops: [
                .init(color: .black.opacity(leadingFade ? 0 : 1), location: 0),
                .init(color: .black, location: f),
                .init(color: .black, location: 1 - f),
                .init(color: .black.opacity(trailingFade ? 0 : 1), location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func runMarquee() async {
        // Reset instantly (no animation). Runs on every measurement-keyed
        // restart; a fresh core (new title) starts here too, with zeroed state.
        withTransaction(Transaction(animation: nil)) {
            offsetX = 0
            leadingFade = false
            trailingFade = overflow > 0
        }
        // Don't animate against unsettled measurements — when they land,
        // the task id changes and we run again.
        guard overflow > 0, containerWidth > 0, !reduceMotion else { return }

        let scrollDuration = TimeInterval(overflow / pointsPerSecond)
        do {
            while true {
                try await Task.sleep(for: .seconds(endPause))
                // Cancellation can be flagged while our continuation is
                // already queued — in that window the sleep returns normally,
                // so re-check before EVERY synchronous state write. Without
                // this, a dying cycle can fire one last stale animation on
                // top of the replacement cycle's state.
                try Task.checkCancellation()

                // Forward: the leading fade appears the moment motion starts.
                withAnimation(.easeInOut(duration: fadeToggle)) { leadingFade = true }
                withAnimation(.linear(duration: scrollDuration)) { offsetX = -overflow }
                try await Task.sleep(for: .seconds(scrollDuration))
                try Task.checkCancellation()

                // Arrived at the end: nothing hidden to the right anymore.
                withAnimation(.easeInOut(duration: fadeToggle)) { trailingFade = false }
                try await Task.sleep(for: .seconds(endPause))
                try Task.checkCancellation()

                // Reverse: the trailing fade returns the moment motion starts.
                withAnimation(.easeInOut(duration: fadeToggle)) { trailingFade = true }
                withAnimation(.linear(duration: scrollDuration)) { offsetX = 0 }
                try await Task.sleep(for: .seconds(scrollDuration))
                try Task.checkCancellation()

                // Back at the start: nothing hidden to the left.
                withAnimation(.easeInOut(duration: fadeToggle)) { leadingFade = false }
            }
        } catch {
            // Cancelled — view disappeared or measurements changed; the next
            // `task(id:)` invocation (or a fresh core) resets state itself.
        }
    }
}
