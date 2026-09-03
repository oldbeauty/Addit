import SwiftUI
import UIKit
import CoreMotion

/// "Phosphor" — Addit's design-language kit. The app is a physical
/// instrument, and every UI element belongs to one of three layers:
///
///   1. CHASSIS — the matte machined faceplate: wells, sockets, engraved
///      labels. Lives in `TactileControls.swift`. Uses the user's accent.
///   2. DISPLAYS — anywhere data lives (durations, meters, playheads,
///      numbers) is a pixel/LED readout inset into the chassis. Always
///      ice-cyan (this file), never the user accent — the instrument's
///      own light. Motion on this layer is quantized (ticks at grid
///      resolution), never smoothly eased.
///   3. GLASS — transient floating surfaces as edge-lit light planes.
///      Only for surfaces we fully control; system sheets keep their
///      frame. (To come.)
enum Phosphor {
    /// The display identity color — fixed regardless of user accent.
    /// Bright ice in dark mode; a deep cyan ink in light mode where a
    /// luminous color would be illegible.
    static let lit = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.66, green: 0.89, blue: 1.00, alpha: 1) // #A8E4FF
            : UIColor(red: 0.05, green: 0.42, blue: 0.58, alpha: 1) // #0D6B94
    })

    /// Secondary readout level — present but not emphasized.
    static var dim: Color { lit.opacity(0.55) }

    /// Faint traces: gridlines, unlit-but-implied structure.
    static var ghost: Color { lit.opacity(0.22) }
}

// MARK: - Typography

extension Font {
    /// THE app-family knob. The entire app's UI type routes through the
    /// `ui*` accessors below, so changing the default font = changing this
    /// one string to a bundled font's PostScript family name (+ adding the
    /// file to the target and `UIAppFonts`). `nil` = system SF.
    /// Readout type (`Font.readout`) is separate and stays bitmap.
    ///
    /// Currently bundled, so each is a one-word swap here:
    /// - `"Space Grotesk"` — proportional cut of Space Mono. Regular/Medium/
    ///   Bold only: the family has **no SemiBold** in any official build
    ///   (Google Fonts ships only the variable), so `uiHeadline`'s `.semibold`
    ///   resolves to the nearest cut rather than a drawn one.
    /// - `"BDO Grotesk"` — neo-grotesque. Regular/Medium/DemiBold/Bold, so it
    ///   does have a real semibold-weight cut.
    /// - `"Geist"` — Regular/Medium/SemiBold/Bold.
    /// - `"Inter"` — the current default. Regular/Medium/SemiBold/Bold, the
    ///   static cuts from the upstream 4.1 release rather than Google Fonts',
    ///   whose statics are named per optical size (`Inter 18pt`) and would not
    ///   answer to this family string.
    static let appFamily: String? = "Inter"

    /// Fixed-size UI font in the app family.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard let family = appFamily else { return .system(size: size, weight: weight) }
        return .custom(family, size: size).weight(weight)
    }

    // Semantic tiers. With `appFamily == nil` these are EXACTLY Apple's
    // text styles; with a family set, they use Apple's default sizes and
    // scale `relativeTo` the same style so Dynamic Type keeps working.
    static var uiLargeTitle: Font { appFamily.map { .custom($0, size: 34, relativeTo: .largeTitle) } ?? .largeTitle }
    static var uiTitle: Font { appFamily.map { .custom($0, size: 28, relativeTo: .title) } ?? .title }
    static var uiTitle2: Font { appFamily.map { .custom($0, size: 22, relativeTo: .title2) } ?? .title2 }
    static var uiTitle3: Font { appFamily.map { .custom($0, size: 20, relativeTo: .title3) } ?? .title3 }
    static var uiHeadline: Font { appFamily.map { .custom($0, size: 17, relativeTo: .headline).weight(.semibold) } ?? .headline }
    static var uiBody: Font { appFamily.map { .custom($0, size: 17, relativeTo: .body) } ?? .body }
    static var uiCallout: Font { appFamily.map { .custom($0, size: 16, relativeTo: .callout) } ?? .callout }
    static var uiSubheadline: Font { appFamily.map { .custom($0, size: 15, relativeTo: .subheadline) } ?? .subheadline }
    static var uiFootnote: Font { appFamily.map { .custom($0, size: 13, relativeTo: .footnote) } ?? .footnote }
    static var uiCaption: Font { appFamily.map { .custom($0, size: 12, relativeTo: .caption) } ?? .caption }
    static var uiCaption2: Font { appFamily.map { .custom($0, size: 11, relativeTo: .caption2) } ?? .caption2 }
}

