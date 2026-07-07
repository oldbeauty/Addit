import SwiftUI

struct SignInView: View {
    @Environment(CloudAuthCoordinator.self) private var authService
    @Environment(ThemeService.self) private var themeService

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "music.note.house.fill")
                .font(.system(size: 80))
                .foregroundStyle(themeService.accentColor)

            VStack(spacing: 8) {
                Text("Addit")
                    .font(.largeTitle.bold())
                Text("Your cloud music library")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    Task { await authService.signInGoogle() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.title3)
                        Text("Sign in with Google")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(themeService.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button {
                    Task { await authService.signInMicrosoft() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "cloud.fill")
                            .font(.title3)
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
    }
}
