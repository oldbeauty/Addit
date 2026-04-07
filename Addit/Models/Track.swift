import Foundation
import SwiftData

@Model
final class Track {
    var googleFileId: String
    var name: String
    var album: Album?
    var durationSeconds: Double?
    var mimeType: String
    var fileSize: Int64?
    var trackNumber: Int
    var modifiedTime: String?
    var localFilePath: String?
    var isHidden: Bool = false

    init(googleFileId: String, name: String, album: Album? = nil,
         durationSeconds: Double? = nil, mimeType: String,
         fileSize: Int64? = nil, trackNumber: Int, modifiedTime: String? = nil,
         localFilePath: String? = nil) {
        self.googleFileId = googleFileId
        self.name = name
        self.album = album
        self.durationSeconds = durationSeconds
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.trackNumber = trackNumber
        self.modifiedTime = modifiedTime
        self.localFilePath = localFilePath
    }

    var isLocal: Bool { localFilePath != nil }

    var localFileURL: URL? {
        guard let localFilePath else { return nil }
        // If it's already an absolute path, use it directly (legacy data)
        // Otherwise treat it as relative to Documents directory
        if localFilePath.hasPrefix("/") {
            // Legacy absolute path — check if it still works
            if FileManager.default.fileExists(atPath: localFilePath) {
                return URL(fileURLWithPath: localFilePath)
            }
            // Absolute path is stale (container UUID changed) — try to extract relative portion
            if let range = localFilePath.range(of: "Documents/") {
                let relativePath = String(localFilePath[range.upperBound...])
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let resolved = docs.appendingPathComponent(relativePath)
                if FileManager.default.fileExists(atPath: resolved.path) {
                    return resolved
                }
            }
            return URL(fileURLWithPath: localFilePath)
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(localFilePath)
    }

    var fileExtension: String {
        (name as NSString).pathExtension.uppercased()
    }

    var formattedModifiedDate: String? {
        guard let modifiedTime else { return nil }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = isoFormatter.date(from: modifiedTime) ?? {
            let basic = ISO8601DateFormatter()
            basic.formatOptions = [.withInternetDateTime]
            return basic.date(from: modifiedTime)
        }()
        guard let date else { return nil }
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .none
        return display.string(from: date)
    }

    var displayName: String {
        let nameWithoutExt = (name as NSString).deletingPathExtension
        return nameWithoutExt
    }
}
