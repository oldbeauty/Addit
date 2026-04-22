import SwiftUI

struct ContentView: View {
    @Environment(GoogleAuthService.self) private var authService
    @Environment(AudioPlayerService.self) private var playerService
    @Environment(ThemeService.self) private var themeService
    @State private var showNowPlaying = false
    @State private var libraryPath = NavigationPath()

    var body: some View {
        Group {
            if authService.isRestoringSession || authService.isSwitchingAccount {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("addit")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if authService.isSignedIn {
                ZStack(alignment: .bottom) {
                    NavigationStack(path: $libraryPath) {
                        LibraryView()
                    }

                    if playerService.currentTrack != nil && !playerService.hideNowPlayingBar {
                        NowPlayingBar(showFullPlayer: $showNowPlaying)
                    }
                }
                .sheet(isPresented: $showNowPlaying) {
                    NowPlayingView(onOpenAlbum: { album in
                        // Push the album onto the library stack *before*
                        // dismissing the sheet, so when the sheet animates
                        // away the album view is already behind it.
                        libraryPath.append(album)
                        showNowPlaying = false
                    })
                }
            } else {
                SignInView()
            }
        }
        .tint(themeService.accentColor)
        .preferredColorScheme(themeService.appearanceMode.colorScheme)
        .alert("Unable to play this audio format", isPresented: .init(
            get: { playerService.failedTrack != nil },
            set: { if !$0 { playerService.failedTrack = nil } }
        )) {
            Button("OK", role: .cancel) {
                playerService.failedTrack = nil
            }
        } message: {
            Text("This file uses an audio format that Addit doesn't support.")
        }
    }
}
