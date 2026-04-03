import Foundation
import SwiftData

enum StorageSource: String, Codable {
    case googleDrive
    case localStorage
}

@Model
final class Album {
    @Attribute(.unique) var googleFolderId: String
    var name: String
    var artistName: String?
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
