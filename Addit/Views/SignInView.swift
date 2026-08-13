import SwiftUI

struct SignInView: View {
    @Environment(CloudAuthCoordinator.self) private var authService
    @Environment(ThemeService.self) private var themeService
    /// Flipping this is the whole action — `ContentView` watches the same key
    /// and swaps this screen for the library.
    @AppStorage(AppStorageKey.usesLocalOnly) private var usesLocalOnly = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            DiscoHouse(side: 150)

            VStack(spacing: 8) {
                Text("Addit")
                    .font(.uiLargeTitle.bold())
                Text("The cloud music library")
                    .font(.uiSubheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    Task { await authService.signInGoogle() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.uiTitle3)
                        Text("Sign in with Google")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    // Deliberately NOT accent-derived. This button is the first
                    // thing anyone sees and it has to be unambiguous at every
                    // setting — but the accent is user-chosen, and the dark
                    // default is now white, which `legibleUnderWhiteLabel`
                    // could only rescue by flattening into a washed grey.
                    // Inverted primary is maximum contrast in both schemes and
                    // depends on nothing.
                    .background(Color.primary)
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button {
                    Task { await authService.signInMicrosoft() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "cloud.fill")
                            .font(.uiTitle3)
                        Text("Sign in with Microsoft")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.quaternary)
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // Addit has a real iPhone Storage library, so a cloud account
                // isn't actually required to use the app — only to reach a
                // cloud. Deliberately plain text rather than a third button:
                // it's the fallback, not a peer of the two sign-in options.
                Button {
                    usesLocalOnly = true
                } label: {
                    Text("Use without an account")
                        .font(.uiSubheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 40)

            Spacer()
                .frame(height: 60)
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
