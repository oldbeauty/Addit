import Foundation
import SwiftData

extension Notification.Name {
    /// A background add put a track in the store. `userInfo["track"]` is the
    /// `Track`. Posted rather than written into the album page's state because
    /// the page that started the add may be gone, and the one on screen now —
    /// if any — is a different instance that has to hear about it.
    static let albumTrackAdded = Notification.Name("albumTrackAdded")
}

/// Adding tracks from edit mode's + menu, as a background transfer.
///
/// This used to run inside the album page with the + button swapped for a
/// spinner until it finished — which blocked nothing (the work was an
/// unstructured `Task` and outlived the page anyway) but *looked* like it had
/// to be waited out, and said nothing about how far along it was. A stalled
/// upload was a spinner that never stopped. Now it's a `.addTracks` job: the
/// toolbar's `ActivityRing` fills with it (beside Save in edit mode, beside the
/// ellipsis after, and in the library once you've left), and edit mode carries
/// on around it.
extension TransferService {
    /// One file of an add: `add` does the work, reporting bytes as it goes,
    /// and returns the track it put in the store.
    struct PendingTrack {
        let name: String
        /// What this file weighs in the ring. Zero when it isn't known, which
        /// makes the ring move a whole file at a time.
        let bytes: Int64
        let add: (_ progress: @escaping @Sendable (Int64) -> Void) async throws -> Track
    }

    /// Runs `pending` as one job, a file at a time. Failures are collected
    /// rather than stopping the batch — one file Drive refused is no reason to
    /// drop the rest — and reported once, at the end, through `failures`.
    func addTracks(_ pending: [PendingTrack], to album: Album) {
        guard !pending.isEmpty else { return }
        let albumId = album.googleFolderId
        let albumName = album.name
        Task {
            guard let jobId = await begin(albumId: albumId, albumName: albumName, kind: .addTracks) else { return }
            defer { finish(jobId) }

            // A file of unknown size still counts for something, or a batch of
            // them would sit at zero until the end.
            let weights = pending.map { max($0.bytes, 1) }
            let total = weights.reduce(0, +)
            var done: Int64 = 0
            var failed: [String] = []
            var firstError: Error?

            for (item, weight) in zip(pending, weights) {
                update(jobId, current: Int(done), total: Int(total), detail: item.name)
                let base = done
                do {
                    // Strong on purpose: this service lives as long as the app.
                    let track = try await item.add { sent in
                        Task { @MainActor in
                            self.advance(jobId, to: Int(base + min(sent, weight)))
                        }
                    }
                    NotificationCenter.default.post(
                        name: .albumTrackAdded, object: albumId, userInfo: ["track": track]
                    )
                } catch {
                    #if DEBUG
                    print("[AddTracks] \(item.name) failed: \(error)")
                    #endif
                    failed.append(item.name)
                    firstError = firstError ?? error
                }
                done += weight
                update(jobId, current: Int(done), total: Int(total), detail: item.name)
            }

            if let firstError {
                let names = ListFormatter.localizedString(byJoining: failed.map {
                    ($0 as NSString).deletingPathExtension
                })
                let verb = failed.count == 1 ? "wasn't" : "weren't"
                failures[albumId] = "\(names) \(verb) added. \(firstError.localizedDescription)"
            }
        }
    }

}

extension Album {
    /// A file a background add put in this album's cloud folder, as a track.
    /// `bytes` stands in for the size Drive's create response leaves out, so
    /// the row shows one before the next sync fills it in.
    ///
    /// Checks for the track first: a sync that listed the folder after the
    /// file landed but before this ran will already have added it, and a
    /// second `Track` for one file plays twice.
    func addUploadedTrack(_ item: DriveItem, bytes: Int64?, context: ModelContext) -> Track {
        let fileId = item.id
        let folderId = googleFolderId
        let accountId = self.accountId
        let descriptor = FetchDescriptor<Track>(predicate: #Predicate {
            $0.googleFileId == fileId
                && $0.album?.googleFolderId == folderId
                && $0.album?.accountId == accountId
        })
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let track = Track(
            googleFileId: item.id,
            name: item.name,
            album: self,
            mimeType: item.mimeType,
            fileSize: item.fileSizeBytes ?? bytes,
            trackNumber: trackCount + 1,
            modifiedTime: item.modifiedTime
        )
        context.insert(track)
        trackCount += 1
        try? context.save()
        return track
    }
}
