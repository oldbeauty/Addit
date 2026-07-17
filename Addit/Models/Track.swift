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
    /// Cached scrubber waveform: one byte per bar (0…255 peak amplitude),
    /// written after the first full extraction so replays skip the file scan
    /// (~30 B per second of audio).
    @Attribute(.externalStorage) var waveformData: Data? = nil

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

    // MARK: Waveform cache

    /// Decoded waveform samples (0…1), or nil when nothing is cached or the
    /// cached bar count doesn't match `expectedCount` — a mismatch means the
    /// file's audio changed or the extraction density did, and forces a
    /// fresh extraction.
    func cachedWaveform(expectedCount: Int) -> [Float]? {
        guard let waveformData, waveformData.count == expectedCount else { return nil }
        return waveformData.map { Float($0) / 255 }
    }

    func storeWaveform(_ samples: [Float]) {
        waveformData = Data(samples.map { UInt8((min(max($0, 0), 1) * 255).rounded()) })
    }
}
