import SwiftUI

/// The way back to a Google Drive that Addit can't reach — a sign-in with the
/// Drive box left unticked, or a library whose session is gone.
///
/// Google's consent screen gives Drive its own checkbox, unticked, and a
/// sign-in without it still succeeds — so this is the one mistake the sign-in
/// flow can't stop you making. The card says what happened, shows the box as
/// Google words it, and sends you back to Google. It sits over whatever is on
/// screen, because either can come from any route in: the sign-in screen,
/// adding an account from the library, a switch, or a relaunch — which, with
/// "use local" on, opens the library whether or not there's a session behind
/// it.
private struct DriveAccessPopup: View {
    let request: GoogleAuthService.DriveAccessRequest

    @Environment(CloudAuthCoordinator.self) private var authService
    @Environment(ThemeService.self) private var themeService
    /// Written on success for the same reason `SignInView` writes it: granting
    /// Drive is asking to see the Drive library, and this can be reached from
    /// the Local one.
    @AppStorage(AppStorageKey.viewedLibrary) private var viewedLibrary =
        StorageSource.googleDrive.rawValue

    @State private var isAsking = false
    @State private var outcome: GoogleAuthService.DriveAccessOutcome?

    /// Google's own words for the scope, so the line here is the line there.
    private static let scopeLine = "See, edit, create, and delete all of your Google Drive files"
    /// Google's checkbox blue — this row is a picture of their screen, not a
    /// control of ours, so it wears their colour rather than the accent.
    private static let googleBlue = Color(red: 0x1A / 255, green: 0x73 / 255, blue: 0xE8 / 255)

    private var isSignedOut: Bool { request.reason == .signedOut }

    private var title: String {
        isSignedOut ? "Sign in to Google again" : "Google Drive wasn't ticked"
    }

    private var copy: String {
        switch outcome {
        case .stillMissing:
            return "Still unticked. On Google's screen, tick the Drive box before you press Continue."
        case .failed(let message):
            return message
        default:
            if isSignedOut {
                return "Addit was signed out of \(request.email). Your library is still here, and plays again once you sign back in."
            }
            let who = request.email.isEmpty ? "You signed in" : "You signed in as \(request.email)"
            return "\(who), but Addit wasn't given your Drive, so nothing can play and no covers can load."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                StorageSourceLogo(source: .googleDrive, scale: 2.6)
                    .padding(.bottom, 6)

                Text(title)
                    .font(.uiTitle3.weight(.semibold))

                Text(copy)
                    .font(.uiSubheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)

                Text(isSignedOut ? "If Google asks, keep this ticked:" : "On Google's screen, tick this:")
                    .font(.uiFootnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)

                consentRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 18)

            HStack(spacing: 0) {
                Button("Not now") { authService.dismissDriveAccessRequest() }
                    .font(.uiSubheadline)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                Button(isSignedOut ? "Sign In" : "Go to Google") { ask() }
                    .buttonStyle(WelcomeAdvanceStyle(accent: themeService.accentColor))
            }
            .disabled(isAsking)
            .padding(.horizontal, 20)
            .frame(height: 52)
        }
        .frame(width: 290)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(GlassRim(cornerRadius: 16))
        .shadow(color: .black.opacity(0.30), radius: 24, y: 8)
        .animation(.snappy(duration: 0.2), value: outcome)
    }

    /// The box to tick, drawn as Google draws it.
    private var consentRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.square.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Self.googleBlue)
                .font(.system(size: 20))
            Text(Self.scopeLine)
                .font(.uiFootnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.scopeLine)
    }

    private func ask() {
        isAsking = true
        Task {
            let result = await authService.grantDriveAccess()
            isAsking = false
            switch result {
            case .granted:
                viewedLibrary = StorageSource.googleDrive.rawValue
            case .cancelled:
                // Backing out of Google's screen changes nothing here — the
                // card is still the explanation.
                break
            case .stillMissing, .failed:
                outcome = result
            }
        }
    }
}

private struct DriveAccessPromptModifier: ViewModifier {
    @Environment(CloudAuthCoordinator.self) private var authService

    func body(content: Content) -> some View {
        content.overlay {
            // Same shape as `WelcomeIntroModifier`.
            ZStack {
                if let request = authService.driveAccessRequest {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        // Not a dismiss target: the way out is "Not now",
                        // said on purpose, because out is a library that
                        // doesn't work.
                        .onTapGesture {}

                    DriveAccessPopup(request: request)
                        // A new account is a new question, not the old card
                        // still saying "still unticked".
                        .id(request.id)
                }
            }
            .animation(.snappy(duration: 0.2), value: authService.driveAccessRequest)
        }
    }
}

extension View {
    /// Puts the Drive-access card up whenever a Google sign-in comes back
    /// without Drive. See `GoogleAuthService.driveAccessRequest`.
    func driveAccessPrompt() -> some View {
        modifier(DriveAccessPromptModifier())
    }
}
