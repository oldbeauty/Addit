import SwiftUI

/// The screen between launch and the library: the wordmark under the orb.
///
/// Rendered from two places — `AccountContainerView` shows it while the session
/// restores (before `ContentView` exists at all), and `ContentView` shows it
/// during an account switch. It lives here so those two can't drift apart; they
/// were previously separate hand-maintained copies, and they had.
struct LoadingSplashView: View {
    var body: some View {
        VStack(spacing: 16) {
            SpinningPlasmaOrb(diameter: 64)
            Text("addit")
                .font(.uiTitle2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    LoadingSplashView()
}
