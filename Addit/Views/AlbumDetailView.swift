import SwiftUI
import SwiftData

struct AlbumDetailView: View {
    let album: Album
    @Environment(AudioPlayerService.self) private var playerService
    @Environment(GoogleDriveService.self) private var driveService
    @Environment(AlbumArtService.self) private var albumArtService
    @Environment(ThemeService.self) private var themeService
    @Environment(\.modelContext) private var modelContext
    @State private var isSyncing = true
    @State private var syncError: String?
    @State private var showEditSheet = false
    @State private var showSharingSheet = false
    @State private var albumImage: UIImage?
    @State private var queuedTrackId: String?
    @State private var displayItems: [TracklistItem] = []

    private let coverSize: CGFloat = 200

    private var sortedTracks: [Track] {
        album.tracks.sorted { $0.trackNumber < $1.trackNumber }
    }

    private var playableTracks: [Track] {
        displayItems.compactMap(\.asTrack)
    }

    private var artworkTaskID: String? {
        let refreshMarker = albumArtService.lastUpdatedAlbumFolderId == album.googleFolderId
            ? albumArtService.artworkRefreshVersion
            : 0
        return "\(album.coverArtTaskID)-\(refreshMarker)"
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
                    ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
                        switch item {
                        case .track(let track):
                            let trackNumber = displayItems[0...index].filter({ !$0.isDiscMarker }).count
                            TrackRow(
                                track: track,
                                number: trackNumber,
                                isCurrentTrack: playerService.currentTrack?.googleFileId == track.googleFileId,
                                isPlaying: playerService.currentTrack?.googleFileId == track.googleFileId && playerService.isPlaying
                            )
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
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 16) {
                    Button {
                        showSharingSheet = true
                    } label: {
                        Label("Sharing", systemImage: "person.2")
                    }
                    Button {
                        showEditSheet = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }
            }
        }
        .sheet(isPresented: $showSharingSheet) {
            SharingSheet(album: album)
        }
        .sheet(isPresented: $showEditSheet, onDismiss: {
            Task { await syncFromDrive() }
        }) {
            AlbumMetadataEditorSheet(album: album)
        }
        .refreshable {
            await syncFromDrive()
        }
        .task {
            await syncFromDrive()
        }
        .task(id: artworkTaskID) {
            let resolution = await albumArtService.resolveAlbumArt(for: album)
            albumImage = resolution.image
            albumArtService.applyResolution(resolution, to: album, modelContext: modelContext)
        }
        .safeAreaInset(edge: .bottom) {
            if playerService.currentTrack != nil {
                Color.clear.frame(height: 64)
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
                    trackNumber: index + 1
                )
                modelContext.insert(track)
            }

            // Update names and file sizes for existing tracks
            for file in driveFiles {
                if let existing = album.tracks.first(where: { $0.googleFileId == file.id }) {
                    existing.name = file.name
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

                if let size = track.fileSize {
                    Text(formatFileSize(size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
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