extension Font {
    /// True once the Departure Mono bitmap font is bundled (add the .otf to
    /// the app target + `UIAppFonts` in Info.plist); checked once.
    private static let departureMonoAvailable: Bool =
        UIFont(name: "DepartureMono-Regular", size: 12) != nil

    /// Readout typography for the display layer: durations, track numbers,
    /// counters, badges. Bitmap pixel font when bundled, monospaced SF
    /// fallback until then. Titles and prose stay SF.
    static func readout(_ size: CGFloat) -> Font {
        departureMonoAvailable
            ? .custom("DepartureMono-Regular", size: size)
            : .system(size: size, weight: .medium, design: .monospaced)
    }
}

/// Tight phosphor bloom for lit display elements — enough to read as
/// emitted light, well short of CRT kitsch. No-op in light mode (glow on a
/// white surface reads as smudge, and the light-mode ink isn't luminous).
private struct PhosphorGlow: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let color: Color
    let intensity: Double

    func body(content: Content) -> some View {
        content
            .shadow(color: scheme == .dark ? color.opacity(0.70 * intensity) : .clear, radius: 1.5)
            .shadow(color: scheme == .dark ? color.opacity(0.30 * intensity) : .clear, radius: 5)
    }
}

extension View {
    /// Apply the display layer's emitted-light bloom. `intensity` scales
    /// both halos; 1.0 for primary readouts, ~0.5 for secondary ones.
    func phosphorGlow(_ color: Color = Phosphor.lit, intensity: Double = 1) -> some View {
        modifier(PhosphorGlow(color: color, intensity: intensity))
    }

    /// GLASS layer: an edge-lit floating pane — our replacement for stock
    /// liquid glass on surfaces we fully control. System blur is the
    /// substrate, but the identity is the ice edge-light: a rim that's
    /// brightest along the top (light entering the pane), a darkened tint
    /// so content reads over anything, a deep drop shadow, and a faint
    /// ambient ice spill in dark mode.
    func glassPane(cornerRadius: CGFloat = 16) -> some View {
        modifier(PhosphorGlassPane(cornerRadius: cornerRadius))
    }
}

// MARK: - Press feedback

/// CHASSIS layer: the card sinks under a finger and comes back as it lifts.
///
/// Uses `ButtonStyle`'s own press state deliberately. It's the one mechanism
/// that already knows the difference between a press and the start of a
/// scroll, so it stays out of the way of a scrolling grid — hand-rolled press
/// tracking with a `DragGesture` per cell claims touches the scroll view
/// needs, and the grid stops scrolling properly.
///
/// **Attach to a `Button`, not a `NavigationLink`** — a link doesn't surface
/// press state to a custom style, so the effect silently never renders.
///
/// Timings are short on both sides: the point is to feel like the card
/// answered the finger, not to play an animation at the user before their tap
/// is allowed through. Nothing here gates the action.
struct ImprintButtonStyle: ButtonStyle {
    /// How far it sinks. Shallow on purpose — at a full grid of covers, a deep
    /// press reads as the whole page flinching.
    var pressedScale: CGFloat = 0.93

    /// Shortest time the imprint stays on screen, measured from touch-down.
    ///
    /// Without a floor, the imprint is only as long as the touch: flick a
    /// finger at a card for 40ms and the sink animation gets a third of the
    /// way down before reversing, which reads as nothing happening. A press
    /// held longer than this releases the moment the finger lifts — the floor
    /// only ever extends a tap that was too brief to see.
    var minimumDwell: TimeInterval = 0.13

    func makeBody(configuration: Configuration) -> some View {
        Imprint(
            configuration: configuration,
            pressedScale: pressedScale,
            minimumDwell: minimumDwell
        )
    }

    /// A `View`, not inline in `makeBody`, because holding the sink past the
    /// end of the touch needs state of its own — `configuration.isPressed`
    /// reports the finger, and what's wanted is the finger *plus* a floor.
    private struct Imprint: View {
        let configuration: Configuration
        let pressedScale: CGFloat
        let minimumDwell: TimeInterval

        @State private var isSunk = false
        @State private var pressedAt: Date?
        @State private var release: Task<Void, Never>?

