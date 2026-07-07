import Foundation

enum Constants {
    // Replace with your actual Google OAuth Client ID
    static let googleClientID = "234191398888-6juqhe695b4p2oua8q6hpjv9o96d0s63.apps.googleusercontent.com"

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
