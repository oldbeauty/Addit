import SwiftUI

struct SignInView: View {
    @Environment(CloudAuthCoordinator.self) private var authService
    @Environment(ThemeService.self) private var themeService

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "music.note.house.fill")
                .font(.ui(80))
                .foregroundStyle(themeService.accentColor)

            VStack(spacing: 8) {
                Text("Addit")
                    .font(.uiLargeTitle.bold())
                Text("Your cloud music library")
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
                    // Deepened like the queue chips so the white label holds up
                    // against a pale accent — this is the one control on the
                    // screen a signed-out user has to be able to read.
                    .background(themeService.accentColor.legibleUnderWhiteLabel)
                    .foregroundStyle(.white)
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
