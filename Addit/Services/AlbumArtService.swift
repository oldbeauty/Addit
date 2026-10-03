import Foundation
import ImageIO
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
    /// When set, requests route per-album / per-fileId to the right cloud
    /// provider; `driveService` remains as a Google-only fallback.
    var cloudRouter: CloudServiceRouter?
    var activeAccountId: String?

    private func client(for album: Album) -> (any CloudDriveService)? {
        cloudRouter?.service(for: album) ?? driveService
    }

    private func client(forFileId fileId: String) -> (any CloudDriveService)? {
        cloudRouter?.service(forFileId: fileId) ?? driveService
    }
    private(set) var artworkRefreshVersion = 0
    private(set) var lastUpdatedAlbumFolderId: String?

    private let fileManager = FileManager.default
    /// Covers at their original size. Whatever the provider stored — often
    /// 1500px or more square. Only the screens that show a cover *large* should
    /// be pulling from here.
    private let memoryCache = NSCache<NSString, UIImage>()
    /// Covers reduced to the size they're actually drawn at, keyed
    /// `<identity>@<pixels>`.
    ///
    /// Grid and list thumbnails come from here instead of scaling a full-size
    /// cover down on the fly, which was costing three separate things: the GPU
    /// resampled a multi-megapixel texture into a 148pt square on every frame
    /// it composited, the decoded originals filled the cache until it started
    /// evicting and re-decoding them mid-scroll, and the decode itself happened
    /// on the main thread on the frame a row appeared. A thumbnail is built
    /// once, off the main thread, straight out of the file at the size asked
    /// for — `ImageIO` never decodes the full image to do it.
    private let thumbnailCache = NSCache<NSString, UIImage>()

    private var cacheDirectory: URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let base = caches.appendingPathComponent("AlbumArt", isDirectory: true)
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
    func clearCache(for accountId: String) {
        memoryCache.removeAllObjects()
        thumbnailCache.removeAllObjects()
        localIdentities.removeAll()
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("AlbumArt", isDirectory: true)
            .appendingPathComponent(accountId, isDirectory: true)
        if fileManager.fileExists(atPath: dir.path) {
            try? fileManager.removeItem(at: dir)
        }
    }

    func resolveAlbumArt(for album: Album) async -> AlbumArtResolution {
        if let coverFileId = album.coverFileId, let cachedImage = await image(for: coverFileId) {
            return AlbumArtResolution(image: cachedImage, resolvedCoverItem: nil, shouldPersistMetadata: false)
        }

        guard let client = client(for: album) else {
            let fallbackImage = await fallbackImage(for: album)
            return AlbumArtResolution(image: fallbackImage, resolvedCoverItem: nil, shouldPersistMetadata: false)
        }

        do {
            let coverItem = try await client.findCoverImage(inFolder: album.googleFolderId)

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
        // New bytes under an id we may already have thumbnails for — a cover
        // replaced in place keeps its file id on Drive.
        invalidateThumbnails(for: fileId)
        try? data.write(to: localURL(for: fileId), options: [.atomic])
        return image
    }

    /// Fast synchronous lookup — memory cache only, no file I/O or network.
    func cachedImage(for fileId: String) -> UIImage? {
        memoryCache.object(forKey: fileId as NSString)
    }

    // MARK: - Thumbnails

    /// Longest side, in pixels, for a cover shown *large* — the album page's
    /// hero, the now-playing artwork, the lock screen.
    ///
    /// Above the biggest any current iPhone draws (a ~430pt square at 3×), so
    /// the art is never scaled up, and far below what a photo out of the camera
    /// roll actually is. One number because these are one job: "as big as this
    /// app ever needs a cover."
    static let displayPixels = 1280

    /// Every thumbnail size that has been asked for, so an invalidation can
    /// find them all again. Small and bounded — the app draws covers at two or
    /// three sizes.
    ///
    /// `NSCache` deliberately offers no key enumeration (it evicts behind your
    /// back), so the keys have to be tracked separately to be able to drop a
    /// stale cover's thumbnails without dropping everyone's.
    private static var requestedPixelSizes = Set<Int>()

    private static func thumbnailKey(_ identity: String, _ pixelSize: Int) -> NSString {
        "\(identity)@\(pixelSize)" as NSString
    }

    /// Fast synchronous lookup — memory only, no I/O. What a cover reads as it
    /// draws, so one that scrolls back into view, or a new copy of one already
    /// on screen, has its art on its first frame.
    func cachedThumbnail(for identity: String, pixelSize: Int) -> UIImage? {
        thumbnailCache.object(forKey: Self.thumbnailKey(identity, pixelSize))
    }

    /// A cloud cover at `pixelSize` pixels on its longest side, downloading it
    /// first if this device has never seen it.
    func thumbnail(for fileId: String, pixelSize: Int) async -> UIImage? {
        if let hit = cachedThumbnail(for: fileId, pixelSize: pixelSize) { return hit }

        let url = localURL(for: fileId)
        if let made = await makeThumbnail(at: url, identity: fileId, pixelSize: pixelSize) {
            return made
        }

        // Not on disk yet. `image(for:)` is the one that knows how to fetch and
        // where to put it; once it has, the file is there to be thumbnailed.
        guard await image(for: fileId) != nil else { return nil }
        return await makeThumbnail(at: url, identity: fileId, pixelSize: pixelSize)
    }

    /// The identity most recently worked out for a local cover path, so the
    /// synchronous lookup below never has to touch the filesystem.
    ///
    /// One entry per local album, and only ever written from the async path,
    /// which re-stats every time it runs. A stale entry is therefore possible
    /// for exactly one frame — a cover's first, before the task that follows
    /// it refreshes both this and the image.
    ///
    /// Unobserved: covers read it while they draw (`AlbumArtworkThumbnail`),
    /// and as an observed property every cover that finished loading would
    /// redraw every cover still waiting.
    @ObservationIgnored private var localIdentities: [String: String] = [:]

    /// A cover already sitting in the app's own Documents — a local album's.
    ///
    /// Keyed by path *and* modification date: local covers are rewritten in
    /// place at `LocalAlbums/<id>/cover.jpg`, so the path alone would serve the
    /// old artwork forever after an edit. The stat that reads that date happens
    /// off the main thread with the decode.
    func thumbnail(atPath path: String, pixelSize: Int) async -> UIImage? {
        let url = URL(fileURLWithPath: path)
        let identity = await Task.detached(priority: .userInitiated) {
            Self.localIdentity(for: url)
        }.value
        localIdentities[path] = identity

        if let hit = cachedThumbnail(for: identity, pixelSize: pixelSize) { return hit }
        return await makeThumbnail(at: url, identity: identity, pixelSize: pixelSize)
    }

    /// The synchronous half of the local lookup, read as a cover draws. A
    /// dictionary hit or nothing — no `stat`, no read, nothing that can block a
    /// frame.
    func cachedThumbnail(atPath path: String, pixelSize: Int) -> UIImage? {
        guard let identity = localIdentities[path] else { return nil }
        return cachedThumbnail(for: identity, pixelSize: pixelSize)
    }

    /// Drop every size held for one cover.
    func invalidateThumbnails(for identity: String) {
        for size in Self.requestedPixelSizes {
            thumbnailCache.removeObject(forKey: Self.thumbnailKey(identity, size))
        }
    }

    /// As above, for a local album's cover file. Called from the one place that
    /// overwrites a local cover in place; the `stat` here is on an edit, not on
    /// a scroll.
    func invalidateThumbnails(atPath path: String) {
        invalidateThumbnails(for: Self.localIdentity(for: URL(fileURLWithPath: path)))
        localIdentities[path] = nil
    }

    private func makeThumbnail(at url: URL, identity: String, pixelSize: Int) async -> UIImage? {
        Self.requestedPixelSizes.insert(pixelSize)
        let thumbnail = await Task.detached(priority: .userInitiated) {
            Self.thumbnail(fromFileAt: url, pixelSize: pixelSize)
        }.value
        guard let thumbnail else { return nil }
        thumbnailCache.setObject(thumbnail, forKey: Self.thumbnailKey(identity, pixelSize))
        return thumbnail
    }

    /// Path plus modification time, which is what makes a rewritten local cover
    /// a different cover as far as the cache is concerned.
    ///
    /// `nonisolated` because the scroll path calls it from a detached task —
    /// this reads the filesystem, and doing that on the main thread is the
    /// thing the whole thumbnail path exists to stop.
    nonisolated private static func localIdentity(for url: URL) -> String {
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?
            .timeIntervalSince1970 ?? 0
        return "\(url.path)#\(Int(stamp))"
    }

    /// Decode straight to the size wanted.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` reads the file's own sub-sampled
    /// representations where they exist and never materialises the full-size
    /// bitmap where they don't — which is the entire reason this isn't
    /// `UIImage(contentsOfFile:)` followed by a resize. `ShouldCacheImmediately`
    /// forces the decode to happen *here*, on this background thread, rather
    /// than lazily on the main thread at first draw.
    nonisolated private static func thumbnail(fromFileAt url: URL, pixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    func invalidateImage(for fileId: String?) {
        guard let fileId else { return }
        invalidateThumbnails(for: fileId)

        memoryCache.removeObject(forKey: fileId as NSString)
        try? fileManager.removeItem(at: localURL(for: fileId))
    }

    func clearCache() {
        memoryCache.removeAllObjects()
        thumbnailCache.removeAllObjects()
        localIdentities.removeAll()
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

        // Read disk cache off the main thread
        let url = localURL(for: fileId)
        let diskImage: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
        if let diskImage {
            memoryCache.setObject(diskImage, forKey: fileId as NSString)
            return diskImage
        }

        guard let client = client(forFileId: fileId) else { return nil }
        do {
            let data = try await client.downloadFileData(fileId: fileId)
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
