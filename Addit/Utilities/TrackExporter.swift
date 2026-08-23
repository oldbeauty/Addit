import Foundation

/// Staging one track as a file the share sheet can hand to another app.
///
/// Extracted from `AlbumDetailView` when the player grew its own share menu:
/// the tracklist and the now-playing card both need this, and the residue rules
/// below are the sort of thing that quietly diverges once it exists twice.
///
/// Deliberately share-*only*. If the track isn't already on-device it is
/// fetched straight to a temp file and the persistent audio cache is never
/// touched — so "send a song to a friend" leaves nothing behind once the temp
/// file is purged. If a local or cached copy does exist, its bytes are reused
/// through a hardlink rather than re-downloaded or duplicated.
@MainActor
enum TrackExporter {
    /// All file I/O runs off the main actor so playback doesn't stutter.
    static func stage(
        _ track: Track,
        driveService: any CloudDriveService,
        cacheService: AudioCacheService
    ) async throws -> URL {
        let fileId = track.googleFileId
        // The stored filename verbatim, so the export keeps its original
        // extension case ("wav", not the uppercased "WAV" the on-screen badge
        // produces).
        let niceName = track.name
        let localSource = track.localFileURL ?? cacheService.cachedFileURL(for: track)

        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let dest = fm.temporaryDirectory.appendingPathComponent(niceName)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            if let localSource {
                // A hardlink shares the bytes, so deleting the temp file later
                // doesn't disturb the original. Copy as a fallback in case temp
                // and source ever land on different volumes.
                do { try fm.linkItem(at: localSource, to: dest) }
                catch { try fm.copyItem(at: localSource, to: dest) }
            } else {
                try await driveService.downloadFile(fileId: fileId, to: dest)
            }
            return dest
        }.value
    }
}
