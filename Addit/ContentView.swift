import SwiftUI

struct ContentView: View {
    @Environment(CloudAuthCoordinator.self) private var authService
    @Environment(AudioPlayerService.self) private var playerService
    @Environment(ThemeService.self) private var themeService
    @Environment(\.colorScheme) private var colorScheme
    @State private var libraryPath: [Album] = []
    /// "Use without an account" — the library opens on iPhone Storage with no
    /// cloud session. Sticky, so a relaunch doesn't dump the user back on the
    /// sign-in screen; the account menu is still how you sign in later.
    @AppStorage(AppStorageKey.usesLocalOnly) private var usesLocalOnly = false

    var body: some View {
        Group {
            if authService.isRestoringSession || authService.isSwitchingAccount {
                LoadingSplashView()
            } else if authService.isSignedIn || usesLocalOnly {
                ZStack(alignment: .bottom) {
                    NavigationStack(path: $libraryPath) {
                        LibraryView(libraryPath: $libraryPath)
                            .flatSlideNavigation()
                    }

                    if playerService.currentTrack != nil && !playerService.hideNowPlayingBar {
                        // Mini and full player are one view: the pill owns
                        // both states and expands in place, so there's no
                        // presentation for this level to drive.
                        NowPlayingPill(onOpenAlbum: { album in
                            // Push the album onto the library stack *before*
                            // the pill collapses, so the album view is already
                            // behind the shrinking card. If the album already
                            // sits on top of the stack (user was viewing it
                            // before opening the player), skip the push so
                            // "tap cover" just returns there instead of
                            // stacking a duplicate.
                            if libraryPath.last != album {
                                libraryPath.append(album)
                            }
                        })
                        // The pill is pinned to the bottom of the window and has
                        // no text input of its own, so it has no business moving
                        // for a keyboard — and letting it move is what allowed it
                        // to get *stuck* mid-screen.
                        //
                        // Collapsing the library's search bar removes its
                        // `TextField` from the hierarchy in the same transaction
                        // that clears focus, so the responder disappears instead
                        // of resigning and the keyboard's frame change can fail to
                        // unwind the safe-area inset. Rather than trying to make
                        // that reset reliable — it depends on ordering inside
                        // SwiftUI — the pill simply never reads the inset, so
                        // there is no raised position for it to be stranded in.
                        // The library itself keeps normal keyboard avoidance, so
                        // the search field is still lifted clear.
                        .ignoresSafeArea(.keyboard, edges: .bottom)
                    }
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
