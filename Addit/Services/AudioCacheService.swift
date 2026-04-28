import Foundation

@Observable
final class AudioCacheService {
    var driveService: GoogleDriveService?
    var activeAccountId: String?

    /// Live "Make Available Offline" progress per album, keyed by the
    /// album's Google folder ID. An entry exists only while a cache run
    /// is in flight; presence in this dictionary is what AlbumDetailView's
    /// toolbar progress ring uses to decide whether to render itself.
    /// Stored on the service (rather than as `@State` on the view) so the
    /// indicator survives navigating away from the album and back again
    /// while the underlying download Task continues running.
    var albumCacheProgress: [String: AlbumCacheProgress] = [:]

    /// Snapshot of an in-flight album cache run.
    struct AlbumCacheProgress: Equatable {
        var current: Int
        var total: Int
    }

    private let fileManager = FileManager.default

    private var cacheDirectory: URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let base = caches.appendingPathComponent("AudioCache", isDirectory: true)
        let dir: URL
        if let accountId = activeAccountId {
            dir = base.appendingPathComponent(accountId, isDirectory: true)
        } else {
            dir = base
        }
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Clear cache for a specific account
    func clearCache(for accountId: String) throws {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("AudioCache", isDirectory: true)
            .appendingPathComponent(accountId, isDirectory: true)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
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
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .audioCacheDidChange, object: nil)
        }
        return destination
    }

    func removeTrack(_ track: Track) {
        let url = cacheFilePath(for: track)
        try? fileManager.removeItem(at: url)
        NotificationCenter.default.post(name: .audioCacheDidChange, object: nil)
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
        // Prefer the original file's extension over MIME type, since Google Drive
        // sometimes reports incorrect MIME types (e.g. m4a files as audio/mpeg)
        let originalExt = (track.name as NSString).pathExtension.lowercased()
        let ext = originalExt.isEmpty ? fileExtension(for: track.mimeType) : originalExt
        return cacheDirectory.appendingPathComponent("\(track.googleFileId).\(ext)")
    }

    private func fileExtension(for mimeType: String) -> String {
        switch mimeType {
        case "audio/mpeg": return "mp3"
        case "audio/mp4", "audio/x-m4a", "video/mp4": return "m4a"
        case "audio/aac": return "aac"
        case "audio/ogg": return "ogg"
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/aiff", "audio/x-aiff": return "aiff"
        default: return "audio"
        }
    }
}

extension Notification.Name {
    static let audioCacheDidChange = Notification.Name("audioCacheDidChange")
}

enum CacheError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Cache service not configured"
        }
    }
}