        var body: some View {
            configuration.label
                // Resolve the label's geometry as one unit, or a child that
                // re-renders mid-press resolves independently and skips the
                // animation. A library card is exactly that case: its artwork
                // carries `GlassRim`, whose specular angle follows
                // `MotionShine`, so the cover's branch invalidates as the
                // device tilts while the title's never does. That's why the
                // title would sink and the cover — sometimes, depending on
                // whether a gyro update landed inside the press — would not.
                .geometryGroup()
                .scaleEffect(isSunk ? pressedScale : 1)
                .animation(.easeOut(duration: isSunk ? 0.08 : 0.16), value: isSunk)
                .onChange(of: configuration.isPressed) { _, isPressed in
                    release?.cancel()

                    guard !isPressed else {
                        pressedAt = .now
                        isSunk = true
                        return
                    }

                    // Only the *remainder* of the floor — a press that already
                    // outlasted it lifts immediately, so holding never feels
                    // like it sticks.
                    let held = pressedAt.map { Date().timeIntervalSince($0) } ?? minimumDwell
                    let remaining = minimumDwell - held
                    guard remaining > 0 else {
                        isSunk = false
                        return
                    }
                    release = Task {
                        try? await Task.sleep(for: .seconds(remaining))
                        guard !Task.isCancelled else { return }
                        isSunk = false
                    }
                }
        }
    }
}

// MARK: - Glass rim (gyro-reactive hairline)

/// Shared device-attitude source for gyro-reactive UI. One `CMMotionManager`
/// app-wide (Apple's guidance), refcounted by subscribing views and stopped
/// when the last one disappears. A UI-lifecycle singleton rather than an
/// injected service — it has no app state, it's a sensor tap.
///
/// Publishes the gravity vector's screen-plane components, quantized (~1°)
/// so subscribers only re-render on visible changes rather than at the raw
/// 30 Hz update rate.
@Observable
final class MotionShine {
    static let shared = MotionShine()

    /// Screen-plane gravity in the device frame; (0, -1) = phone upright,
    /// which puts the shine at the top edge. Defaults double as the static
    /// fallback wherever motion is unavailable (Simulator, Reduce Motion).
    private(set) var gravityX: Double = 0
    private(set) var gravityY: Double = -1

    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var consumers = 0

    func addConsumer() {
        consumers += 1
        guard consumers == 1, manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let g = motion?.gravity else { return }
            let qx = (g.x * 64).rounded() / 64
            let qy = (g.y * 64).rounded() / 64
            if qx != gravityX { gravityX = qx }
            if qy != gravityY { gravityY = qy }
        }
    }

    func removeConsumer() {
        consumers = max(0, consumers - 1)
        if consumers == 0 { manager.stopDeviceMotionUpdates() }
    }
}

/// The "glass edge" hairline for floating artwork and panels: a barely-there
/// rim (so covers with dark edges separate from the background) plus a
/// specular highlight that slides around that rim with device tilt — the
/// light source stays fixed overhead in world space while the phone moves
/// under it, the way Apple's app icons shine.
///
/// Every rim gets the moving lobe, in both schemes, but the two schemes are
/// lit differently and it is worth knowing which half does the work. Dark
/// mode is carried by the bright lobe, and puts a second, weaker one opposite
/// it — glow wrapping around the far edge of a lit object floating in the
/// dark. Light mode replaces that far-edge glow with a soft *occlusion*: on a
/// bright ground the far edge turns away from the light rather than catching
/// it, and drawing the wrap-around there would flatten the bevel it is meant
/// to describe.
///
/// That occlusion is also what keeps the effect alive over a pale ground. The
/// white lobe needs something mid-toned under it to register, which artwork
/// supplies and the near-white page does not — so on the play button in light
/// mode it is the travelling *shadow*, not the highlight, that you actually
/// see going round. The rim was originally written to sit out light mode
/// entirely for that reason; the shaded half is the part that survives there,
/// and it turns out to be enough.
struct GlassRim<S: InsettableShape>: View {
    var shape: S
    var lineWidth: CGFloat = 1

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var subscribed = false
    private let motion = MotionShine.shared

