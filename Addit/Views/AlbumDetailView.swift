import SwiftUI
import SwiftData
import UIKit

struct AlbumDetailView: View {
    let album: Album
    @Environment(AudioPlayerService.self) private var playerService
    @Environment(GoogleDriveService.self) private var driveService
    @Environment(AlbumArtService.self) private var albumArtService
    @Environment(ThemeService.self) private var themeService
    @Environment(AudioCacheService.self) private var cacheService
    @Environment(\.modelContext) private var modelContext
    @State private var isSyncing = true
    @State private var cachedTrackIds: Set<String> = []
    @State private var syncError: String?
    @State private var showEditSheet = false
    @State private var showSharingSheet = false
    @State private var navigateToChat = false
    @State private var albumImage: UIImage?
    @State private var queuedTrackId: String?
    @State private var displayItems: [TracklistItem] = []
    @State private var showToolbarActions = false
    @State private var toolbarActionGeneration = 0
    @State private var shareFileURL: URL?
    @State private var isDownloadingAlbum = false

    private let coverSize: CGFloat = 200

    private var sortedTracks: [Track] {
        album.tracks.sorted { $0.trackNumber < $1.trackNumber }
    }

    private var playableTracks: [Track] {
        displayItems.compactMap(\.asTrack)
    }

    /// Pre-computed track numbers keyed by track's googleFileId, avoiding O(n²) per-row filtering.
    private var trackNumbers: [String: Int] {
        var numbers: [String: Int] = [:]
        var count = 0
        for item in displayItems {
            if case .track(let track) = item {
                count += 1
                numbers[track.googleFileId] = count
            }
        }
        return numbers
    }

    private var artworkTaskID: String? {
        let refreshMarker = albumArtService.lastUpdatedAlbumFolderId == album.googleFolderId
            ? albumArtService.artworkRefreshVersion
            : 0
        return "\(album.coverArtTaskID)-\(refreshMarker)-\(album.localCoverPath ?? "")"
    }

