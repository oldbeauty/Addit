import Foundation
import SwiftData

enum StorageSource: String, Codable {
    case googleDrive
    case oneDrive
    case localStorage

    /// True for sources backed by a remote drive API (anything that isn't
    /// on-device storage). Use this instead of listing cloud cases at call
    /// sites so adding a provider doesn't require sweeping conditionals.
    var isCloud: Bool { self != .localStorage }
}

@Model
final class Album {
    var googleFolderId: String
    var name: String
    var artistName: String?
    /// The album's blurb. On a cloud album this mirrors the Drive/OneDrive
    /// folder's own description field, so it is editable from the provider's
    /// web UI too and travels with a shared folder; the copy here is the
    /// offline one. Named around `description` rather than as it, which on a
    /// type means something else entirely.
    var albumDescription: String?
    var coverFileId: String?
    var coverMimeType: String?
    var coverModifiedTime: String?
    var coverUpdatedAt: Date?
    var trackCount: Int
    var dateAdded: Date
    var canEdit: Bool
    var isFolderOwner: Bool = false
    var displayOrder: Int = 0
    var cachedTracklist: [String] = []
    var additDataFileId: String?
    var storageSourceRaw: String? = StorageSource.googleDrive.rawValue
    var localCoverPath: String?
    var showHiddenTracks: Bool = true
    var accountId: String?

    var storageSource: StorageSource {
        get { StorageSource(rawValue: storageSourceRaw ?? "") ?? .googleDrive }
        set { storageSourceRaw = newValue.rawValue }
    }

    @Relationship(deleteRule: .cascade, inverse: \Track.album)
    var tracks: [Track] = []

    init(
        googleFolderId: String,
        name: String,
        artistName: String? = nil,
        coverFileId: String? = nil,
        coverMimeType: String? = nil,
        coverUpdatedAt: Date? = nil,
        trackCount: Int,
        dateAdded: Date = .now,
        canEdit: Bool = false,
        isFolderOwner: Bool = false,
        displayOrder: Int = 0,
        storageSource: StorageSource = .googleDrive
    ) {
        self.googleFolderId = googleFolderId
        self.name = name
        self.artistName = artistName
        self.coverFileId = coverFileId
        self.coverMimeType = coverMimeType
        self.coverUpdatedAt = coverUpdatedAt
        self.trackCount = trackCount
        self.dateAdded = dateAdded
        self.canEdit = canEdit
        self.isFolderOwner = isFolderOwner
        self.displayOrder = displayOrder
        self.storageSourceRaw = storageSource.rawValue
    }

    var isLocal: Bool { storageSource == .localStorage }
    var isOneDrive: Bool { storageSource == .oneDrive }

    /// Where a local album's files live: `Documents/LocalAlbums/<id>`, holding
    /// its audio and its `cover.jpg`. `nil` for cloud albums.
    ///
    /// The `<id>` is `googleFolderId` minus the `local_` prefix every creation
    /// path stamps on. Deletion used to derive this inline, which is precisely
    /// the kind of duplicated mapping that goes stale and leaves a directory
    /// behind — it lives here now, next to the paths it has to agree with.
    var localDirectoryURL: URL? {
        guard isLocal else { return nil }
        let directoryName = googleFolderId.hasPrefix("local_")
            ? String(googleFolderId.dropFirst("local_".count))
            : googleFolderId
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalAlbums", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Resolves localCoverPath to an absolute path, handling both legacy absolute and relative paths
    var resolvedLocalCoverPath: String? {
        guard let localCoverPath else { return nil }
        if localCoverPath.hasPrefix("/") {
            if FileManager.default.fileExists(atPath: localCoverPath) {
                return localCoverPath
            }
            // Absolute path is stale — extract relative portion after Documents/
            if let range = localCoverPath.range(of: "Documents/") {
                let relativePath = String(localCoverPath[range.upperBound...])
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let resolved = docs.appendingPathComponent(relativePath).path
                if FileManager.default.fileExists(atPath: resolved) {
                    return resolved
                }
            }
            return localCoverPath
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(localCoverPath).path
    }

    var coverArtTaskID: String {
        return "\(coverFileId ?? "none")-\(coverModifiedTime ?? "unknown")"
    }
}
