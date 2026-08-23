import Foundation
import SwiftData

/// Turning a cloud folder into an `Album` in the library.
///
/// Extracted from `AddAlbumView` when share links arrived: the picker and an
/// incoming link both have to produce *identically* set-up albums, and the
/// half of this that runs after the save — claiming `.addit-data`, claiming the
/// cover, reading the artist back out — is exactly the sort of thing that
/// silently drifts when it exists twice.
@MainActor
struct AlbumImporter {
    let driveService: any CloudDriveService
    let modelContext: ModelContext

    // MARK: - Lookup

    /// The album already in the library for this folder, if any.
    ///
    /// Scoped by account as well as folder: the same shared Drive folder can
    /// legitimately sit in two accounts' libraries, and they are separate rows.
    func existingAlbum(folderId: String, accountId: String?) -> Album? {
        let descriptor = FetchDescriptor<Album>(
            predicate: #Predicate { $0.googleFolderId == folderId && $0.accountId == accountId }
        )
        return (try? modelContext.fetch(descriptor))?.first
    }

    /// What the picker gets from browsing, for a caller that has only an ID.
    /// Throws whatever the drive client throws — a recipient without
    /// permission lands here, and the error text is the honest thing to show.
    func resolve(folderId: String) async throws -> (folder: DriveItem, audioFiles: [DriveItem]) {
        async let metadata = driveService.getFileMetadata(fileId: folderId)
        async let audio = driveService.listAudioFiles(inFolder: folderId)
        return try await (metadata, audio.files)
    }

    // MARK: - Import

    /// Creates the album and its tracks and saves. Synchronous on purpose: the
    /// row should exist before any network work starts, so the library has
    /// something to show and `finishImport` has something to attach to.
    @discardableResult
    func insert(
        folder: DriveItem,
        audioFiles: [DriveItem],
        accountId: String?,
        storageSource: StorageSource
    ) throws -> Album {
        let existingAlbums = (try? modelContext.fetch(FetchDescriptor<Album>())) ?? []
        let nextOrder = (existingAlbums.map(\.displayOrder).max() ?? -1) + 1

        let album = Album(
            googleFolderId: folder.id,
            name: folder.name,
            trackCount: audioFiles.count,
            canEdit: folder.canEdit,
            displayOrder: nextOrder,
            storageSource: storageSource
        )
        album.accountId = accountId
        modelContext.insert(album)

        for (index, file) in audioFiles.enumerated() {
            let track = Track(
                googleFileId: file.id,
                name: file.name,
                album: album,
                mimeType: file.mimeType,
                fileSize: file.fileSizeBytes,
                trackNumber: index + 1,
                modifiedTime: file.modifiedTime
            )
            modelContext.insert(track)
        }

        try modelContext.save()
        return album
    }

    /// Everything that needs the network, after the album is already visible.
    /// Every step is best-effort — a folder you can only read will fail the
    /// ownership claims, and that is the normal shared-album case, not an error.
    func finishImport(of album: Album, audioFiles: [DriveItem]) async {
        let folderMeta = try? await driveService.getFileMetadata(fileId: album.googleFolderId)
        album.isFolderOwner = folderMeta?.ownedByMe ?? false
        try? modelContext.save()

        await initializeAdditData(for: album, audioFiles: audioFiles)
        await loadAdditMetadata(for: album)
        if album.isFolderOwner {
            await claimCoverOwnership(for: album)
        }
        await syncCoverArt(for: album)
    }

    // MARK: - Steps

    private func initializeAdditData(for album: Album, audioFiles: [DriveItem]) async {
        do {
            let existing = try await driveService.findFile(named: ".addit-data", inFolder: album.googleFolderId)

            if let existing {
                // File exists — claim ownership if we're the folder owner and don't own it
                if album.isFolderOwner && existing.ownedByMe == false {
                    let oldData = try await driveService.downloadFileData(fileId: existing.id)
                    try await driveService.removeFileFromFolder(fileId: existing.id, folderId: album.googleFolderId)
                    _ = try await driveService.createFile(
                        name: ".addit-data",
                        mimeType: "application/json",
                        inFolder: album.googleFolderId,
                        data: oldData
                    )
                }
                // If we already own it or aren't the folder owner, nothing to do
                return
            }

            // File doesn't exist — create it
            let metadata = AdditMetadata(tracklist: audioFiles.map(\.name))
            let data = try JSONEncoder().encode(metadata)

            _ = try await driveService.createFile(
                name: ".addit-data",
                mimeType: "application/json",
                inFolder: album.googleFolderId,
                data: data
            )
        } catch {
            // Best effort — will be created on next sync or edit
        }
    }

    private func loadAdditMetadata(for album: Album) async {
        do {
            guard let additData = try await driveService.findFile(named: ".addit-data", inFolder: album.googleFolderId) else { return }
            let data = try await driveService.downloadFileData(fileId: additData.id)
            let metadata = try JSONDecoder().decode(AdditMetadata.self, from: data)
            if let artist = metadata.artist, !artist.isEmpty {
                album.artistName = artist
            }
            album.additDataFileId = additData.id
            try? modelContext.save()
        } catch {
            // Best effort
        }
    }

    private func claimCoverOwnership(for album: Album) async {
        do {
            guard let existing = try await driveService.findCoverImage(inFolder: album.googleFolderId) else { return }
            guard existing.ownedByMe == false else { return }

            let data = try await driveService.downloadFileData(fileId: existing.id)
            try await driveService.removeFileFromFolder(fileId: existing.id, folderId: album.googleFolderId)
            let newCover = try await driveService.createFile(
                name: existing.name,
                mimeType: existing.mimeType,
                inFolder: album.googleFolderId,
                data: data
            )
            album.coverFileId = newCover.id
            album.coverMimeType = newCover.mimeType
            album.coverModifiedTime = newCover.modifiedTime
            try? modelContext.save()
        } catch {
            // Best effort — cover still usable even if not owned
        }
    }

    private func syncCoverArt(for album: Album) async {
        let coverItem = try? await driveService.findCoverImage(inFolder: album.googleFolderId)
        if let coverItem {
            album.coverFileId = coverItem.id
            album.coverMimeType = coverItem.mimeType
            album.coverModifiedTime = coverItem.modifiedTime
            album.coverUpdatedAt = .now
        } else {
            album.coverFileId = nil
            album.coverMimeType = nil
            album.coverModifiedTime = nil
            album.coverUpdatedAt = nil
        }
        try? modelContext.save()
    }
}
