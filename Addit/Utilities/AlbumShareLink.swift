import Foundation

/// An album, reduced to something you can paste into a text message.
///
/// The wire format is `https://hollowpoint.tv/a/<provider>/<folderId>`, with an
/// optional `?n=<name>` that exists only so the preview card iMessage draws can
/// say which album it is. Nothing else needs to travel: an album *is* its cloud
/// folder, so track order, disc markers and cover art all come back out of
/// `.addit-data` and `findCoverImage` on the recipient's side.
///
/// The link is a pointer, not a key. It grants no access on its own — the
/// sender grants that on the Drive folder itself, and a recipient without
/// permission gets a plain "no access" error rather than anything leaking.
///
/// `https` rather than a custom `addit://` scheme because Messages only
/// linkifies http(s): an `addit://` URL arrives in the bubble as grey,
/// untappable text, which defeats the entire feature. The custom scheme is
/// still parsed — see `customScheme` — but only as a testing affordance.
struct AlbumShareLink: Equatable, Hashable, Identifiable {
    let source: StorageSource
    let folderId: String
    /// Display name, for the web preview card and for naming the album in the
    /// UI before the first network call returns. Never trusted: the import
    /// re-reads the real name from the folder.
    let name: String?
    /// Artist and cover are carried purely so the web preview card can be a
    /// real card — the app re-reads both from the folder on import and never
    /// trusts what the URL said.
    let artist: String?
    /// Google-only, and only for `og:image` — i.e. the card someone else's
    /// server builds when the link is *pasted* into Slack or a browser. It is
    /// fetched from Drive anonymously, so it resolves exactly when the album is
    /// shared "anyone with the link" and can never expose a cover Drive would
    /// have withheld. Sharing from inside the app doesn't rely on it: that path
    /// supplies the on-device cover directly (`AlbumLinkShareItem`).
    let coverFileId: String?
    /// Set when the link points at one song rather than the whole album. The
    /// album still travels — a track can only be reached through the folder
    /// that holds it — so this is an *extra* instruction: open this album, then
    /// start here.
    let trackFileId: String?

    var id: String { "\(source.rawValue)|\(folderId)|\(trackFileId ?? "")" }

    static let host = "hollowpoint.tv"
    static let pathPrefix = "a"
    /// Not registered for Messages' sake — see the type comment. It exists so
    /// `xcrun simctl openurl booted "addit://a/g/<id>"` can drive this code
    /// path in the Simulator, where universal links can't be relied on.
    static let customScheme = "addit"

    /// Cap matches the web Function's, so a long name can't produce a URL that
    /// one side truncates and the other doesn't.
    private static let maxNameLength = 120

    // MARK: - Wire codes

    /// Deliberately short and deliberately *not* `StorageSource.rawValue`:
    /// this is a published URL format, and it must not move because someone
    /// renames an enum case. Local albums have no code — their files live in
    /// the app sandbox and there is nothing on the other end to point at.
    private static func code(for source: StorageSource) -> String? {
        switch source {
        case .googleDrive: return "g"
        case .oneDrive: return "m"
        case .localStorage: return nil
        }
    }

    private static func source(forCode code: String) -> StorageSource? {
        switch code {
        case "g": return .googleDrive
        case "m": return .oneDrive
        default: return nil
        }
    }

    // MARK: - Building

    init?(album: Album) {
        guard Self.code(for: album.storageSource) != nil else { return nil }
        self.source = album.storageSource
        self.folderId = album.googleFolderId
        self.name = album.name
        self.artist = album.artistName
        self.coverFileId = album.storageSource == .googleDrive ? album.coverFileId : nil
        self.trackFileId = nil
    }

    /// One song. Its cover and artist are the album's — a track carries neither
    /// of its own — but the title is the song's.
    init?(track: Track, in album: Album) {
        guard Self.code(for: album.storageSource) != nil else { return nil }
        self.source = album.storageSource
        self.folderId = album.googleFolderId
        self.name = track.displayName
        self.artist = album.artistName
        self.coverFileId = album.storageSource == .googleDrive ? album.coverFileId : nil
        self.trackFileId = track.googleFileId
    }

    init(source: StorageSource, folderId: String, name: String?, artist: String? = nil,
         coverFileId: String? = nil, trackFileId: String? = nil) {
        self.source = source
        self.folderId = folderId
        self.name = name
        self.artist = artist
        self.coverFileId = coverFileId
        self.trackFileId = trackFileId
    }

    var url: URL? {
        guard let code = Self.code(for: source) else { return nil }

        // OneDrive IDs are composite `driveId|itemId`, and `|` is not legal in
        // a path — encoding by hand and assigning `percentEncodedPath` avoids
        // both the double-encoding that `path` would cause and URLComponents'
        // willingness to pass `|` through untouched.
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        guard let encodedId = folderId.addingPercentEncoding(withAllowedCharacters: unreserved),
              !encodedId.isEmpty
        else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.percentEncodedPath = "/\(Self.pathPrefix)/\(code)/\(encodedId)"
        var query: [URLQueryItem] = []
        if let name, !name.isEmpty {
            query.append(URLQueryItem(name: "n", value: String(name.prefix(Self.maxNameLength))))
        }
        if let artist, !artist.isEmpty {
            query.append(URLQueryItem(name: "a", value: String(artist.prefix(Self.maxNameLength))))
        }
        if let coverFileId, !coverFileId.isEmpty {
            query.append(URLQueryItem(name: "c", value: coverFileId))
        }
        if let trackFileId, !trackFileId.isEmpty {
            query.append(URLQueryItem(name: "t", value: trackFileId))
        }
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }

    // MARK: - Parsing

    /// `nil` for anything that isn't an album link — the OAuth callbacks share
    /// this entry point, so a miss here is completely ordinary.
    init?(url: URL) {
        let scheme = url.scheme?.lowercased()

        var segments = url.pathComponents.filter { $0 != "/" }
        switch scheme {
        case "https":
            guard url.host?.lowercased() == Self.host else { return nil }
        case Self.customScheme:
            // `addit://a/g/<id>` parses with "a" as the *host*, not a path
            // component, so put it back before matching.
            guard let host = url.host else { return nil }
            segments.insert(host, at: 0)
        default:
            return nil
        }

        guard segments.count == 3,
              segments[0] == Self.pathPrefix,
              let source = Self.source(forCode: segments[1])
        else { return nil }

        // `pathComponents` is already percent-decoded, so a OneDrive `%7C` is
        // back to `|` here.
        let folderId = segments[2]
        guard !folderId.isEmpty else { return nil }

        self.source = source
        self.folderId = folderId

        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        func value(_ key: String) -> String? {
            let raw = query?.first(where: { $0.name == key })?.value
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else { return nil }
            return String(trimmed.prefix(Self.maxNameLength))
        }
        self.name = value("n")
        self.artist = value("a")
        self.coverFileId = value("c")
        self.trackFileId = value("t")
    }
}
