import SwiftUI

/// A view modifier that replaces SwiftUI's ellipsis truncation with a trailing
/// fade-out when a single-line `Text` can't fit its full content.
///
/// Usage: `Text("…").fadingTruncation()`
///
/// Implementation notes:
/// - The text is wrapped in a scroll-disabled horizontal `ScrollView`. That
///   container takes the width the parent offers and clips its content to
///   that width (same cutoff point SwiftUI's built-in truncation would pick)
///   without propagating the oversized intrinsic width back up the layout.
/// - `fixedSize(horizontal: true)` on the inner text prevents SwiftUI from
///   inserting the "…" character — the glyphs render in full and the scroll
///   container does the clipping.
/// - `mask(...)` fades the trailing `fadeWidth` points of whatever is
///   visible. When the text fits, the faded region sits past the last glyph
///   so short strings render cleanly with no visible fade.
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
    @State private var containerWidth: CGFloat = 0

    func body(content: Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                // When the text is shorter than the container, `minWidth`
                // pads the frame out to the container width so the specified
                // alignment takes effect (e.g. centered text stays centered).
                // When the text is longer, the frame grows to fit the text
                // and the ScrollView clips the trailing overflow.
                .frame(minWidth: containerWidth, alignment: alignment)
        }
        .scrollDisabled(true)
        .mask(
            HStack(spacing: 0) {
                Rectangle().fill(.black)
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: fadeWidth)
            }
        )
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { containerWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, new in
                        containerWidth = new
                    }
            }
        )
    }
}
