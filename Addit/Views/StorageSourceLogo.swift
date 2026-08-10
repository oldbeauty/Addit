import SwiftUI

/// Compact brand mark for a storage source, as a solid piece of glass — the
/// library selector's collapsed label shows this instead of a text title.
///
/// The mark itself is `GlassLogo.metal`; this view only decides how it is
/// turned and how much room it takes up. Face-on it is the flat logo, so the
/// selector still reads at a glance; the scroll turns it far enough to show
/// that it has a back, and no further.
struct StorageSourceLogo: View {
    let source: StorageSource
    /// Content offset of the library's list or grid. Left at zero the mark
    /// simply sits face-on, which is what any non-scrolling caller wants.
    var scrollOffset: CGFloat = 0
    /// Multiplies both the canvas and the footprint. A plain `scaleEffect`
    /// would blow up the rendered pixels; this re-marches at the larger size,
    /// so a big mark is actually sharp.
    var scale: CGFloat = 1

    /// Radians of phase per point scrolled — about a screen and a half per
    /// full rock.
    private static let radiansPerPoint: Double = 0.0085
    /// Yaw is a *rock*, not a spin, and this is the whole difference between
    /// this and the orb. Position-driven rotation that keeps going would put
    /// the mark edge-on for a good part of every scroll, and a selector that
    /// periodically becomes an unreadable sliver is a worse selector. Running
    /// the same offset through a sine keeps every bit of the tie to the
    /// gesture — the same tracking, the same coast to a stop — while never
    /// turning past the angle where the mark still names itself.
    private static let maxYaw: Double = 0.70            // ~40°
    /// A little pitch as well, at half the rate so the two never quite line up
    /// and the motion doesn't read as a mechanism.
    private static let maxPitch: Double = 0.16          // ~9°
    /// Far less twist than the orb takes: enough to see the glass is soft,
    /// not enough to bend the mark out of shape.
    private static let maxTwist: Double = 0.55

    var body: some View {
        let phase = Double(scrollOffset) * Self.radiansPerPoint

        ScrollTorque(scrollOffset: scrollOffset, maxTwist: Self.maxTwist) { twist in
            Rectangle()
                .fill(.white)
                .frame(width: canvas, height: canvas)
                .colorEffect(
                    ShaderLibrary.glassLogo(
                        .float2(canvas, canvas),
                        .float(Self.maxYaw * sin(phase)),
                        .float(Self.maxPitch * sin(phase * 0.5 + 1.1)),
                        .float(twist),
                        .float(shapeId)
                    )
                )
        }
        .frame(width: canvas, height: canvas)
        // Two frames on purpose. The inner one is the canvas the shader needs:
        // square, and roomy enough that a mark turning inside it never touches
        // the edge. The outer one is the space the mark actually *occupies*, so
        // the selector capsule stays as tight around it as it was around the
        // flat artwork — the spare canvas is transparent and simply overhangs.
        .frame(width: footprint.width, height: footprint.height)
        .accessibilityLabel(name)
    }

    private var shapeId: Float {
        switch source {
        case .googleDrive: 0
        case .oneDrive: 1
        case .localStorage: 2
        }
    }

    /// Side of the square the shader draws into.
    private var canvas: CGFloat {
        let side: CGFloat = switch source {
        case .googleDrive: 25
        case .oneDrive: 26
        case .localStorage: 24
        }
        return side * scale
    }

    /// What the mark measures inside that canvas, which is what the layout is
    /// told about. Matched to the sizes the flat artwork used, per mark — the
    /// wide OneDrive cloud reads bigger than its box at equal height.
    private var footprint: CGSize {
        let size: CGSize = switch source {
        case .googleDrive: CGSize(width: 19, height: 17)
        case .oneDrive: CGSize(width: 22, height: 13)
        case .localStorage: CGSize(width: 17, height: 12)
        }
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private var name: String {
        switch source {
        case .googleDrive: "Google Drive"
        case .oneDrive: "OneDrive"
        case .localStorage: "Local Library"
        }
    }
}

#Preview("Marks") {
    @Previewable @State var offset: CGFloat = 0

    VStack(spacing: 36) {
        HStack(spacing: 28) {
            ForEach([StorageSource.googleDrive, .oneDrive, .localStorage], id: \.self) { source in
                StorageSourceLogo(source: source, scrollOffset: offset, scale: 5)
            }
        }
        HStack(spacing: 14) {
            ForEach([StorageSource.googleDrive, .oneDrive, .localStorage], id: \.self) { source in
                HStack(spacing: 6) {
                    StorageSourceLogo(source: source, scrollOffset: offset)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
            }
        }
        Slider(value: $offset, in: -600...600)
    }
    .padding(40)
    .background(Color(red: 0.06, green: 0.06, blue: 0.07))
}