    var body: some View {
        List {
            if isSyncing && album.tracks.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Syncing from Drive...")
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                // Album header: cover art, title, artist, play buttons
                Section {
                    VStack(spacing: 16) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [themeService.accentColor.opacity(0.6), themeService.accentColor.opacity(0.3)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: coverSize, height: coverSize)
                            .overlay {
                                if let albumImage {
                                    Image(uiImage: albumImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: coverSize, height: coverSize)
                                        .clipped()
                                } else {
                                    Image(systemName: "music.note")
                                        .font(.system(size: 48))
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        VStack(spacing: 4) {
                            Text(album.name)
                                .font(.title2.bold())
                                .multilineTextAlignment(.center)
                                .lineLimit(2)

                            Text(album.artistName ?? "Unknown Artist")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 12) {
                            Button {
                                playerService.playAlbum(album)
                            } label: {
                                Image(systemName: "play.fill")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                playerService.playAlbum(album, shuffled: true)
                            } label: {
                                Image(systemName: "shuffle")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    ForEach(Array(displayItems.enumerated()), id: \.element.id) { _, item in
                        switch item {
                        case .track(let track):
                            TrackRow(
                                track: track,
                                number: trackNumbers[track.googleFileId] ?? 0,
                                isCurrentTrack: playerService.currentTrack?.googleFileId == track.googleFileId,
                                isPlaying: playerService.currentTrack?.googleFileId == track.googleFileId && playerService.isPlaying,
                                isCached: track.isLocal || cachedTrackIds.contains(track.googleFileId),
                                isLocal: album.isLocal,
                                onToggleCache: {
                                    toggleCache(for: track)
                                },
                                onDownload: {
                                    downloadAndShare(track: track)
                                }
                            )
                            .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                            .listRowBackground(Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                playerService.playTrack(track, inQueue: playableTracks)
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    playerService.addToQueue(track)
                                    queuedTrackId = track.googleFileId
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    Task {
                                        try? await Task.sleep(for: .seconds(1.5))
                                        if queuedTrackId == track.googleFileId {
                                            queuedTrackId = nil
                                        }
                                    }
                                } label: {
                                    Label("Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                                }
                                .tint(themeService.accentColor)
                            }
                            .overlay(alignment: .trailing) {
                                if queuedTrackId == track.googleFileId {
                                    Text("Queued")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(themeService.accentColor, in: Capsule())
                                        .transition(.opacity.combined(with: .scale))
                                        .padding(.trailing, 8)
                                }
                            }
                            .animation(.easeInOut(duration: 0.2), value: queuedTrackId)
                        case .discMarker(_, let label):
                            DiscMarkerRow(label: label)
                                .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }
                }

                if let syncError {
                    Section {
                        Label(syncError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showToolbarActions.toggle()
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .simultaneousGesture(
            showToolbarActions
                ? TapGesture().onEnded {
                    withAnimation(.easeIn(duration: 0.2)) { showToolbarActions = false }
                }
                : nil
        )
        .simultaneousGesture(
            showToolbarActions
                ? DragGesture(minimumDistance: 5).onChanged { _ in
                    withAnimation(.easeIn(duration: 0.2)) { showToolbarActions = false }
                }
                : nil
        )
        .overlay(alignment: .topTrailing) {
            if showToolbarActions {
                VStack(alignment: .trailing, spacing: 0) {
                    if !album.isLocal {
                        Button {
                            showSharingSheet = true
                            withAnimation { showToolbarActions = false }
                        } label: {
                            Label("Sharing", systemImage: "person.2")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        Divider()

                        Button {
                            navigateToChat = true
                            withAnimation { showToolbarActions = false }
                        } label: {
                            Label("Chat", systemImage: "bubble.left")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        Divider()
                    }

                    Button {
                        showEditSheet = true
                        withAnimation { showToolbarActions = false }
                    } label: {
                        Label("Edit", systemImage: "pencil")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    if !album.isLocal {
                        Divider()

                        Button {
                            toggleAllCache()
                            withAnimation { showToolbarActions = false }
                        } label: {
                            Label(
                                allTracksCached ? "Remove Offline Access" : "Make Available Offline",
                                systemImage: allTracksCached ? "xmark.circle" : "arrow.down.circle"
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }

                    Divider()

                    Button {
                        downloadAlbumAsZip()
                        withAnimation { showToolbarActions = false }
                    } label: {
                        Label("Download", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .frame(width: 230)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.trailing, 16)
                .padding(.top, 4)
                .transition(.opacity.combined(with: .scale(scale: 0.5, anchor: .topTrailing)))
            }
        }
        .sheet(isPresented: $showSharingSheet) {
            SharingSheet(album: album)
        }
        .navigationDestination(isPresented: $navigateToChat) {
            ChatView(album: album)
        }
        .sheet(isPresented: Binding(
            get: { shareFileURL != nil },
            set: { if !$0 { shareFileURL = nil } }
        )) {
            if let url = shareFileURL {
                ShareSheet(activityItems: [url])
            }
        }
        .sheet(isPresented: $showEditSheet, onDismiss: {
            if album.isLocal {
                if !album.cachedTracklist.isEmpty {
                    buildDisplayItems(from: AdditMetadata(tracklist: album.cachedTracklist))
                } else {
                    buildDisplayItems(from: nil)
                }
            } else {
                Task { await syncFromDrive() }
            }
        }) {
            AlbumMetadataEditorSheet(album: album)
        }
        .refreshable {
            await syncFromDrive()
        }
        .task {
            if album.isLocal {
                isSyncing = false
                if !album.cachedTracklist.isEmpty {
                    buildDisplayItems(from: AdditMetadata(tracklist: album.cachedTracklist))
                } else {
                    buildDisplayItems(from: nil)
                }
            } else {
                await syncFromDrive()
            }
            refreshCachedState()
        }
        .onChange(of: playerService.currentTrack?.googleFileId) {
            refreshCachedState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .audioCacheDidChange)) { _ in
            refreshCachedState()
        }
        .task(id: artworkTaskID) {
            if album.isLocal {
                if let coverPath = album.localCoverPath {
                    albumImage = UIImage(contentsOfFile: coverPath)
                }
            } else {
                let resolution = await albumArtService.resolveAlbumArt(for: album)
                albumImage = resolution.image
                albumArtService.applyResolution(resolution, to: album, modelContext: modelContext)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if playerService.currentTrack != nil {
                Color.clear.frame(height: 64)
            }
        }
    }

    // MARK: - Cache

    private var allTracksCached: Bool {
        !album.tracks.isEmpty && cachedTrackIds.count == album.tracks.count
    }

    private func toggleAllCache() {
        if allTracksCached {
            for track in album.tracks {
                cacheService.removeTrack(track)
            }
            cachedTrackIds.removeAll()
        } else {
            Task {
                for track in album.tracks where !cachedTrackIds.contains(track.googleFileId) {
                    do {
                        _ = try await cacheService.cacheTrack(track)
                        cachedTrackIds.insert(track.googleFileId)
                    } catch {
                        // Skip failed tracks
                    }
                }
            }
        }
    }

    private func refreshCachedState() {
        cachedTrackIds = Set(
            album.tracks
                .filter { cacheService.cachedFileURL(for: $0) != nil }
                .map(\.googleFileId)
        )
    }

    private func toggleCache(for track: Track) {
        if cachedTrackIds.contains(track.googleFileId) {
            cacheService.removeTrack(track)
            cachedTrackIds.remove(track.googleFileId)
        } else {
            Task {
                do {
                    _ = try await cacheService.cacheTrack(track)
                    cachedTrackIds.insert(track.googleFileId)
                } catch {
                    // Download failed silently
                }
            }
        }
    }

    private func downloadAlbumAsZip() {
        guard !isDownloadingAlbum else { return }
        isDownloadingAlbum = true
        Task {
            defer { isDownloadingAlbum = false }
            do {
                let fm = FileManager.default
                let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let albumDir = tempDir.appendingPathComponent(album.name)
                try fm.createDirectory(at: albumDir, withIntermediateDirectories: true)

                // Download all tracks
                for track in sortedTracks {
                    let fileURL = try await cacheService.cacheTrack(track)
                    cachedTrackIds.insert(track.googleFileId)
                    let destination = albumDir.appendingPathComponent(track.name)
                    try fm.copyItem(at: fileURL, to: destination)
                }

                // Download cover if present
                if let coverFileId = album.coverFileId {
                    let coverData = try await driveService.downloadFileData(fileId: coverFileId)
                    let ext: String
                    switch album.coverMimeType {
                    case "image/png": ext = "png"
                    case "image/gif": ext = "gif"
                    case "image/webp": ext = "webp"
                    default: ext = "jpg"
                    }
                    let coverURL = albumDir.appendingPathComponent("cover.\(ext)")
                    try coverData.write(to: coverURL)
                }

                // Download addit-data if present
                if let additDataId = album.additDataFileId {
                    let additData = try await driveService.downloadFileData(fileId: additDataId)
                    let additURL = albumDir.appendingPathComponent(".addit-data")
                    try additData.write(to: additURL)
                }

                // Create zip using FileManager's built-in support (NSFileCoordinator)
                let zipURL = tempDir.appendingPathComponent("\(album.name).zip")
                let coordinator = NSFileCoordinator()
                var coordinatorError: NSError?
                var resultURL: URL?

                coordinator.coordinate(readingItemAt: albumDir, options: .forUploading, error: &coordinatorError) { tempZipURL in
                    do {
                        try fm.copyItem(at: tempZipURL, to: zipURL)
                        resultURL = zipURL
                    } catch {
                        print("Failed to copy zip: \(error)")
                    }
                }

                if let error = coordinatorError {
                    throw error
                }

                if let zipURL = resultURL {
                    shareFileURL = zipURL
                }

                // Clean up the unzipped folder
                try? fm.removeItem(at: albumDir)
            } catch {
                print("Failed to create album zip: \(error)")
            }
        }
    }

    private func downloadAndShare(track: Track) {
        Task {
            do {
                let fileURL = try await cacheService.cacheTrack(track)
                cachedTrackIds.insert(track.googleFileId)
                // Copy to temp directory with the original filename so the share sheet shows the proper name
                let tempDir = FileManager.default.temporaryDirectory
                let destination = tempDir.appendingPathComponent(track.displayName + "." + track.fileExtension)
                let fm = FileManager.default
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(at: fileURL, to: destination)
                shareFileURL = destination
            } catch {
                print("Failed to download track for sharing: \(error)")
            }
        }
    }

    // MARK: - Sync

    private func syncFromDrive() async {
        isSyncing = true
        syncError = nil
        defer { isSyncing = false }

        // Show existing tracks (with cached disc markers) immediately while syncing
        if displayItems.isEmpty && !album.tracks.isEmpty {
            if !album.cachedTracklist.isEmpty {
                buildDisplayItems(from: AdditMetadata(tracklist: album.cachedTracklist))
            } else {
                displayItems = sortedTracks.map { .track($0) }
            }
        }

        do {
            // Refresh folder name and permissions from Drive
            if let folderInfo = try? await driveService.getFileMetadata(fileId: album.googleFolderId) {
                album.name = folderInfo.name
                album.canEdit = folderInfo.canEdit
                album.isFolderOwner = folderInfo.ownedByMe ?? false
            }

            let response = try await driveService.listAudioFiles(inFolder: album.googleFolderId)
            let driveFiles = response.files
            let driveIds = Set(driveFiles.map(\.id))
            let localIds = Set(album.tracks.map(\.googleFileId))

            // Remove tracks that no longer exist on Drive
            for track in album.tracks where !driveIds.contains(track.googleFileId) {
                modelContext.delete(track)
            }

            // Add new tracks from Drive
            for (index, file) in driveFiles.enumerated() where !localIds.contains(file.id) {
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

            // Update names and file sizes for existing tracks
            for file in driveFiles {
                if let existing = album.tracks.first(where: { $0.googleFileId == file.id }) {
                    existing.name = file.name
                    existing.modifiedTime = file.modifiedTime
                    if let size = file.fileSizeBytes {
                        existing.fileSize = size
                    }
                }
            }

            // Sync addit metadata (tracklist ordering + artist name)
            await syncAdditMetadata(driveFiles: driveFiles)

            // Sync JPEG cover art metadata
            await syncCoverArtMetadata()

            album.trackCount = driveFiles.count
            try? modelContext.save()
        } catch {
            syncError = "Couldn't sync: \(error.localizedDescription)"
        }
    }

    private func syncAdditMetadata(driveFiles: [DriveItem]) async {
        var metadata: AdditMetadata?

        // Try .addit-data (JSON) first
        do {
            if let item = try await driveService.findFile(named: ".addit-data", inFolder: album.googleFolderId) {
                album.additDataFileId = item.id
                let data = try await driveService.downloadFileData(fileId: item.id)
                metadata = try? JSONDecoder().decode(AdditMetadata.self, from: data)
            }
        } catch {
            // Fall through to legacy
        }

        // Legacy fallback: read .addit-tracklist and .addit-artist separately
        if metadata == nil {
            var legacy = AdditMetadata()

            if let item = try? await driveService.findFile(named: ".addit-tracklist", inFolder: album.googleFolderId),
               let data = try? await driveService.downloadFileData(fileId: item.id),
               let content = String(data: data, encoding: .utf8) {
                legacy.tracklist = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
            }

            if let item = try? await driveService.findFile(named: ".addit-artist", inFolder: album.googleFolderId),
               let data = try? await driveService.downloadFileData(fileId: item.id),
               let content = String(data: data, encoding: .utf8) {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                legacy.artist = trimmed.isEmpty ? nil : trimmed
            }

            if legacy.tracklist != nil || legacy.artist != nil {
                metadata = legacy
            }
        }

        // Apply artist name
        if let metadata {
            if let artist = metadata.artist {
                album.artistName = artist.isEmpty ? nil : artist
            }
        }

        // Apply track ordering (skip disc markers)
        if let orderedNames = metadata?.tracklist, !orderedNames.isEmpty {
            var trackNumber = 1

            for name in orderedNames {
                if name.hasPrefix(AdditMetadata.discMarkerPrefix) { continue }
                if let track = album.tracks.first(where: { $0.name == name }) {
                    track.trackNumber = trackNumber
                    trackNumber += 1
                }
            }

            let listedNames = Set(orderedNames.filter { !$0.hasPrefix(AdditMetadata.discMarkerPrefix) })
            let unlistedTracks = album.tracks
                .filter { !listedNames.contains($0.name) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            for track in unlistedTracks {
                track.trackNumber = trackNumber
                trackNumber += 1
            }
        } else {
            // Default: order from Drive API response
            for (index, file) in driveFiles.enumerated() {
                if let track = album.tracks.first(where: { $0.googleFileId == file.id }) {
                    track.trackNumber = index + 1
                }
            }
        }

        // Build display items with disc markers interleaved
        buildDisplayItems(from: metadata)

        // Cache tracklist for instant display on next visit
        album.cachedTracklist = metadata?.tracklist ?? []
    }

    private func buildDisplayItems(from metadata: AdditMetadata?) {
        guard let orderedNames = metadata?.tracklist, !orderedNames.isEmpty else {
            displayItems = sortedTracks.map { .track($0) }
            return
        }

        var items: [TracklistItem] = []
        var matchedIds = Set<String>()

        for name in orderedNames {
            if name.hasPrefix(AdditMetadata.discMarkerPrefix) {
                let label = String(name.dropFirst(AdditMetadata.discMarkerPrefix.count))
                items.append(.discMarker(id: UUID(), label: label))
            } else if let track = album.tracks.first(where: { $0.name == name && !matchedIds.contains($0.googleFileId) }) {
                items.append(.track(track))
                matchedIds.insert(track.googleFileId)
            }
        }

        // Append any tracks not in the tracklist
        let unmatched = album.tracks
            .filter { !matchedIds.contains($0.googleFileId) }
            .sorted { $0.trackNumber < $1.trackNumber }
        for track in unmatched {
            items.append(.track(track))
        }

        displayItems = items
    }

    private func syncCoverArtMetadata() async {
        do {
            let coverItem = try await driveService.findCoverImage(inFolder: album.googleFolderId)

            if let coverItem {
                let fileIdChanged = album.coverFileId != coverItem.id
                let contentChanged = coverItem.modifiedTime != nil && coverItem.modifiedTime != album.coverModifiedTime

                if fileIdChanged || contentChanged {
                    // Invalidate cached image so it gets re-downloaded with fresh content
                    if let oldId = album.coverFileId {
                        albumArtService.invalidateImage(for: oldId)
                    }
                    if fileIdChanged {
                        albumArtService.invalidateImage(for: coverItem.id)
                    }
                }

                album.coverFileId = coverItem.id
                album.coverMimeType = coverItem.mimeType
                album.coverModifiedTime = coverItem.modifiedTime
                album.coverUpdatedAt = .now
            } else {
                if let oldId = album.coverFileId {
                    albumArtService.invalidateImage(for: oldId)
                }
                album.coverFileId = nil
                album.coverMimeType = nil
                album.coverModifiedTime = nil
                album.coverUpdatedAt = nil
            }
        } catch {
            // Keep existing cover metadata on error
        }
    }
}

struct TrackRow: View {
    let track: Track
    let number: Int
    let isCurrentTrack: Bool
    let isPlaying: Bool
    let isCached: Bool
    var isLocal: Bool = false
    var onToggleCache: (() -> Void)?
    var onDownload: (() -> Void)?
    @Environment(ThemeService.self) private var themeService

    var body: some View {
        HStack(spacing: 12) {
            if isCurrentTrack {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(themeService.accentColor)
                    .frame(width: 24)
            } else {
                Text("\(number)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayName)
                    .font(.body)
                    .foregroundStyle(isCurrentTrack ? themeService.accentColor : .primary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if isCached {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let size = track.fileSize {
                        Text(formatFileSize(size))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Menu {
                // File info section
                Section {
                    HStack {
                        if let date = track.formattedModifiedDate {
                            Text(date)
                                .font(.system(size: 9))
                        }
                        if track.formattedModifiedDate != nil && !track.fileExtension.isEmpty {
                            Divider()
                        }
                        if !track.fileExtension.isEmpty {
                            Text(track.fileExtension)
                                .font(.system(size: 9))
                        }
                    }
                    .frame(height: 10)
                }

                Button {
                    onDownload?()
                } label: {
                    Label("Download", systemImage: "square.and.arrow.up")
                }

                if !isLocal {
                    Button {
                        onToggleCache?()
                    } label: {
                        if isCached {
                            Label("Remove Offline Access", systemImage: "xmark.circle")
                        } else {
                            Label("Make Available Offline", systemImage: "arrow.down.circle")
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 10)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576.0
        return String(format: "%.1f MB", mb)
    }
}

struct DiscMarkerRow: View {
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            VStack { Divider() }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack { Divider() }
        }
        .padding(.vertical, 4)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

