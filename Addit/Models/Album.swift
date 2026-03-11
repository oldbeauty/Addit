import Foundation
import SwiftData

@Model
final class Album {
    @Attribute(.unique) var googleFolderId: String
    var name: String
    var artistName: String?
    var coverFileId: String?
    var coverMimeType: String?
    var coverUpdatedAt: Date?
    var trackCount: Int
    var dateAdded: Date
    var canEdit: Bool

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
        canEdit: Bool = false
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
    }

    var coverArtTaskID: String {
        let timestamp = coverUpdatedAt?.timeIntervalSince1970 ?? 0
        return "\(coverFileId ?? "none")-\(timestamp)"
    }
}
