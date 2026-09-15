import SwiftUI

struct SignInView: View {
    @Environment(CloudAuthCoordinator.self) private var authService
    @Environment(ThemeService.self) private var themeService
    /// Flipping this is the whole action — `ContentView` watches the same key
    /// and swaps this screen for the library.
    @AppStorage(AppStorageKey.usesLocalOnly) private var usesLocalOnly = false

    /// Side of each provider tile.
    private static let providerTile: CGFloat = 80

    /// The mark in a square tile, in a pair sitting side by side.
    ///
    /// These are the flat brand marks from the asset catalog, not the app's own
    /// 3D glass ones from `GlassLogo.metal`. The glass versions are right in the
    /// library selector, where you already know what the app is — but as the
    /// very first thing on screen they read as something unfamiliar rather than
    /// as "Google Drive", and a sign-in button's whole job is to be recognised
    /// instantly.
    ///
    /// Both buttons share one treatment. They're peers: nothing about signing
    /// in with Google is more "primary" than signing in with Microsoft, and
    /// weighting one heavier only implied otherwise.
    @ViewBuilder
    private func providerButton(
        asset: String,
        title: String,
        /// Height as a fraction of the tile. Per-mark rather than shared: the
        /// OneDrive cloud is far wider than the Drive triangle, so at equal
        /// height it reads as the bigger of the two. Matching them optically
        /// means not matching them numerically.
        markScale: CGFloat = 0.50,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            // A fixed square rather than one sized by the row: the pair no
            // longer fills the width, so it centres instead. Padding around the
            // mark couldn't set this shape — the two marks have different
            // proportions, so equal padding gives unequal boxes.
            Color.clear
                .frame(width: Self.providerTile, height: Self.providerTile)
                .overlay {
                    // Constrained by height, not width: the OneDrive cloud is
                    // much wider than it is tall and the Drive triangle is
                    // nearly square, so matching widths would make one mark
                    // tower over the other.
                    Image(asset)
                        .resizable()
                        .scaledToFit()
                        .frame(height: Self.providerTile * markScale)
                }
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        // The mark is the whole button now, so the name has to live here or
        // VoiceOver announces an unlabelled image.
        .accessibilityLabel(title)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            DiscoHouse(side: 225)

            VStack(spacing: 10) {
                // The house and the mark carry the screen at 1.5×; the
                // tagline and the buttons stayed where they were. Scaling
                // everything just made a bigger version of the same picture —
                // holding the small parts small is what makes the pair above
                // them read as the subject and the rest as apparatus.
                AdditWordmark(size: 51)
                Text("The cloud music library")
                    .font(.uiSubheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 18)

            // The one real division on the screen, and deliberately much
            // bigger than any gap inside the lockup above it: house to mark
            // measures 13–35pt as the house turns, mark to tagline 5, so a
            // separator has to clear 35 by enough to not read as more of the
            // same rhythm. At the 34 it was, every gap on the screen was
            // roughly every other gap and the five elements read as five
            // things evenly scattered rather than two groups.
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    providerButton(
                        asset: "GoogleDriveLogo",
                        title: "Google Drive"
                    ) {
                        Task { await authService.signInGoogle() }
                    }

                    providerButton(
                        asset: "OneDriveLogo",
                        title: "OneDrive",
                        markScale: 0.45
                    ) {
                        Task { await authService.signInMicrosoft() }
                    }
                }

                // Addit has a real iPhone Storage library, so a cloud account
                // isn't actually required to use the app — only to reach a
                // cloud. Deliberately plain text rather than a third button:
                // it's the fallback, not a peer of the two above.
                Button {
                    usesLocalOnly = true
                } label: {
                    Text("Or, just use local")
                        .font(.uiSubheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 60)

            Spacer(minLength: 20)
        }
        // Pulls the picture up ~30pt (both Spacers shrink by half of it) to
        // sit at optical centre. It hangs low without this because
        // `DiscoHouse`'s square is not its drawing: the roof apex leaves ~50pt
        // of empty sky inside the top of that box at 225, against 3–25pt below
        // the lawn, so centring the *boxes* centres something 25–47pt lower
        // than what you can see. Measured off screenshots rather than reasoned
        // about — the dead margin is a property of the model and the camera in
        // `DiscoHouse.metal`, not of anything visible here.
        .padding(.bottom, 60)
        .alert("Sign-In Failed", isPresented: Binding(
            get: { authService.signInError != nil },
            set: { if !$0 { authService.signInError = nil } }
        )) {
            Button("OK", role: .cancel) { authService.signInError = nil }
        } message: {
            Text(authService.signInError ?? "")
        }
    }
}
