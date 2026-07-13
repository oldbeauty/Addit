import SwiftUI

/// A raised, physical push-button in the same debossed-crater visual language
/// as the album cover mount: a rounded/circular plate extruded off the surface
/// with a top rim highlight and a drop + contact shadow, that visibly *presses
/// in* (shadows invert to an inner shadow, the part sinks and scales down) when
/// held. Teenage-Engineering-flavored — hard edges, precise, tactile.
struct TactileButtonStyle: ButtonStyle {
    /// When set, the button reads as "engaged" — the plate fills with this
    /// color instead of the neutral surface (e.g. shuffle while active).
    var engaged: Color? = nil
    var diameter: CGFloat = 56

    func makeBody(configuration: Configuration) -> some View {
        Plate(configuration: configuration, engaged: engaged, diameter: diameter)
    }

    private struct Plate: View {
        let configuration: Configuration
        let engaged: Color?
        let diameter: CGFloat

        var body: some View {
            let pressed = configuration.isPressed
            // Cap sits a touch lighter than the socket so its top catches the
            // top-down light and reads as raised out of the surface.
            let cap = engaged ?? Color(uiColor: .tertiarySystemBackground)

            ZStack {
                // Recessed socket the cap emerges from — same debossed carve
                // as the album crater, so the button looks seated *in* the
                // surface rather than floating above it.
                Circle()
                    .fill(
                        Color(uiColor: .secondarySystemBackground)
                            .shadow(.inner(color: .black.opacity(0.6), radius: 4, x: 0, y: 2))
                            .shadow(.inner(color: .white.opacity(0.05), radius: 1, x: 0, y: -1))
                    )
                    .frame(width: diameter + 14, height: diameter + 14)

                // Raised cap.
                configuration.label
                    .font(.ui(20, weight: .semibold))
                    .frame(width: diameter, height: diameter)
                    .background {
                        Circle()
                            .fill(
                                pressed
                                    ? AnyShapeStyle(cap.shadow(.inner(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)))
                                    : AnyShapeStyle(cap)
                            )
                            .overlay {
                                // Rim: bright top lip, dark bottom — sells the
                                // machined edge; stays put when pressed.
                                Circle()
                                    .strokeBorder(
                                        LinearGradient(
                                            colors: [.white.opacity(0.18), .clear, .black.opacity(0.32)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        ),
                                        lineWidth: 1
                                    )
                            }
                    }
                    // Tight contact shadow only — grounds the cap to the socket
                    // instead of the big diffuse shadow that read as floating.
                    // It tucks in as the cap presses down into the socket.
                    .shadow(color: .black.opacity(pressed ? 0.2 : 0.5), radius: pressed ? 1 : 3, x: 0, y: pressed ? 0.5 : 2)
                    .scaleEffect(pressed ? 0.94 : 1)
                    .animation(.spring(response: 0.22, dampingFraction: 0.6), value: pressed)
            }
        }
    }
}

extension View {
    /// Debossed / letterpress text — reads as engraved into the faceplate.
    /// A dark shadow rides the top edge of each glyph (in shadow, as if
    /// recessed) while a brighter highlight catches the bottom lip under the
    /// same top-down light as the crater and buttons. Two crisp, offset,
    /// zero-blur shadows are what make it read as *carved* rather than just
    /// "text with a drop shadow."
    func engraved() -> some View {
        shadow(color: .black.opacity(0.55), radius: 0, x: 0, y: -1)
            .shadow(color: .white.opacity(0.22), radius: 0, x: 0, y: 1)
    }
}