    var body: some View {
        ZStack {
            // Base hairline — the always-there thin border.
            shape.strokeBorder(
                scheme == .dark
                    ? Color.white.opacity(0.12)
                    : Color.black.opacity(0.07),
                lineWidth: lineWidth
            )

            // Specular lobe, rotated to stay under the world's light.
            shape.strokeBorder(
                AngularGradient(
                    stops: scheme == .dark ? darkStops : lightStops,
                    center: .center,
                    angle: shineAngle
                ),
                lineWidth: lineWidth
            )

            // Light mode only: the edge rolling away from the light.
            if scheme != .dark {
                shape.strokeBorder(
                    AngularGradient(
                        stops: occlusionStops,
                        center: .center,
                        angle: shineAngle
                    ),
                    lineWidth: lineWidth
                )
            }
        }
        .allowsHitTesting(false)
        .onAppear { syncMotion(to: true) }
        .onDisappear { syncMotion(to: false) }
    }

    /// Dark mode: a bright lobe under the light and a weaker one wrapping to
    /// the far edge, with the rim nearly extinguished on the two flanks.
    private var darkStops: [Gradient.Stop] {
        [
            .init(color: .white.opacity(0.55), location: 0),
            .init(color: .white.opacity(0.06), location: 0.18),
            .init(color: .white.opacity(0.02), location: 0.36),
            .init(color: .white.opacity(0.18), location: 0.5),
            .init(color: .white.opacity(0.02), location: 0.64),
            .init(color: .white.opacity(0.06), location: 0.82),
            .init(color: .white.opacity(0.55), location: 1),
        ]
    }

    /// Light mode: a brighter, tighter lobe that falls to nothing well before
    /// the flanks. It has to out-run a pale ground to register at all, and
    /// keeping it narrow is what stops the leftovers reading as grime on the
    /// parts of the rim the light isn't hitting.
    private var lightStops: [Gradient.Stop] {
        [
            .init(color: .white.opacity(0.70), location: 0),
            .init(color: .white.opacity(0.16), location: 0.12),
            .init(color: .white.opacity(0), location: 0.28),
            .init(color: .white.opacity(0), location: 0.72),
            .init(color: .white.opacity(0.16), location: 0.88),
            .init(color: .white.opacity(0.70), location: 1),
        ]
    }

    /// The shaded half, opposite the lobe: a wide, shallow darkening that
    /// deepens the base hairline where the edge faces away. Drawn as its own
    /// pass rather than as black stops in `lightStops`, because interpolating
    /// white through `.clear` to black dirties the falloff between them.
    private var occlusionStops: [Gradient.Stop] {
        [
            .init(color: .black.opacity(0), location: 0.22),
            .init(color: .black.opacity(0.08), location: 0.5),
            .init(color: .black.opacity(0), location: 0.78),
        ]
    }

    /// Angular position of the bright lobe. The gradient's 0-location sits
    /// at SwiftUI's 3-o'clock; -90° puts it at the top when upright, and
    /// `atan2(-gx, -gy)` swings it toward whichever screen edge currently
    /// faces up in the world as the device tilts.
    private var shineAngle: Angle {
        if reduceMotion { return .degrees(-90) }
        return .degrees(-90) + .radians(atan2(-motion.gravityX, -motion.gravityY))
    }

    /// Hold a gyro subscription exactly while this rim is on screen. Routed
    /// through one funnel with its own flag rather than calling the shared
    /// counter directly, so a repeated `onAppear` — or an `onDisappear` for a
    /// subscription Reduce Motion meant we never took — can't leak a consumer
    /// or release one twice, either of which desyncs that counter and stops
    /// the shine for every other rim on screen.
    private func syncMotion(to want: Bool) {
        let want = want && !reduceMotion
        guard want != subscribed else { return }
        subscribed = want
        if want { motion.addConsumer() } else { motion.removeConsumer() }
    }
}

extension GlassRim where S == RoundedRectangle {
    /// The original spelling, for the rounded artwork it was written for.
    init(cornerRadius: CGFloat, lineWidth: CGFloat = 1) {
        self.init(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            lineWidth: lineWidth
        )
    }
}

private struct PhosphorGlassPane: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay {
                        // Deepen the pane in dark mode so it reads as smoked
                        // glass rather than frosted white.
                        shape.fill(Color.black.opacity(scheme == .dark ? 0.30 : 0))
                    }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Phosphor.lit.opacity(0.55),
                            Phosphor.lit.opacity(0.10),
                            Phosphor.lit.opacity(0.22),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 8)
            .shadow(color: scheme == .dark ? Phosphor.lit.opacity(0.10) : .clear, radius: 12)
    }
}
