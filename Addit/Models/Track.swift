import Foundation
import SwiftData

@Model
final class Track {
    @Attribute(.unique) var googleFileId: String
    var name: String
    var album: Album?
    var durationSeconds: Double?
    var mimeType: String
    var fileSize: Int64?
    var trackNumber: Int

    init(googleFileId: String, name: String, album: Album? = nil,
         durationSeconds: Double? = nil, mimeType: String,
         fileSize: Int64? = nil, trackNumber: Int) {
        self.googleFileId = googleFileId
        self.name = name
        self.album = album
        self.durationSeconds = durationSeconds
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.trackNumber = trackNumber
    }

    var displayName: String {
        let nameWithoutExt = (name as NSString).deletingPathExtension
        return nameWithoutExt
    }
}
