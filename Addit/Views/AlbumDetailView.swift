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
    @State private var albumImage: UIImage?

    private let coverSize: CGFloat = 200

    private var sortedTracks: [Track] {
        album.tracks.sorted { $0.trackNumber < $1.trackNumber }
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
                    ForEach(Array(sortedTracks.enumerated()), id: \.element.persistentModelID) { index, track in
                        TrackRow(
                            track: track,
                            number: index + 1,
                            isCurrentTrack: playerService.currentTrack?.googleFileId == track.googleFileId,
                            isPlaying: playerService.currentTrack?.googleFileId == track.googleFileId && playerService.isPlaying
                        )
                        .listRowBackground(Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            playerService.playTrack(track, inQueue: sortedTracks)
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
                Button {
                    showEditSheet = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
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

        do {
            // Refresh folder name and permissions from Drive
            if let folderInfo = try? await driveService.getFileMetadata(fileId: album.googleFolderId) {
                album.name = folderInfo.name
                album.canEdit = folderInfo.canEdit
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

            // Apply tracklist ordering
            await applyTrackOrdering(driveFiles: driveFiles)

            // Sync artist name
            await syncArtistName()

            // Sync JPEG cover art metadata
            await syncCoverArtMetadata()

            album.trackCount = driveFiles.count
            try? modelContext.save()
        } catch {
            syncError = "Couldn't sync: \(error.localizedDescription)"
        }
    }

    private func applyTrackOrdering(driveFiles: [DriveItem]) async {
        do {
            let tracklistItem = try await driveService.findFile(named: ".addit-tracklist", inFolder: album.googleFolderId)

            if let tracklistItem {
                let data = try await driveService.downloadFileData(fileId: tracklistItem.id)
                if let content = String(data: data, encoding: .utf8) {
                    let orderedNames = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    var trackNumber = 1

                    // Assign numbers to tracks listed in the tracklist
                    for name in orderedNames {
                        if let track = album.tracks.first(where: { $0.name == name }) {
                            track.trackNumber = trackNumber
                            trackNumber += 1
                        }
                    }

                    // Append unlisted tracks alphabetically at the end
                    let listedNames = Set(orderedNames)
                    let unlistedTracks = album.tracks
                        .filter { !listedNames.contains($0.name) }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

                    for track in unlistedTracks {
                        track.trackNumber = trackNumber
                        trackNumber += 1
                    }
                    return
                }
            }
        } catch {
            // Fall back to default ordering
        }

        // Default: alphabetical order from Drive API response
        for (index, file) in driveFiles.enumerated() {
            if let track = album.tracks.first(where: { $0.googleFileId == file.id }) {
                track.trackNumber = index + 1
            }
        }
    }

    private func syncArtistName() async {
        do {
            let artistItem = try await driveService.findFile(named: ".addit-artist", inFolder: album.googleFolderId)

            if let artistItem {
                let data = try await driveService.downloadFileData(fileId: artistItem.id)
                if let content = String(data: data, encoding: .utf8) {
                    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    album.artistName = trimmed.isEmpty ? nil : trimmed
                }
            }
        } catch {
            // Keep existing local value on error
        }
    }

    private func syncCoverArtMetadata() async {
        do {
            let coverItem = try await driveService.findCoverImage(inFolder: album.googleFolderId)

            if let coverItem {
                album.coverFileId = coverItem.id
                album.coverMimeType = coverItem.mimeType
                album.coverUpdatedAt = .now
            } else {
                album.coverFileId = nil
                album.coverMimeType = nil
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
