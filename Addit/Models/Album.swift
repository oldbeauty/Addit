import Foundation
import SwiftData

@Model
final class Album {
    @Attribute(.unique) var googleFolderId: String
    var name: String
    var artistName: String?
    var trackCount: Int
    var dateAdded: Date
    var canEdit: Bool

    @Relationship(deleteRule: .cascade, inverse: \Track.album)
    var tracks: [Track] = []

    init(googleFolderId: String, name: String, artistName: String? = nil, trackCount: Int, dateAdded: Date = .now, canEdit: Bool = false) {
        self.googleFolderId = googleFolderId
        self.name = name
        self.artistName = artistName
        self.trackCount = trackCount
        self.dateAdded = dateAdded
        self.canEdit = canEdit
    }
}
