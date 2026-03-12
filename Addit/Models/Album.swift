import Foundation
import SwiftData

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
        displayOrder: Int = 0
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
    }

    var coverArtTaskID: String {
        return "\(coverFileId ?? "none")-\(coverModifiedTime ?? "unknown")"
    }
}
