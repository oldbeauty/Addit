import SwiftUI

struct ContentView: View {
    @Environment(CloudAuthCoordinator.self) private var authService
    @Environment(AudioPlayerService.self) private var playerService
    @Environment(ThemeService.self) private var themeService
    @Environment(\.colorScheme) private var colorScheme
    @State private var showNowPlaying = false
    @State private var libraryPath: [Album] = []

    var body: some View {
        Group {
            if authService.isRestoringSession || authService.isSwitchingAccount {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("addit")
                        .font(.uiTitle2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if authService.isSignedIn {
                ZStack(alignment: .bottom) {
                    NavigationStack(path: $libraryPath) {
                        LibraryView(libraryPath: $libraryPath)
                            .flatSlideNavigation()
                    }

                    if playerService.currentTrack != nil && !playerService.hideNowPlayingBar {
                        NowPlayingBar(showFullPlayer: $showNowPlaying)
                    }
                }
                .sheet(isPresented: $showNowPlaying) {
                    NowPlayingView(onOpenAlbum: { album in
                        // Push the album onto the library stack *before*
                        // dismissing the sheet, so when the sheet animates
                        // away the album view is already behind it. If the
                        // album already sits on top of the stack (user was
                        // viewing it before opening the player), skip the
                        // push so "tap cover" just returns there instead of
                        // stacking a duplicate.
                        if libraryPath.last != album {
                            libraryPath.append(album)
                        }
                        showNowPlaying = false
                    })
                }
            } else {
                SignInView()
            }
        }
        .tint(themeService.accentColor)
        // Default UI font for any text without an explicit .font() — routes
        // through the same appFamily knob as the ui* tokens (Phosphor.swift).
        .environment(\.font, .uiBody)
        .preferredColorScheme(themeService.appearanceMode.colorScheme)
        // Bridge SwiftUI's effective colorScheme into ThemeService so
        // its `accentColor` computed property knows which per-scheme
        // hex to return. Run on first appearance (so the very first
        // frame uses the right color) and on every change after that
        // (so flipping system dark/light or changing the in-app
        // Appearance picker swaps the accent immediately).
        .onAppear { themeService.currentScheme = colorScheme }
        .onChange(of: colorScheme) { _, newValue in
            themeService.currentScheme = newValue
        }
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
