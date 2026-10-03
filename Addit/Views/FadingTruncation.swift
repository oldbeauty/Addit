import SwiftUI

/// A view modifier that replaces SwiftUI's ellipsis truncation with a trailing
/// fade-out when a single-line `Text` can't fit its full content.
///
/// Usage: `Text("…").fadingTruncation()`
///
/// Implementation notes:
/// - The line is laid out at its natural width, `fixedSize` so SwiftUI never
///   inserts the "…": the glyphs render in full and the cut is a clip.
/// - `ViewThatFits` picks, in the layout pass itself, between the line as it
///   is — when it fits, placed by `alignment` — and the line clipped to the
///   width it's offered with its trailing `fadeWidth` points faded.
/// - Only an overflowing line pays for `.mask`. A mask forces the masked
///   subtree into an offscreen pass, and this modifier is on both labels of
///   every album card: a screen of them was paying for a dozen offscreen
///   passes a frame to fade text that mostly fits, which draws identically
///   without one.
/// - Nothing is measured into state. The first version clipped inside a
///   scroll-disabled horizontal `ScrollView` and found the overflow with two
///   `GeometryReader`s writing `@State` — a `UIScrollView` per line, and a
///   second update pass for every label just after it appeared. That's two of
///   each per card, so every folder opening built a handful of scroll views
///   and laid its panel out twice, on the frames the folder starts moving.
extension View {
    func fadingTruncation(
        fadeWidth: CGFloat = 18,
        alignment: Alignment = .leading
    ) -> some View {
        modifier(FadingTruncationModifier(fadeWidth: fadeWidth, alignment: alignment))
    }
}

private struct FadingTruncationModifier: ViewModifier {
    let fadeWidth: CGFloat
    let alignment: Alignment

    func body(content: Content) -> some View {
        let line = content
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        ViewThatFits(in: .horizontal) {
            // Half a point of slack, so a line exactly the container's width
            // doesn't land on the faded side of the choice by rounding.
            NaturalWidthLine(alignment: alignment.horizontal, slack: 0.5) { line }
            NaturalWidthLine(alignment: .leading, slack: 0) { line }
                .mask {
                    HStack(spacing: 0) {
                        Rectangle().fill(.black)
                        LinearGradient(
                            colors: [.black, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: fadeWidth)
                    }
                }
        }
    }
}

/// One line at its natural width, placed by `alignment` inside the width it's
/// offered — and that offered width is the one it reports, so a line too long
/// for its room runs off the trailing edge (for the mask to cut) rather than
/// pushing the room wider. Asked for its ideal width, as `ViewThatFits` asks,
/// it answers the line's less `slack`.
private struct NaturalWidthLine: Layout {
    var alignment: HorizontalAlignment
    var slack: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(
            width: proposal.width ?? max(0, natural.width - slack),
            height: natural.height
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let line = subviews.first else { return }
        let width = line.sizeThatFits(.unspecified).width
        let x: CGFloat = switch alignment {
        case .center: bounds.midX - width / 2
        case .trailing: bounds.maxX - width
        default: bounds.minX
        }
        line.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: .unspecified)
    }
}

/// The multi-line counterpart to `fadingTruncation`: text clamped to a number
/// of lines whose overflow **fades out** instead of ending in an ellipsis.
///
/// Why it isn't the modifier above. That one clips a single line and fades the
/// trailing edge of the whole thing, which works precisely because there is
/// only ever one line. Fade the trailing
/// edge of a two-line block and you fade the end of the *first* line too — and
/// a line that wrapped is by definition running right up to the edge, so what
/// you get is a title that appears to be cut in the middle of a perfectly
/// intact word.
///
/// So the fade is confined to the last line's band, and applied only when the
/// clamp actually cut something. Both of those need measuring:
///
/// - **Was anything cut?** A hidden copy of the same text, at the same width
///   with no line limit, gives the height the text *wanted*. Taller than the
///   clamped one means there is more text than is showing. Without this test a
///   centered line that merely came close to the edge would be faded for no
///   reason, since a centered short line can end well inside the fade's reach.
/// - **Where is the last line?** The clamped height divided by the line count.
///   When the text is cut, the clamp is by definition full, so that division is
///   exact rather than an estimate.
///
/// The ellipsis is still generated — `Text` gives no way to refuse one — and is
/// hidden by the fade rather than removed: it sits at the very end of the line,
/// which the gradient has taken to fully transparent well before its own edge.
/// That's what `fadeWidth` and the 0.55 stop are for, and why the fade is wider
/// than the single-line one.
struct FadingClampedText: View {
    let text: String
    let font: Font
    /// Lines to show before cutting.
    var lines: Int = 1
    var alignment: TextAlignment = .center
    /// Width of the fade in points. Wide enough that the last third of it —
    /// where the ellipsis lives — is completely clear.
    var fadeWidth: CGFloat = 46

    /// Height as drawn, and height the text would have taken unclamped.
    @State private var clampedHeight: CGFloat = 0
    @State private var naturalHeight: CGFloat = 0

    private var isTruncated: Bool {
        clampedHeight > 0 && naturalHeight > clampedHeight + 0.5
    }

    var body: some View {
        Text(text)
            .font(font)
            .multilineTextAlignment(alignment)
            .lineLimit(lines)
            .background(heightReader { clampedHeight = $0 })
            .background(alignment: .top) { ruler }
            .modifier(
                LastLineFade(
                    isActive: isTruncated,
                    bandHeight: clampedHeight / CGFloat(max(lines, 1)),
                    fadeWidth: fadeWidth
                )
            )
    }

    /// The same text, same width, no line limit — and never drawn. Anchored to
    /// the top of a background so that being taller than what it measures
    /// against costs nothing: a background is laid out inside its parent's
    /// frame and reports nothing back up.
    private var ruler: some View {
        Text(text)
            .font(font)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .background(heightReader { naturalHeight = $0 })
    }

    private func heightReader(_ store: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { store(geo.size.height) }
                .onChange(of: geo.size.height) { _, new in store(new) }
        }
    }
}

/// Fades the trailing end of the bottom `bandHeight` of a view, or does nothing
/// at all — same reasoning as `fadingTruncation`'s, a mask that draws everything
/// through still costs the offscreen pass.
private struct LastLineFade: ViewModifier {
    let isActive: Bool
    let bandHeight: CGFloat
    let fadeWidth: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive, bandHeight > 0 {
            content.mask(
                VStack(spacing: 0) {
                    // Every line but the last, untouched.
                    Rectangle().fill(.black)

                    HStack(spacing: 0) {
                        Rectangle().fill(.black)
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .clear, location: 0.55),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: fadeWidth)
                    }
                    .frame(height: bandHeight)
                }
            )
        } else {
            content
        }
    }
}
