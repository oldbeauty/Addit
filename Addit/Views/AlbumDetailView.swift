import SwiftUI
import SwiftData

struct AlbumDetailView: View {
    let album: Album
    @Environment(AudioPlayerService.self) private var playerService
    @Environment(GoogleDriveService.self) private var driveService
    @Environment(\.modelContext) private var modelContext
    @State private var isSyncing = true
    @State private var syncError: String?
    @State private var isReordering = false
    @State private var reorderedTracks: [Track] = []
    @State private var tracklistFileId: String?
    @State private var isSavingOrder = false
    @State private var editMode: EditMode = .inactive
    @State private var addiDataFolderId: String?
    @State private var artistFileId: String?
    @State private var isEditingArtist = false
    @State private var editedArtistName = ""
    @State private var isEditingAlbumName = false
    @State private var editedAlbumName = ""
    @State private var isEditingTrackName = false
    @State private var editedTrackName = ""
    @State private var trackBeingRenamed: Track?

    private var sortedTracks: [Track] {
        album.tracks.sorted { $0.trackNumber < $1.trackNumber }
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
            } else if isReordering {
                Section {
                    ForEach(reorderedTracks) { track in
                        Text(track.displayName)
                            .font(.body)
                            .lineLimit(1)
                            .padding(.vertical, 4)
                    }
                    .onMove(perform: moveTrack)
                    .deleteDisabled(true)
                }
            } else {
                // Artist section
                if album.artistName != nil || album.canEdit {
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Artist")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(album.artistName ?? "Unknown Artist")
                                    .font(.headline)
                                    .foregroundStyle(album.artistName != nil ? .primary : .secondary)
                            }
                            Spacer()
                            if album.canEdit {
                                Image(systemName: "pencil")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if album.canEdit {
                                editedArtistName = album.artistName ?? ""
                                isEditingArtist = true
                            }
                        }
                    }
                }

                Section {
                    HStack(spacing: 12) {
                        Button {
                            playerService.playAlbum(album)
                        } label: {
                            Label("Play All", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            playerService.playAlbum(album, shuffled: true)
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }
                        .buttonStyle(.bordered)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .padding(.vertical, 4)
                }

                Section {
                    ForEach(Array(sortedTracks.enumerated()), id: \.element.persistentModelID) { index, track in
                        TrackRow(
                            track: track,
                            number: index + 1,
                            isCurrentTrack: playerService.currentTrack?.googleFileId == track.googleFileId,
                            isPlaying: playerService.currentTrack?.googleFileId == track.googleFileId && playerService.isPlaying,
                            canEdit: album.canEdit
                        ) {
                            editedTrackName = track.displayName
                            trackBeingRenamed = track
                            isEditingTrackName = true
                        }
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
        .environment(\.editMode, $editMode)
        .navigationTitle(album.name)
        .toolbar {
            if album.canEdit && !isReordering && !isSyncing {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        startReordering()
                    } label: {
                        Label("Reorder", systemImage: "arrow.up.arrow.down")
                    }
                    .disabled(album.tracks.isEmpty)
                }
            }
            if isReordering {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancelReordering()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSavingOrder {
                        ProgressView()
                    } else {
                        Button("Done") {
                            Task { await saveTrackOrder() }
                        }
                    }
                }
            }
        }
        .toolbarTitleMenu {
            if album.canEdit && !isReordering && !isSyncing {
                Button {
                    editedAlbumName = album.name
                    isEditingAlbumName = true
                } label: {
                    Label("Rename Album", systemImage: "pencil")
                }
            }
        }
        .alert("Artist Name", isPresented: $isEditingArtist) {
            TextField("Artist name", text: $editedArtistName)
            Button("Save") {
                Task { await saveArtistName() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter the artist or band name for this album")
        }
        .alert("Rename Album", isPresented: $isEditingAlbumName) {
            TextField("Album name", text: $editedAlbumName)
            Button("Save") {
                Task { await saveAlbumName() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter a new name for this album")
        }
        .alert("Rename Track", isPresented: $isEditingTrackName) {
            TextField("Track name", text: $editedTrackName)
            Button("Save") {
                Task { await saveTrackName() }
            }
            Button("Cancel", role: .cancel) {
                trackBeingRenamed = nil
            }
        } message: {
            Text("Enter a new name for this track")
        }
        .refreshable {
            await syncFromDrive()
        }
        .task {
            await syncFromDrive()
        }
        .safeAreaInset(edge: .bottom) {
            if playerService.currentTrack != nil && !isReordering {
                Color.clear.frame(height: 64)
            }
        }
    }

    // MARK: - Reorder

    private func startReordering() {
        reorderedTracks = sortedTracks
        editMode = .active
        isReordering = true
    }

    private func cancelReordering() {
        editMode = .inactive
        isReordering = false
        reorderedTracks = []
    }

    private func moveTrack(from source: IndexSet, to destination: Int) {
        reorderedTracks.move(fromOffsets: source, toOffset: destination)
    }

    private func saveTrackOrder() async {
        isSavingOrder = true
        defer { isSavingOrder = false }

        let content = reorderedTracks.map(\.name).joined(separator: "\n")
        guard let data = content.data(using: .utf8) else { return }

        do {
            let folderId = try await ensureAdditDataFolder()

            if let existingId = tracklistFileId {
                try await driveService.updateFileData(fileId: existingId, data: data, mimeType: "text/plain")
            } else {
                let item = try await driveService.createFile(
                    name: ".addit-tracklist",
                    mimeType: "text/plain",
                    inFolder: folderId,
                    data: data
                )
                tracklistFileId = item.id
            }

            // Update local track numbers
            for (index, track) in reorderedTracks.enumerated() {
                track.trackNumber = index + 1
            }
            try? modelContext.save()

            editMode = .inactive
            isReordering = false
            reorderedTracks = []
        } catch {
            syncError = "Failed to save order: \(error.localizedDescription)"
        }
    }

    // MARK: - Artist

    private func saveArtistName() async {
        let trimmed = editedArtistName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName: String? = trimmed.isEmpty ? nil : trimmed

        album.artistName = newName
        try? modelContext.save()

        guard let data = (newName ?? "").data(using: .utf8) else { return }

        do {
            let folderId = try await ensureAdditDataFolder()

            if let existingId = artistFileId {
                try await driveService.updateFileData(fileId: existingId, data: data, mimeType: "text/plain")
            } else {
                let item = try await driveService.createFile(
                    name: ".addit-artist",
                    mimeType: "text/plain",
                    inFolder: folderId,
                    data: data
                )
                artistFileId = item.id
            }
        } catch {
            syncError = "Failed to save artist: \(error.localizedDescription)"
        }
    }

    // MARK: - Rename Album

    private func saveAlbumName() async {
        let trimmed = editedAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != album.name else { return }

        let oldName = album.name
        album.name = trimmed
        try? modelContext.save()

        do {
            try await driveService.renameFile(fileId: album.googleFolderId, newName: trimmed)
        } catch {
            // Revert on failure
            album.name = oldName
            try? modelContext.save()
            syncError = "Failed to rename album: \(error.localizedDescription)"
        }
    }

    // MARK: - Rename Track

    private func saveTrackName() async {
        guard let track = trackBeingRenamed else { return }
        let trimmed = editedTrackName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            trackBeingRenamed = nil
            return
        }

        // Preserve the original file extension
        let originalExtension = (track.name as NSString).pathExtension
        let newFileName: String
        if originalExtension.isEmpty {
            newFileName = trimmed
        } else {
            newFileName = "\(trimmed).\(originalExtension)"
        }

        guard newFileName != track.name else {
            trackBeingRenamed = nil
            return
        }

        let oldName = track.name

        // Update locally first
        track.name = newFileName
        try? modelContext.save()

        do {
            try await driveService.renameFile(fileId: track.googleFileId, newName: newFileName)

            // Update the tracklist file if it exists, replacing old name with new
            await updateTracklistAfterRename(oldName: oldName, newName: newFileName)
        } catch {
            // Revert on failure
            track.name = oldName
            try? modelContext.save()
            syncError = "Failed to rename track: \(error.localizedDescription)"
        }

        trackBeingRenamed = nil
    }

    private func updateTracklistAfterRename(oldName: String, newName: String) async {
        guard let tracklistId = tracklistFileId else { return }

        do {
            let data = try await driveService.downloadFileData(fileId: tracklistId)
            guard var content = String(data: data, encoding: .utf8) else { return }

            content = content.replacingOccurrences(of: oldName, with: newName)

            guard let updatedData = content.data(using: .utf8) else { return }
            try await driveService.updateFileData(fileId: tracklistId, data: updatedData, mimeType: "text/plain")
        } catch {
            // Non-critical — tracklist will still work on next reorder
        }
    }

    // MARK: - addit-data Folder

    private func resolveAdditDataFolder() async {
        do {
            if let item = try await driveService.findFile(named: "addit-data", inFolder: album.googleFolderId),
               item.isFolder {
                addiDataFolderId = item.id
                return
            }
        } catch {
            // Best effort
        }
        addiDataFolderId = nil
    }

    private func ensureAdditDataFolder() async throws -> String {
        if let existing = addiDataFolderId {
            return existing
        }
        let folder = try await driveService.findOrCreateFolder(named: "addit-data", inParent: album.googleFolderId)
        addiDataFolderId = folder.id
        return folder.id
    }

    // MARK: - Sync

    private func syncFromDrive() async {
        guard !isReordering else { return }
        isSyncing = true
        syncError = nil
        defer { isSyncing = false }

        do {
            // Refresh folder permissions
            if let folderInfo = try? await driveService.getFileMetadata(fileId: album.googleFolderId) {
                album.canEdit = folderInfo.canAddChildren
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

            // Resolve addit-data folder for metadata lookups
            await resolveAdditDataFolder()

            // Apply tracklist ordering
            await applyTrackOrdering(driveFiles: driveFiles)

            // Sync artist name
            await syncArtistName()

            album.trackCount = driveFiles.count
            try? modelContext.save()
        } catch {
            syncError = "Couldn't sync: \(error.localizedDescription)"
        }
    }

    private func applyTrackOrdering(driveFiles: [DriveItem]) async {
        do {
            var tracklistItem: DriveItem?

            // Check addit-data/ first
            if let folderId = addiDataFolderId {
                tracklistItem = try await driveService.findFile(named: ".addit-tracklist", inFolder: folderId)
            }

            // Fall back to root for backward compatibility
            if tracklistItem == nil {
                tracklistItem = try await driveService.findFile(named: ".addit-tracklist", inFolder: album.googleFolderId)
            }

            if let tracklistItem {
                tracklistFileId = tracklistItem.id
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
        tracklistFileId = nil
        for (index, file) in driveFiles.enumerated() {
            if let track = album.tracks.first(where: { $0.googleFileId == file.id }) {
                track.trackNumber = index + 1
            }
        }
    }

    private func syncArtistName() async {
        do {
            var artistItem: DriveItem?

            // Check addit-data/ first
            if let folderId = addiDataFolderId {
                artistItem = try await driveService.findFile(named: ".addit-artist", inFolder: folderId)
            }

            // Fall back to root
            if artistItem == nil {
                artistItem = try await driveService.findFile(named: ".addit-artist", inFolder: album.googleFolderId)
            }

            if let artistItem {
                artistFileId = artistItem.id
                let data = try await driveService.downloadFileData(fileId: artistItem.id)
                if let content = String(data: data, encoding: .utf8) {
                    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    album.artistName = trimmed.isEmpty ? nil : trimmed
                }
            } else {
                artistFileId = nil
            }
        } catch {
            // Keep existing local value on error
        }
    }
}

struct TrackRow: View {
    let track: Track
    let number: Int
    let isCurrentTrack: Bool
    let isPlaying: Bool
    var canEdit: Bool = false
    var onRename: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            if isCurrentTrack {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
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
                    .foregroundStyle(isCurrentTrack ? Color.accentColor : .primary)
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
        .contextMenu {
            if canEdit {
                Button {
                    onRename?()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
        }
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576.0
        return String(format: "%.1f MB", mb)
    }
}
