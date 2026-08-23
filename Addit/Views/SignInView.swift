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

    /// "ADDIT" as extruded chrome.
    ///
    /// Three things stacked, which is what separates chrome from a grey
    /// gradient: an extrusion of offset dark copies giving the letters depth, a
    /// face carrying the classic chrome ramp — bright sky at the top, a hard
    /// dark horizon across the middle, ground light bouncing up underneath —
    /// and a specular sliver over the top edge.
    ///
    /// The face is Hoefler Text Black: iOS ships no blackletter at all (Druk and
    /// Bebas are on the device but private to system UI), and of what's actually
    /// available a heavy gothic serif is nearest to a metal logo. A real black
    /// metal face would have to be bundled like Geist and Departure Mono are.
    private var chromeWordmark: some View {
        let face = Font.custom("HoeflerText-Black", size: 52)
        return ZStack {
            // Extrusion. Drawn back-to-front so the nearest slab is brightest —
            // a flat-coloured extrusion reads as a drop shadow, not as depth.
            ForEach((1...6).reversed(), id: \.self) { depth in
                Text("ADDIT")
                    .font(face)
                    .tracking(2)
                    .foregroundStyle(
                        Color(white: 0.10 + 0.035 * Double(6 - depth))
                    )
                    .offset(y: CGFloat(depth))
            }

            Text("ADDIT")
                .font(face)
                .tracking(2)
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: Color(red: 0.17, green: 0.18, blue: 0.20), location: 0.00),
                            .init(color: Color(red: 0.95, green: 0.97, blue: 1.00), location: 0.30),
                            .init(color: Color(red: 0.54, green: 0.57, blue: 0.61), location: 0.47),
                            // The horizon: a hard, dark band is the single most
                            // recognisable feature of chrome. Without it this is
                            // just a silver gradient.
                            .init(color: Color(red: 0.11, green: 0.13, blue: 0.16), location: 0.52),
                            .init(color: Color(red: 0.81, green: 0.85, blue: 0.90), location: 0.72),
                            .init(color: Color(red: 0.43, green: 0.46, blue: 0.50), location: 0.88),
                            .init(color: Color(red: 0.91, green: 0.94, blue: 0.98), location: 1.00),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: .black.opacity(0.45), radius: 6, y: 4)
        }
        .compositingGroup()
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            DiscoHouse(side: 150)

            VStack(spacing: 10) {
                chromeWordmark
                Text("The cloud music library")
                    .font(.uiSubheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 18)

            // The gap between the title block and the buttons, explicit rather
            // than whatever a Spacer felt like giving it.
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
            .padding(.top, 34)

            Spacer(minLength: 20)
        }
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
