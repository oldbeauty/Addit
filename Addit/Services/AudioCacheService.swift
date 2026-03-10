import Foundation

@Observable
final class AudioCacheService {
    var driveService: GoogleDriveService?

    private let fileManager = FileManager.default

    private var cacheDirectory: URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("AudioCache", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func cachedFileURL(for track: Track) -> URL? {
        let url = cacheFilePath(for: track)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func cacheTrack(_ track: Track) async throws -> URL {
        let destination = cacheFilePath(for: track)
        if fileManager.fileExists(atPath: destination.path) {
            return destination
        }

        guard let driveService else { throw CacheError.notConfigured }
        try await driveService.downloadFile(fileId: track.googleFileId, to: destination)
        return destination
    }

    func clearCache() throws {
        if fileManager.fileExists(atPath: cacheDirectory.path) {
            try fileManager.removeItem(at: cacheDirectory)
        }
    }

    func cacheSize() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func cacheFilePath(for track: Track) -> URL {
        let ext = fileExtension(for: track.mimeType)
        return cacheDirectory.appendingPathComponent("\(track.googleFileId).\(ext)")
    }

    private func fileExtension(for mimeType: String) -> String {
        switch mimeType {
        case "audio/mpeg": return "mp3"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "audio/aac": return "aac"
        case "audio/ogg": return "ogg"
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/aiff", "audio/x-aiff": return "aiff"
        default: return "audio"
        }
    }
}

enum CacheError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Cache service not configured"
        }
    }
}
