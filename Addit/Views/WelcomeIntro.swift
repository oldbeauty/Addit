import SwiftUI

/// The four cards a new arrival is shown, once, on their first trip to the
/// library.
///
/// Content lives here rather than in the view so the sequence reads as a
/// script — the whole point of an intro is the order it goes in, and that is
/// hard to see when the copy is spread through a `switch`.
struct WelcomeStep: Identifiable {
    let id: Int
    /// The object on the card. Chosen for the step, not for variety — the
    /// folder-and-record is the "folders are albums" idea drawn, and the chain
    /// is the same mark the Access sheet uses for a link.
    let ornament: WelcomeOrnament
    let title: String
    let copy: String

    /// The advancing button's title. Every step says "Next" except the last,
    /// whose button is the one that closes the intro and so has to say what it
    /// does rather than promise another card.
    var advanceTitle: String { id == WelcomeStep.script.count - 1 ? "Get Started" : "Next" }

    static let script: [WelcomeStep] = [
        WelcomeStep(
            id: 0,
            ornament: .orb,
            title: "Welcome to Addit",
            copy: """
            This is an environment to listen to, share, and centralize your \
            cloud-stored music. We work with Google Drive and OneDrive, and \
            all functionality is free.
            """
        ),
        WelcomeStep(
            id: 1,
            ornament: .folderRecord,
            title: "How It Works",
            copy: """
            Folders in the cloud are treated as albums. Any songs housed \
            directly within a selected folder belong to that album.
            """
        ),
        WelcomeStep(
            id: 2,
            ornament: .chain,
            title: "Sharing and Access",
            copy: """
            Sharing and access in Addit behave exactly according to that of \
            the cloud type you are using. Addit is simply a listening \
            interface you can plug your clouds into. You can add as many \
            accounts as you want.
            """
        ),
        WelcomeStep(
            id: 3,
            ornament: .record,
            title: "All Set",
            copy: """
            Add a folder from one of your clouds and it arrives as an album. \
            Music already on this device works too.
            """
        ),
    ]
}

/// The intro card itself: title, copy, and a footer carrying the step count
/// and the button that advances it.
private struct WelcomeIntroPopup: View {
    @Binding var stepIndex: Int
    let dismiss: () -> Void

    @Environment(ThemeService.self) private var themeService

    private var step: WelcomeStep { WelcomeStep.script[stepIndex] }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                WelcomeOrnamentView(ornament: step.ornament)
                    .padding(.bottom, 4)

                Text(step.title)
                    .font(.uiTitle3.weight(.semibold))
                    .multilineTextAlignment(.leading)

                Text(step.copy)
                    .font(.uiSubheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(2)
            }
            // Ranged left: the VStack sizes to its widest child, so without
            // this the block would centre itself in the card even with its
            // own lines left-aligned.
            .frame(maxWidth: .infinity, alignment: .leading)
            // Keyed on the step so the two labels cross-fade as a pair
            // instead of the card appearing to retype itself.
            .id(stepIndex)
            .transition(.opacity)
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 18)
            // The copy is a different length on every step, and a card that
            // resizes under a fade looks like a layout bug. This holds the
            // tallest step's height for all four, so only the words change.
            .frame(minHeight: 242, alignment: .topLeading)

            HStack(spacing: 0) {
                // Set in the UI face, not the pixel readout — this sits
                // beside a plain button on a plain card, and the readout made
                // it look like a component from another screen. It keeps the
                // instrument light, which is still the right colour for a
                // counter: data, never the user's accent.
                Text("\(stepIndex + 1)/\(WelcomeStep.script.count)")
                    .font(.uiSubheadline)
                    .foregroundStyle(Phosphor.lit)
                    .monospacedDigit()

                Spacer(minLength: 12)

                Button(step.advanceTitle) { advance() }
                    .buttonStyle(WelcomeAdvanceStyle(accent: themeService.accentColor))
            }
            // Matches the text block's inset above, so the counter starts on
            // the same left edge as the title and copy rather than 4pt outside
            // them — which is exactly the sort of near-miss that reads as
            // sloppy without being obvious enough to name.
            .padding(.horizontal, 20)
            .frame(height: 52)
        }
        .frame(width: 290)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Glass, not the plain hairline `PromptPopup` wears: this is a
        // floating surface we draw entirely ourselves, which is the kit's
        // condition for the edge-lit treatment.
        .overlay(GlassRim(cornerRadius: 16))
        .shadow(color: .black.opacity(0.30), radius: 24, y: 8)
    }

    private func advance() {
        if stepIndex < WelcomeStep.script.count - 1 {
            stepIndex += 1
        } else {
            dismiss()
        }
    }
}

/// Accent-filled advance button. The label takes `legibleForeground` rather
/// than a fixed white, so a pale accent from the palette gets black text
/// instead of a glyph that vanishes into its own pill.
private struct WelcomeAdvanceStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.uiSubheadline.weight(.semibold))
            .foregroundStyle(accent.legibleForeground)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(accent, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct WelcomeIntroModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onFinish: () -> Void

    @State private var stepIndex = 0

    func body(content: Content) -> some View {
        content.overlay {
            // Same shape as `PromptPopupModifier`: a stable `ZStack` for the
            // transition to run in, one `.animation(value:)` driving the dim
            // and the card together.
            ZStack {
                if isPresented {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        // Swallows touches meant for the library behind, and
                        // is deliberately not a dismiss target — this runs
                        // once ever, and a stray tap shouldn't spend it.
                        .onTapGesture {}

                    WelcomeIntroPopup(stepIndex: $stepIndex) {
                        isPresented = false
                        onFinish()
                    }
                }
            }
            .animation(.snappy(duration: 0.2), value: isPresented)
            .animation(.snappy(duration: 0.2), value: stepIndex)
        }
        // This modifier outlives any one showing, so the counter has to be
        // wound back on the way in — otherwise a second run (debug replay)
        // opens on the last card with a "Get Started" button.
        .onChange(of: isPresented) { _, shown in
            if shown { stepIndex = 0 }
        }
    }
}

extension View {
    /// Presents the first-run intro over this view.
    ///
    /// `onFinish` fires only when the last card is dismissed by its button —
    /// the caller uses it to record that the intro has been seen. Nothing
    /// else can close this, so an intro abandoned by force-quitting mid-way
    /// is offered again next launch, which is the right side to err on for
    /// something shown exactly once.
    func welcomeIntro(isPresented: Binding<Bool>, onFinish: @escaping () -> Void) -> some View {
        modifier(WelcomeIntroModifier(isPresented: isPresented, onFinish: onFinish))
    }
}
