import Foundation

/// Removes the files an `Album` or `Track` stands for.
///
/// Deleting one of those from SwiftData removes the **record**. The bytes it
/// referred to — an offline cache entry, a local audio file, a cached cover —
/// are ordinary files on disk, and nothing collects them automatically. The
/// cascade rule on `Album.tracks` doesn't either: it deletes rows, not files.
/// So every deletion path has to purge first, **while the record is still
/// there to say what to delete**.
///
/// This is centralised because it kept being missed, in three different ways:
/// album removal cleaned up local files but never the cached audio or artwork
/// of a cloud album; one of the two "Remove from Library" buttons deleted the
/// record and nothing else, stranding a whole album directory; and the Drive
/// sync pruned tracks that had vanished upstream while leaving their offline
/// copies behind, unreachable forever. Call one of these before any
/// `modelContext.delete` of an album or track, and none of that can recur.
enum LibraryCleanup {
    /// Everything on disk belonging to `track`.
    static func purge(_ track: Track, cache: AudioCacheService) {
        // The offline copy of a cloud track. No-op when there isn't one.
        cache.removeTrack(track)

        // The audio itself, for a track that lives on the device. Deleting a
        // whole local album takes its directory in one go — this is the path
        // for pulling a single track out of one.
        if let url = track.localFileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Everything on disk belonging to `album`, its tracks included.
    static func purge(_ album: Album, cache: AudioCacheService, art: AlbumArtService) {
        for track in album.tracks {
            purge(track, cache: cache)
        }

        if let directory = album.localDirectoryURL {
            // Takes the audio, the cover, and anything else written into the
            // album's own directory — including files the track records don't
            // know about, which is why it's worth doing even after the loop.
            try? FileManager.default.removeItem(at: directory)
        } else {
            // Cloud album: its cover is in the shared artwork cache, keyed by
            // file id rather than living under any album directory.
            art.invalidateImage(for: album.coverFileId)
        }
    }
}
