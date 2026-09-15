import SwiftUI

/// The screen between launch and the library: the wordmark over a field of
/// pixels rippling like water.
///
/// The mark is `AdditWordmark`, the same one the sign-in screen carries — so
/// the first two screens of a cold launch show the app under one identity
/// instead of two, and the app's name arrives in full on the very first frame
/// it draws for itself.
///
/// Rendered from two places — `AccountContainerView` shows it while the session
/// restores (before `ContentView` exists at all), and `ContentView` shows it
/// during an account switch. It lives here so those two can't drift apart; they
/// were previously separate hand-maintained copies, and they had.
///
/// Full-bleed rather than a panel inset into the chassis, which is what the
/// design language would ask for anywhere else. This surface has no chassis:
/// it's the first thing drawn, it's up for a moment, and the whole screen being
/// the display is the effect. `PixelRippleField` owns everything about it.
struct LoadingSplashView: View {
    /// How long a cold launch holds this on screen, in seconds, *after* there
    /// is nothing left to wait for.
    ///
    /// The value is not a taste call — it's `kDropPeriod` from
    /// `PixelRipple.metal`, the time it takes every drop slot to fire exactly
    /// once. The field starts empty and fills over precisely this long, so
    /// cutting it any shorter shows an unfinished screen and running it longer
    /// starts the field over. Move one and move the other.
    ///
    /// Only the launch applies this (`AccountContainerView`). The account
    /// switch that shows the same view has a real wait behind it and shouldn't
    /// be padded.
    static let launchHold: Double = 2.4

    /// How long the field takes to fade out to black once the hold is up, in
    /// seconds. Slow next to everything else here on purpose: this is the
    /// animation ending, and a quick fade would read as the screen being taken
    /// away rather than as the water going still.
    static let blackoutFade: Double = 0.45

    /// A beat of plain black between the fade landing and the library sliding
    /// in. Short — it's a breath, not a pause — but without it the slide starts
    /// while the last of the field is still visible and the two motions muddle.
    static let blackoutHold: Double = 0.12

    /// Fades the *field* down to the black behind it, which is what the launch
    /// does at the end of `launchHold` before handing over to the library.
    /// Animated by the caller.
    ///
    /// The wordmark deliberately doesn't go with it. The water draining away
    /// from under the mark leaves the app's name alone on black for a beat,
    /// which is the thing the launch is for — and it's the mark that then
    /// carries the slide, so there's something to watch leave.
    ///
    /// Default off: `ContentView` shows this same view during an account
    /// switch, where there's a real wait behind it and nothing to hand over to
    /// at any particular moment.
    var isBlackedOut: Bool = false

    /// The plaque the wordmark stands on: raked to the letters' own angle, so
    /// the mark reads as one object with a plinth rather than as an italic logo
    /// dropped on an upright pill.
    ///
    /// Apple's glass takes any `Shape` for its outline, which is the whole
    /// reason this is a shape and not a transform — a sheared *view* would
    /// carry the mark and its hit region with it, and `.glassEffect` lenses
    /// whatever outline it is handed. Nothing here is hand-rolled glass.
    private let plaque = SlantedPlaque(cornerRadius: 30)

    var body: some View {
        ZStack {
            // The floor the fade lands on. True black rather than the panel's
            // own unlit colour: this is the app going dark between two screens,
            // and a near-black that still carries a hue reads as a dimmed
            // picture instead of as nothing.
            Color.black

            PixelRippleField()
                // The unlit panel, so a partial bottom row and the launch
                // storyboard behind it match the field rather than flashing.
                .background(Color(red: 0.006, green: 0.004, blue: 0.021))
                // One opacity over the whole field so the fade can't come apart
                // into layers going dark at different rates.
                .opacity(isBlackedOut ? 0 : 1)

            AdditWordmark(size: 46, lift: 0.30)
                // Smaller than the sign-in screen's 51, which is not the
                // obvious way round: that screen has more on it, but all of it
                // is small, where this one is a full-bleed panel the mark has
                // to hold its own against rather than sit quietly on.
                //
                // No `.shadow` on it any more, and that is not an oversight:
                // the mark carries its own contact shadow and its own halo out
                // of `Wordmark.metal`, where both are computed from the
                // letters' distance field. A SwiftUI shadow here would be
                // taken from the *rendered* alpha — halo included — and blur a
                // dark copy of the glow out underneath the glow.
                //
                // What the shadow used to be for still matters: the field
                // runs from near-black to a blown-out crest, so the mark can't
                // rely on contrast with any one part of it. The halo does that
                // job now, and does it better — it's the mark's own light
                // rather than a dark smear behind it, it's the colorway's own
                // light too (`Colorways.h`), and it sits outside the fade, so
                // it stays once the water has gone.
                // 38 rather than the 32 this is asking for, because the
                // plaque is raked and the mark's box already contains its own
                // lean: shearing inside the padded box spends
                // `slant × (plaqueHeight − markHeight) / 2` — about 6pt — of
                // the horizontal padding on the lean itself. The gap ends up
                // uniform down both edges either way, since the plaque's sides
                // are parallel to the letters'; this is only what that uniform
                // gap measures.
                .padding(.horizontal, 38)
                .padding(.vertical, 22)
                .background {
                    // Liquid Glass, sampling the water running underneath it.
                    // The mark used to hold the screen on its own light alone,
                    // which worked against the field's dark body and lost
                    // against a crest passing under it; a plaque gives it one
                    // ground that travels with whatever the water is doing.
                    //
                    // No `GlassRim` over it, which is the kit's rule rather
                    // than an omission: the edge-lit hairline is for floating
                    // surfaces we draw ourselves out of a material, and real
                    // Liquid Glass brings its own specular edge. Two edges on
                    // one plaque reads as a sticker of a button.
                    //
                    // It fades with the field and not with the mark. Glass is
                    // only the water seen through something, so a plaque that
                    // outlived the ripples would be a grey slab sitting on
                    // black — and the beat this screen ends on is the app's
                    // name alone.
                    Color.clear
                        .glassEffect(.clear, in: plaque)
                        .opacity(isBlackedOut ? 0 : 1)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

#Preview {
    LoadingSplashView()
}
