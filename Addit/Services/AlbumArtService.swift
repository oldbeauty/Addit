import Foundation
import UIKit
import SwiftData

struct AlbumArtResolution {
    let image: UIImage?
    let resolvedCoverItem: DriveItem?
    let shouldPersistMetadata: Bool
}

@Observable
final class AlbumArtService {
    var driveService: GoogleDriveService?
    private(set) var artworkRefreshVersion = 0
    private(set) var lastUpdatedAlbumFolderId: String?

    private let fileManager = FileManager.default
    private let memoryCache = NSCache<NSString, UIImage>()

    private var cacheDirectory: URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("AlbumArt", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func resolveAlbumArt(for album: Album) async -> AlbumArtResolution {
        if let coverFileId = album.coverFileId, let cachedImage = await image(for: coverFileId) {
            return AlbumArtResolution(image: cachedImage, resolvedCoverItem: nil, shouldPersistMetadata: false)
        }

        guard let driveService else {
            let fallbackImage = await fallbackImage(for: album)
            return AlbumArtResolution(image: fallbackImage, resolvedCoverItem: nil, shouldPersistMetadata: false)
        }

        do {
            let coverItem = try await driveService.findCoverImage(inFolder: album.googleFolderId)

            let resolvedImage: UIImage?
            if let coverItem {
                resolvedImage = await image(for: coverItem.id)
            } else {
                resolvedImage = nil
            }
            return AlbumArtResolution(image: resolvedImage, resolvedCoverItem: coverItem, shouldPersistMetadata: true)
        } catch {
            let fallbackImage = await fallbackImage(for: album)
            return AlbumArtResolution(image: fallbackImage, resolvedCoverItem: nil, shouldPersistMetadata: false)
        }
    }

    @discardableResult
    func cacheImageData(_ data: Data, for fileId: String) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }

        memoryCache.setObject(image, forKey: fileId as NSString)
        try? data.write(to: localURL(for: fileId), options: [.atomic])
        return image
    }

    func invalidateImage(for fileId: String?) {
        guard let fileId else { return }

        memoryCache.removeObject(forKey: fileId as NSString)
        try? fileManager.removeItem(at: localURL(for: fileId))
    }

    func clearCache() {
        memoryCache.removeAllObjects()
        if fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.removeItem(at: cacheDirectory)
        }
    }

    func bumpRefreshToken(for albumFolderId: String) {
        lastUpdatedAlbumFolderId = albumFolderId
        artworkRefreshVersion += 1
    }

    @MainActor
    func applyResolution(_ resolution: AlbumArtResolution, to album: Album, modelContext: ModelContext) {
        guard resolution.shouldPersistMetadata else { return }

        let previousCoverFileId = album.coverFileId
        let previousCoverMimeType = album.coverMimeType
        let previousCoverUpdatedAt = album.coverUpdatedAt

        if let coverItem = resolution.resolvedCoverItem {
            album.coverFileId = coverItem.id
            album.coverMimeType = coverItem.mimeType
            if previousCoverFileId != coverItem.id || previousCoverMimeType != coverItem.mimeType || previousCoverUpdatedAt == nil {
                album.coverUpdatedAt = .now
            }
        } else {
            album.coverFileId = nil
            album.coverMimeType = nil
            album.coverUpdatedAt = nil
        }

        if previousCoverFileId != album.coverFileId {
            invalidateImage(for: previousCoverFileId)
        }

        let didChangeMetadata = previousCoverFileId != album.coverFileId
            || previousCoverMimeType != album.coverMimeType
            || previousCoverUpdatedAt != album.coverUpdatedAt

        if didChangeMetadata {
            bumpRefreshToken(for: album.googleFolderId)
            try? modelContext.save()
        }
    }

    func image(for fileId: String) async -> UIImage? {
        if let cached = memoryCache.object(forKey: fileId as NSString) {
            return cached
        }

        let localURL = localURL(for: fileId)
        if let data = try? Data(contentsOf: localURL), let image = UIImage(data: data) {
            memoryCache.setObject(image, forKey: fileId as NSString)
            return image
        }

        guard let driveService else { return nil }
        do {
            let data = try await driveService.downloadFileData(fileId: fileId)
            return cacheImageData(data, for: fileId)
        } catch {
            return nil
        }
    }

    private func localURL(for fileId: String) -> URL {
        cacheDirectory.appendingPathComponent("\(fileId).jpg")
    }

    private func fallbackImage(for album: Album) async -> UIImage? {
        guard let coverFileId = album.coverFileId else { return nil }
        return await image(for: coverFileId)
    }
}
