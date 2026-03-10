import SwiftUI

struct ContentView: View {
    @Environment(GoogleAuthService.self) private var authService
    @Environment(AudioPlayerService.self) private var playerService
    @State private var showNowPlaying = false

    var body: some View {
        if authService.isSignedIn {
            ZStack(alignment: .bottom) {
                NavigationStack {
                    LibraryView()
                }

                if playerService.currentTrack != nil {
                    NowPlayingBar(showFullPlayer: $showNowPlaying)
                        .transition(.move(edge: .bottom))
                }
            }
            .sheet(isPresented: $showNowPlaying) {
                NowPlayingView()
            }
        } else {
            SignInView()
        }
    }
}
