import Foundation

enum Constants {
    // Google Cloud → Credentials → OAuth client ID (type: iOS), bound to
    // `tv.hollowpoint.addit`. An iOS client has no secret, so Google identifies
    // the app by its bundle ID — which means a new bundle ID always needs a new
    // client, and the two must change together. Keep in sync with Info.plist:
    // both `GIDClientID` and the reversed-client-ID URL scheme
    // `com.googleusercontent.apps.<id>`.
    static let googleClientID = "234191398888-58jmohlpegd1mir5jivla9e579rp6uh7.apps.googleusercontent.com"

    static let driveAPIBase = "https://www.googleapis.com/drive/v3"
    static let driveScope = "https://www.googleapis.com/auth/drive"

    // MARK: - Microsoft / OneDrive
    // Azure app registration (portal.azure.com → App registrations).
    // Replace with the real Application (client) ID once registered.
    // The registration needs a "Mobile and desktop applications" platform
    // with `microsoftAuthRedirectURI` below as a redirect URI — a fixed
    // custom scheme, deliberately NOT the MSAL msauth.<bundleId> pattern,
    // so every contributor's per-developer bundle ID works against the
    // same registration with zero Azure changes.
    static let microsoftClientID = "a6388f0b-72f0-419a-912e-e55205dfbecb"
    /// /consumers tenant: personal Microsoft accounts only (OneDrive
    /// personal). Switch to /common if org accounts should work too.
    static let microsoftAuthorityBase = "https://login.microsoftonline.com/consumers/oauth2/v2.0"
    static let microsoftAuthRedirectURI = "addit-msauth://callback"
    static let microsoftAuthRedirectScheme = "addit-msauth"
    /// Files.ReadWrite.All (not plain Files.ReadWrite) so shared folders
    /// other people own are writable — the collaborative-album use case.
    static let microsoftScopes = "Files.ReadWrite.All User.Read offline_access"
    static let graphAPIBase = "https://graph.microsoft.com/v1.0"

    // MARK: - Legal
    // The two policy pages, published with the website rather than bundled in
    // the app: App Store Connect requires the privacy URL to be reachable on
    // its own, and a wording fix shouldn't need a build. Source lives in
    // `HollowpointTv/addit/{privacy,terms}/`. Both are linked from Settings.
    static let privacyPolicyURL = URL(string: "https://hollowpoint.tv/addit/privacy/")!
    static let termsOfUseURL = URL(string: "https://hollowpoint.tv/addit/terms/")!

    static let audioMimeTypes = [
        "audio/mpeg",
        "audio/mp4",
        "audio/x-m4a",
        "audio/aac",
        "audio/ogg",
        "audio/flac",
        "audio/x-flac",
        "audio/wav",
        "audio/x-wav",
        "audio/aiff",
        "audio/x-aiff",
        "audio/alac",
        "video/mp4"
    ]
}

/// `UserDefaults` keys shared between views that can't reach each other
/// directly. A key used in one place should stay a local literal; these are
/// here precisely because more than one file depends on the exact string.
enum AppStorageKey {
    /// The user chose "Use without an account" on the sign-in screen. Read by
    /// `AccountContainerView` (which store to hand out) and `ContentView`
    /// (whether to show the library or the sign-in screen).
    static let usesLocalOnly = "usesLocalOnly"

    /// The first-run intro has been read to its last card. Written by
    /// `ContentView`, which presents it; cleared by the debug-only replay row
    /// in `SettingsView`.
    static let hasSeenWelcomeIntro = "hasSeenWelcomeIntro"
}
