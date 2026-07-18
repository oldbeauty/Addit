import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

// AlbumDetailView's inline edit mode — subviews, lifecycle, and the
// immediate actions (delete / add / cover) whose behavior is inherited
// from the old AlbumMetadataEditorSheet. Split out of AlbumDetailView.swift
// purely for file size; same type, same access to its members.

extension AlbumDetailView {
    // MARK: - Inline edit mode

    /// Add-tracks "From cloud" pulls from the active account's provider for
    /// local albums (sheet parity); cloud albums use their own provider.
    private var editDriveService: any CloudDriveService {
        album.isLocal ? cloudRouter.activeService : driveService
    }

    /// Provider name for UI labels ("Google Drive" / "OneDrive").
    private var cloudLabel: String {
        album.isOneDrive ? "OneDrive"
            : album.isLocal ? cloudRouter.activeProvider.displayName
            : "Google Drive"
    }

    /// Pre-computed disc numbers keyed by TracklistItem.id, so each
    /// disc-marker row can render its label without slicing `editItems`
    /// inside the ForEach body (which interacts badly with `.onMove`
    /// diffing on UICollectionView).
    private var editDiscNumbersByItemId: [String: Int] {
        var result: [String: Int] = [:]
        var counter = 0
        for item in editItems where item.isDiscMarker {
            counter += 1
            result[item.id] = counter
        }
        return result
    }

    /// Inline replacement for `tracksSection` while editing: trash button in
    /// the number slot, tap-to-rename names, removable disc markers, and
    /// system reorder handles trailing (edit mode + `.onMove`). No section
    /// header — the add controls live in the album header where play/shuffle
    /// sit, so the first row lands at the same offset as in normal mode.
    var editTracksSection: some View {
        Section {
            ForEach(editItems) { item in
                switch item {
                case .track(let track):
                    editTrackRow(for: track)
                case .discMarker:
                    editDiscMarkerRow(for: item)
                }
            }
            .onMove { source, destination in
                withAnimation {
                    editItems.move(fromOffsets: source, toOffset: destination)
                }
            }
        }
    }

    /// Mirrors `TrackRow`'s exact geometry (24pt leading slot, two-line
    /// name + size stack, 8pt vertical padding, same row insets) so rows
    /// keep their proportions when edit mode toggles — only the leading
    /// slot's content and the trailing control change.
    @ViewBuilder
    private func editTrackRow(for track: Track) -> some View {
        let isCurrentTrack = playerService.currentTrack?.googleFileId == track.googleFileId
        HStack(spacing: 12) {
            if album.canEdit {
                Button {
                    editTrackToDelete = track
                } label: {
                    Image(systemName: "trash")
                        .font(.uiSubheadline)
                        .foregroundStyle(.red)
                        .frame(width: 24)
                }
                .buttonStyle(.plain)
            } else {
                Text("\(editTrackNumbers[track.googleFileId] ?? 0)")
                    .font(.readout(11))
                    .foregroundStyle(track.isHidden ? Phosphor.ghost : Phosphor.dim)
                    .frame(width: 24)
            }

            Button {
                beginEditRename(.track(track))
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(editedTrackNames[track.googleFileId] ?? track.displayName)
                        .font(.uiBody.weight(.medium))
                        .foregroundColor(isCurrentTrack ? themeService.accentColor : track.isHidden ? Color.secondary.opacity(0.5) : .primary)
                        .fadingTruncation()

                    HStack(spacing: 4) {
                        if track.isLocal || cachedTrackIds.contains(track.googleFileId) {
                            Circle()
                                .frame(width: 6, height: 6)
                                .foregroundColor(track.isHidden ? Color.secondary.opacity(0.3) : .secondary)
                        }
                        if let size = track.fileSize {
                            Text(String(format: "%.1f MB", Double(size) / 1_048_576.0))
                                .font(.uiCaption)
                                .foregroundColor(track.isHidden ? Color.secondary.opacity(0.3) : .secondary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
        .listRowBackground(Color.clear)
    }

    /// Track numbers for the read-only edit fallback (no delete permission).
    private var editTrackNumbers: [String: Int] {
        var numbers: [String: Int] = [:]
        var count = 0
        for item in editItems {
            if case .track(let track) = item {
                count += 1
                numbers[track.googleFileId] = count
            }
        }
        return numbers
    }

    /// Mirrors `DiscMarkerRow`'s chassis — same caption font, same
    /// flex-divider centering, same 4pt vertical padding — with the remove
    /// button sitting where the duration readout does, so disc rows keep
    /// their height and the label its position when edit mode toggles.
    @ViewBuilder
    private func editDiscMarkerRow(for item: TracklistItem) -> some View {
        HStack(spacing: 8) {
            removeDiscMarkerButton(for: item).hidden()

            VStack { Divider() }
                .opacity(0)

            Text("Disc \(editDiscNumbersByItemId[item.id] ?? 1)")
                .font(.uiCaption)
                .foregroundStyle(.secondary)

            VStack { Divider() }

            removeDiscMarkerButton(for: item)
        }
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func removeDiscMarkerButton(for item: TracklistItem) -> some View {
        Button {
            let targetId = item.id
            withAnimation {
                editItems.removeAll { $0.id == targetId }
            }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.uiCaption)
                .foregroundStyle(.tertiary)
                // Same trailing offset as DiscMarkerRow's durationText, so
                // the icon's right edge lines up with the duration readout.
                .padding(.trailing, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "Add disc marker" / "Add tracks" controls in the header column —
    /// also the attachment point for every edit-mode presentation modifier
    /// (rename popup, delete confirmation, error alert, file importer, cloud
    /// picker), kept off the main body chain for type-checker budget.
    var editControlsRow: some View {
        editControlsRowContent
            .selectAllInTextFields(while: editRenameTarget != nil)
            .alert(editRenameAlertTitle, isPresented: editRenameAlertBinding) {
                TextField(editRenamePlaceholder, text: $editRenameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") { applyEditRename() }
            }
            .alert("Delete Track?", isPresented: Binding(
                get: { editTrackToDelete != nil },
                set: { if !$0 { editTrackToDelete = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let track = editTrackToDelete {
                        Task { await deleteEditTrack(track) }
                    }
                }
                Button("Cancel", role: .cancel) { editTrackToDelete = nil }
            } message: {
                Text(deleteEditTrackMessage)
            }
            .alert("Couldn't Save Changes", isPresented: Binding(
                get: { editErrorMessage != nil },
                set: { if !$0 { editErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(editErrorMessage ?? "")
            }
            .fileImporter(
                isPresented: $showEditDocumentPicker,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: true
            ) { result in
                Task { await handleEditPickedFiles(result) }
            }
            .sheet(isPresented: $showEditDriveAudioPicker) {
                DriveAudioPickerView(targetFolderId: album.googleFolderId) { files in
                    Task { await handleEditDriveFilesAdded(files) }
                }
            }
    }

    /// Laid out on the edit rows' grid: the plus glyph is centered in the
    /// same 24pt leading slot as the trash buttons, so the "Add disc
    /// marker" text starts exactly where the song titles do. Occupies
    /// `playButtons`' exact vertical envelope (4 + 70pt socket + 1) so the
    /// tracklist below starts at the same level in both modes.
    private var editControlsRowContent: some View {
        HStack(spacing: 12) {
            if !editItems.isEmpty {
                Button {
                    addEditDiscMarker()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.uiSubheadline)
                            .frame(width: 24)
                        Text("Add disc marker")
                            .font(.uiSubheadline)
                    }
                }
                .disabled(editItems.filter(\.isDiscMarker).count >= 100)
            }

            Spacer()

            if isUploadingTracks {
                ProgressView()
                    .controlSize(.small)
            } else if album.canEdit {
                Menu {
                    Button {
                        showEditDriveAudioPicker = true
                    } label: {
                        Label("From \(cloudLabel)", systemImage: "cloud")
                    }
                    Button {
                        showEditDocumentPicker = true
                    } label: {
                        Label("From iPhone", systemImage: "iphone")
                    }
                } label: {
                    Label("Add tracks", systemImage: "plus.circle")
                        .font(.uiSubheadline)
                }
            }
        }
        // Edit rows' 8pt edge inset, so the 24pt slot sits on the
        // trash-button grid.
        .padding(.horizontal, 8)
        .frame(height: 70)
        .padding(.top, 4)
        .padding(.bottom, 1)
    }

    private var deleteEditTrackMessage: String {
        let trackName = editTrackToDelete?.name ?? ""
        return album.isLocal
            ? "This will delete \"\(trackName)\" from \"\(album.name)\" on this iPhone."
            : "This will delete \"\(trackName)\" from \"\(album.name)\" in \(cloudLabel)."
    }

    // MARK: Edit-mode rename popup

    private var editRenameAlertBinding: Binding<Bool> {
        Binding(
            get: { editRenameTarget != nil },
            set: { if !$0 { editRenameTarget = nil } }
        )
    }

    private var editRenameAlertTitle: String {
        switch editRenameTarget {
        case .artist: return "Edit Artist"
        case .track: return "Rename Track"
        default: return "Rename Album"
        }
    }

    private var editRenamePlaceholder: String {
        switch editRenameTarget {
        case .artist: return "Artist"
        case .track: return "Track name"
        default: return "Album title"
        }
    }

    func beginEditRename(_ target: EditRenameTarget) {
        switch target {
        case .title: editRenameText = editedTitle
        case .artist: editRenameText = editedArtist
        case .track(let track): editRenameText = editedTrackNames[track.googleFileId] ?? track.displayName
        }
        editRenameTarget = target
    }

    /// Applies the popup's text. Empty input keeps the old title/track name
    /// (both are required); an empty artist clears the field.
    private func applyEditRename() {
        guard let target = editRenameTarget else { return }
        let trimmed = editRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch target {
        case .title:
            if !trimmed.isEmpty { editedTitle = trimmed }
        case .artist:
            editedArtist = trimmed
        case .track(let track):
            if !trimmed.isEmpty { editedTrackNames[track.googleFileId] = trimmed }
        }
    }

    // MARK: Edit-mode lifecycle

    func enterEditMode() {
        editedTitle = album.name
        editedArtist = album.artistName ?? ""
        editedTrackNames = [:]
        editItems = displayItems
        editErrorMessage = nil
        editAdditDataFileId = album.additDataFileId
        editAdditDataOwnedByMe = true
        withAnimation {
            showToolbarActions = false
            isEditing = true
        }
        if !album.isLocal {
            Task { await resolveEditOwnership() }
        }
    }

    /// Best-effort refresh of folder ownership and the `.addit-data` file id
    /// before a save needs them (mirrors the sheet's resolve pair). Errors
    /// keep the values seeded from the album.
    private func resolveEditOwnership() async {
        if let folderMeta = try? await driveService.getFileMetadata(fileId: album.googleFolderId),
           let ownedByMe = folderMeta.ownedByMe, ownedByMe != album.isFolderOwner {
            album.isFolderOwner = ownedByMe
            try? modelContext.save()
        }
        do {
            if let item = try await driveService.findFile(named: ".addit-data", inFolder: album.googleFolderId) {
                editAdditDataFileId = item.id
                editAdditDataOwnedByMe = item.ownedByMe ?? true
            } else {
                editAdditDataFileId = nil
                editAdditDataOwnedByMe = true
            }
        } catch {
            // Keep the seeded value.
        }
    }

    func cancelEdits() {
        withAnimation { isEditing = false }
        editedTrackNames = [:]
        // Deletes, added tracks, and cover changes apply immediately —
        // rebuild the display list so they survive the cancel.
        refreshTracklist()
    }

    private func finishEditing() {
        withAnimation {
            displayItems = editItems
            isEditing = false
        }
        editedTrackNames = [:]
    }

    func saveEdits() async {
        let trimmedTitle = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        isSavingEdits = true
        defer { isSavingEdits = false }

        let trimmedArtist = editedArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        let newArtist: String? = trimmedArtist.isEmpty ? nil : trimmedArtist

        if album.isLocal {
            album.name = trimmedTitle
            album.artistName = newArtist

            // Update track names, numbers, and persist tracklist with disc markers
            var tracklist: [String] = []
            var trackIndex = 0
            var discNumber = 0
            for item in editItems {
                switch item {
                case .track(let track):
                    if let newName = editedTrackNames[track.googleFileId], newName != track.displayName,
                       let oldURL = track.localFileURL {
                        let ext = oldURL.pathExtension
                        let newFileName = "\(newName).\(ext)"
                        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(newFileName)
                        if oldURL != newURL {
                            try? FileManager.default.moveItem(at: oldURL, to: newURL)
                            // Store relative path
                            if let localFilePath = track.localFilePath,
                               let lastSlash = localFilePath.range(of: "/", options: .backwards) {
                                track.localFilePath = localFilePath[localFilePath.startIndex..<lastSlash.upperBound] + newFileName
                            }
                            track.name = newFileName
                        }
                    }
                    trackIndex += 1
                    track.trackNumber = trackIndex
                    tracklist.append(track.name)
                case .discMarker:
                    discNumber += 1
                    tracklist.append("\(AdditMetadata.discMarkerPrefix)Disc \(discNumber)")
                }
            }
            album.cachedTracklist = tracklist
            try? modelContext.save()
            finishEditing()
            return
        }

        // Snapshot current state for rollback
        let previousName = album.name
        let previousArtist = album.artistName
        let allTracks = editItems.compactMap(\.asTrack)
        let previousTrackNames = Dictionary(uniqueKeysWithValues: allTracks.map { ($0.googleFileId, $0.name) })
        let previousTrackNumbers = Dictionary(uniqueKeysWithValues: allTracks.map { ($0.googleFileId, $0.trackNumber) })

        album.name = trimmedTitle
        album.artistName = newArtist
        try? modelContext.save()

        do {
            // Rename the Drive folder only when the title actually changed —
            // a plain reorder shouldn't need rename permission.
            if trimmedTitle != previousName {
                _ = try await driveService.renameFile(fileId: album.googleFolderId, newName: trimmedTitle)
            }

            try await renameChangedEditTracks()
            try await saveEditAdditData(artist: newArtist)
            finishEditing()
        } catch {
            // Revert all local changes on failure; stay in edit mode.
            album.name = previousName
            album.artistName = previousArtist
            for item in editItems {
                if case .track(let track) = item {
                    if let oldName = previousTrackNames[track.googleFileId] {
                        track.name = oldName
                    }
                    if let oldNumber = previousTrackNumbers[track.googleFileId] {
                        track.trackNumber = oldNumber
                    }
                }
            }
            try? modelContext.save()
            editErrorMessage = error.localizedDescription
        }
    }

    private func renameChangedEditTracks() async throws {
        for item in editItems {
            guard case .track(let track) = item else { continue }
            guard let editedName = editedTrackNames[track.googleFileId] else { continue }
            let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Preserve the original file extension
            let ext = (track.name as NSString).pathExtension
            let newFileName = ext.isEmpty ? trimmed : "\(trimmed).\(ext)"
            guard newFileName != track.name else { continue }

            _ = try await driveService.renameFile(fileId: track.googleFileId, newName: newFileName)
            track.name = newFileName
        }
        try? modelContext.save()
    }

    private func saveEditAdditData(artist: String?) async throws {
        // Build interleaved tracklist with disc markers
        var discNumber = 0
        let tracklist: [String] = editItems.map { item in
            switch item {
            case .track(let track):
                return track.name
            case .discMarker:
                discNumber += 1
                return "\(AdditMetadata.discMarkerPrefix)Disc \(discNumber)"
            }
        }

        let metadata = AdditMetadata(tracklist: tracklist, artist: artist)
        let data = try JSONEncoder().encode(metadata)
        let folderId = album.googleFolderId

        if let existingId = editAdditDataFileId {
            if album.isFolderOwner && !editAdditDataOwnedByMe {
                // Claim ownership: remove the file we don't own and create a new one
                try await driveService.removeFileFromFolder(fileId: existingId, folderId: folderId)
                let item = try await driveService.createFile(
                    name: ".addit-data",
                    mimeType: "application/json",
                    inFolder: folderId,
                    data: data
                )
                editAdditDataFileId = item.id
                album.additDataFileId = item.id
                editAdditDataOwnedByMe = true
                // Notify chat that history was reset due to ownership
                // change. Chat (Drive comments) is Google-only, so this
                // goes through the concrete Google client and is skipped
                // for OneDrive albums.
                if album.storageSource == .googleDrive {
                    _ = try? await cloudRouter.google.createComment(
                        fileId: item.id,
                        content: "File ownership data was changed. Previous chat history may not persist."
                    )
                }
            } else {
                try await driveService.updateFileData(fileId: existingId, data: data, mimeType: "application/json")
            }
        } else {
            let item = try await driveService.createFile(
                name: ".addit-data",
                mimeType: "application/json",
                inFolder: folderId,
                data: data
            )
            editAdditDataFileId = item.id
            album.additDataFileId = item.id
            editAdditDataOwnedByMe = true
        }

        // Assign track numbers (skip disc markers)
        var trackNumber = 1
        for item in editItems {
            if case .track(let track) = item {
                track.trackNumber = trackNumber
                trackNumber += 1
            }
        }
        // Mirror the saved ordering so the next visit renders it instantly
        // without waiting on the .addit-data download.
        album.cachedTracklist = tracklist
        try? modelContext.save()
    }

    // MARK: Edit-mode immediate actions (delete / add / cover — sheet parity)

    private func addEditDiscMarker() {
        let existingDiscCount = editItems.filter(\.isDiscMarker).count
        guard existingDiscCount < 100 else { return }

        let newMarker = TracklistItem.discMarker(id: UUID(), label: "")

        if existingDiscCount == 0 {
            editItems.insert(newMarker, at: 0)
        } else if let lastDiscIndex = editItems.lastIndex(where: \.isDiscMarker) {
            editItems.insert(newMarker, at: lastDiscIndex + 1)
        }
    }

    private func deleteEditTrack(_ track: Track) async {
        if track.isLocal {
            if let url = track.localFileURL {
                try? FileManager.default.removeItem(at: url)
            }
        } else {
            do {
                try await driveService.deleteFile(fileId: track.googleFileId)
                // Drop the offline copy too — a deleted track's cache
                // entry would never be reachable again.
                cacheService.removeTrack(track)
                cachedTrackIds.remove(track.googleFileId)
            } catch {
                editErrorMessage = "Failed to delete: \(error.localizedDescription)"
                editTrackToDelete = nil
                return
            }
        }
        let targetId = track.googleFileId
        withAnimation {
            editItems.removeAll { $0.id == targetId }
            displayItems.removeAll { $0.id == targetId }
        }
        editedTrackNames.removeValue(forKey: targetId)
        modelContext.delete(track)
        album.trackCount = max(0, album.trackCount - 1)
        try? modelContext.save()
        editTrackToDelete = nil
    }

    private func handleEditPickedFiles(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result, !urls.isEmpty else { return }

        isUploadingTracks = true
        defer { isUploadingTracks = false }

        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let data = try Data(contentsOf: url)
                let fileName = url.lastPathComponent
                let mimeType = mimeTypeForExtension(url.pathExtension)

                if album.isLocal {
                    // Save file locally
                    let albumId = album.googleFolderId.replacingOccurrences(of: "local_", with: "")
                    let fm = FileManager.default
                    let albumDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("LocalAlbums", isDirectory: true)
                        .appendingPathComponent(albumId, isDirectory: true)
                    try? fm.createDirectory(at: albumDir, withIntermediateDirectories: true)

                    let destURL = albumDir.appendingPathComponent(fileName)
                    try data.write(to: destURL)

                    let track = Track(
                        googleFileId: "local_\(UUID().uuidString)",
                        name: fileName,
                        album: album,
                        mimeType: mimeType,
                        fileSize: Int64(data.count),
                        trackNumber: editItems.compactMap(\.asTrack).count + 1,
                        localFilePath: "LocalAlbums/\(albumId)/\(fileName)"
                    )
                    modelContext.insert(track)
                    editItems.append(.track(track))
                    album.trackCount += 1
                } else {
                    let driveItem = try await editDriveService.createFile(
                        name: fileName,
                        mimeType: mimeType,
                        inFolder: album.googleFolderId,
                        data: data
                    )

                    let track = Track(
                        googleFileId: driveItem.id,
                        name: driveItem.name,
                        album: album,
                        mimeType: driveItem.mimeType,
                        fileSize: driveItem.fileSizeBytes,
                        trackNumber: editItems.compactMap(\.asTrack).count + 1,
                        modifiedTime: driveItem.modifiedTime
                    )
                    modelContext.insert(track)
                    editItems.append(.track(track))
                    album.trackCount += 1
                }
            } catch {
                editErrorMessage = "Upload failed: \(error.localizedDescription)"
            }
        }
        try? modelContext.save()
    }

    private func handleEditDriveFilesAdded(_ files: [DriveItem]) async {
        isUploadingTracks = true
        defer { isUploadingTracks = false }

        for file in files {
            do {
                if album.isLocal {
                    // Download from the cloud and save locally
                    let data = try await editDriveService.downloadFileData(fileId: file.id)
                    let albumId = album.googleFolderId.replacingOccurrences(of: "local_", with: "")
                    let fm = FileManager.default
                    let albumDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("LocalAlbums", isDirectory: true)
                        .appendingPathComponent(albumId, isDirectory: true)
                    try? fm.createDirectory(at: albumDir, withIntermediateDirectories: true)

                    let destURL = albumDir.appendingPathComponent(file.name)
                    try data.write(to: destURL)

                    let track = Track(
                        googleFileId: "local_\(UUID().uuidString)",
                        name: file.name,
                        album: album,
                        mimeType: file.mimeType,
                        fileSize: Int64(data.count),
                        trackNumber: editItems.compactMap(\.asTrack).count + 1,
                        localFilePath: "LocalAlbums/\(albumId)/\(file.name)"
                    )
                    modelContext.insert(track)
                    editItems.append(.track(track))
                    album.trackCount += 1
                } else {
                    let copiedItem = try await editDriveService.copyFile(
                        fileId: file.id,
                        toFolder: album.googleFolderId
                    )

                    let track = Track(
                        googleFileId: copiedItem.id,
                        name: copiedItem.name,
                        album: album,
                        mimeType: copiedItem.mimeType,
                        fileSize: copiedItem.fileSizeBytes,
                        trackNumber: editItems.compactMap(\.asTrack).count + 1,
                        modifiedTime: copiedItem.modifiedTime
                    )
                    modelContext.insert(track)
                    editItems.append(.track(track))
                    album.trackCount += 1
                }
            } catch {
                editErrorMessage = "Copy failed: \(error.localizedDescription)"
            }
        }
        try? modelContext.save()
    }

    private func mimeTypeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/x-m4a"
        case "mp4": return "audio/mp4"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        case "aiff", "aif": return "audio/aiff"
        case "ogg": return "audio/ogg"
        case "alac": return "audio/alac"
        default: return "audio/mpeg"
        }
    }

    func uploadEditCroppedCover(_ croppedImage: UIImage) async {
        guard !isUploadingCover else { return }

        isUploadingCover = true
        defer { isUploadingCover = false }

        if album.isLocal {
            // Save cover locally
            guard let jpegData = croppedImage.jpegData(compressionQuality: 0.9) else {
                coverUploadErrorMessage = "The selected photo couldn't be converted to a JPEG cover."
                return
            }
            let albumId = album.googleFolderId.replacingOccurrences(of: "local_", with: "")
            let localBase = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LocalAlbums", isDirectory: true)
                .appendingPathComponent(albumId, isDirectory: true)
            try? FileManager.default.createDirectory(at: localBase, withIntermediateDirectories: true)
            let coverURL = localBase.appendingPathComponent("cover.jpg")
            try? jpegData.write(to: coverURL)
            album.localCoverPath = "LocalAlbums/\(albumId)/cover.jpg"
            albumImage = croppedImage
            try? modelContext.save()
            return
        }

        do {
            guard let jpegData = croppedImage.jpegData(compressionQuality: 0.9) else {
                coverUploadErrorMessage = "The selected photo couldn't be converted to a JPEG cover."
                return
            }

            // If folder owner, remove unowned cover so the new one will be owned by us
            if album.isFolderOwner {
                if let existingCover = try await driveService.findCoverImage(inFolder: album.googleFolderId),
                   existingCover.ownedByMe == false {
                    try await driveService.removeFileFromFolder(fileId: existingCover.id, folderId: album.googleFolderId)
                }
            }

            let previousCoverFileId = album.coverFileId
            let coverItem = try await driveService.upsertCoverImage(inFolder: album.googleFolderId, data: jpegData)

            albumArtService.invalidateImage(for: previousCoverFileId)
            albumArtService.invalidateImage(for: coverItem.id)

            let cachedImage = albumArtService.cacheImageData(jpegData, for: coverItem.id)
            albumImage = cachedImage ?? croppedImage

            let resolution = AlbumArtResolution(
                image: cachedImage,
                resolvedCoverItem: coverItem,
                shouldPersistMetadata: true
            )

            albumArtService.applyResolution(resolution, to: album, modelContext: modelContext)
            album.coverModifiedTime = nil
            album.coverUpdatedAt = .now
            try? modelContext.save()
            albumArtService.bumpRefreshToken(for: album.googleFolderId)
        } catch {
            coverUploadErrorMessage = error.localizedDescription
        }
    }

    /// A per-track snapshot taken on the main actor so the zip build can run
    /// entirely off it without touching SwiftData models.
    private struct ZipTrackPlan: Sendable {
        let fileId: String
        let name: String
        let localURL: URL?      // populated for local albums
        let cachedURL: URL?     // existing offline copy, for cloud albums
    }

    func exportAlbum() {
        guard !isExportingAlbum else { return }
        isExportingAlbum = true

        // Snapshot everything we need off the SwiftData models up front, on
        // the main actor. The heavy download/copy/zip work below runs on a
        // detached task (so playback doesn't stutter) and must not reach back
        // into Track/Album, which are main-actor-confined.
        let isLocal = album.isLocal
        let albumName = album.name
        let coverFileId = album.coverFileId
        let coverMimeType = album.coverMimeType
        let localCoverPath = album.resolvedLocalCoverPath
        let additDataFileId = album.additDataFileId
        let artistName = album.artistName
        let client = driveService
        let plans: [ZipTrackPlan] = sortedTracks.map { track in
            ZipTrackPlan(
                fileId: track.googleFileId,
                name: track.name,
                localURL: track.localFileURL,
                cachedURL: cacheService.cachedFileURL(for: track)
            )
        }
        let tracklist = album.cachedTracklist.isEmpty ? plans.map(\.name) : album.cachedTracklist
        // Encode .addit-data here (AdditMetadata's Encodable conformance is
        // main-actor-isolated) and hand the bytes to the detached writer.
        let additDataBytes: Data? = isLocal
            ? try? JSONEncoder().encode(AdditMetadata(tracklist: tracklist, artist: artistName))
            : nil

        Task {
            defer { isExportingAlbum = false }
            do {
                let zipURL = try await Task.detached(priority: .userInitiated) {
                    let fm = FileManager.default
                    let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    let albumDir = tempDir.appendingPathComponent(albumName)
                    try fm.createDirectory(at: albumDir, withIntermediateDirectories: true)

                    if isLocal {
                        for plan in plans {
                            guard let sourceURL = plan.localURL,
                                  fm.fileExists(atPath: sourceURL.path) else { continue }
                            try fm.copyItem(at: sourceURL, to: albumDir.appendingPathComponent(plan.name))
                        }
                        if let localCoverPath, fm.fileExists(atPath: localCoverPath) {
                            try fm.copyItem(atPath: localCoverPath,
                                            toPath: albumDir.appendingPathComponent("cover.jpg").path)
                        }
                        if let additDataBytes {
                            try additDataBytes.write(to: albumDir.appendingPathComponent(".addit-data"))
                        }
                    } else {
                        for plan in plans {
                            let dest = albumDir.appendingPathComponent(plan.name)
                            if let cachedURL = plan.cachedURL {
                                // Reuse the existing offline copy without
                                // re-downloading or re-caching; hardlink shares
                                // the bytes, copy is the cross-volume fallback.
                                do { try fm.linkItem(at: cachedURL, to: dest) }
                                catch { try fm.copyItem(at: cachedURL, to: dest) }
                            } else {
                                // Share-only: fetch straight into the staging
                                // folder, never touching the persistent cache.
                                try await client.downloadFile(fileId: plan.fileId, to: dest)
                            }
                        }

                        if let coverFileId {
                            let coverData = try await client.downloadFileData(fileId: coverFileId)
                            let ext: String
                            switch coverMimeType {
                            case "image/png": ext = "png"
                            case "image/gif": ext = "gif"
                            case "image/webp": ext = "webp"
                            default: ext = "jpg"
                            }
                            try coverData.write(to: albumDir.appendingPathComponent("cover.\(ext)"))
                        }

                        if let additDataFileId {
                            let additData = try await client.downloadFileData(fileId: additDataFileId)
                            try additData.write(to: albumDir.appendingPathComponent(".addit-data"))
                        }
                    }

                    // Create zip using NSFileCoordinator
                    let zipURL = tempDir.appendingPathComponent("\(albumName).zip")
                    let coordinator = NSFileCoordinator()
                    var coordinatorError: NSError?
                    var resultURL: URL?
                    coordinator.coordinate(readingItemAt: albumDir, options: .forUploading, error: &coordinatorError) { tempZipURL in
                        do {
                            try fm.copyItem(at: tempZipURL, to: zipURL)
                            resultURL = zipURL
                        } catch {
                            #if DEBUG
                            print("Failed to copy zip: \(error)")
                            #endif
                        }
                    }
                    if let coordinatorError { throw coordinatorError }

                    // Staging folder no longer needed once zipped.
                    try? fm.removeItem(at: albumDir)
                    guard let resultURL else { throw CocoaError(.fileWriteUnknown) }
                    return resultURL
                }.value

                shareFileURL = zipURL
            } catch {
                #if DEBUG
                print("Failed to create album zip: \(error)")
                #endif
            }
        }
    }

    func saveToLocalLibrary() async {
        guard !isSavingToLocal, !album.isLocal else { return }
        await MainActor.run { isSavingToLocal = true }

        let fm = FileManager.default
        let localAlbumId = UUID().uuidString
        let albumDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalAlbums", isDirectory: true)
            .appendingPathComponent(localAlbumId, isDirectory: true)
        try? fm.createDirectory(at: albumDir, withIntermediateDirectories: true)

        // Fetch all audio files from the Drive folder (handle pagination)
        var allAudioFiles: [DriveItem] = []
        var pageToken: String? = nil
        repeat {
            do {
                let response = try await driveService.listAudioFiles(inFolder: album.googleFolderId, pageToken: pageToken)
                allAudioFiles.append(contentsOf: response.files)
                pageToken = response.nextPageToken
            } catch {
                #if DEBUG
                print("[SaveToLocal] Failed to list audio files: \(error)")
                #endif
                break
            }
        } while pageToken != nil

        #if DEBUG
        print("[SaveToLocal] Found \(allAudioFiles.count) audio files in \(album.name)")
        #endif

        // Download all audio files to disk first
        struct DownloadedTrack {
            let name: String
            let mimeType: String
            let fileSize: Int64
            let relativePath: String
        }
        var downloadedTracks: [DownloadedTrack] = []

        for (index, file) in allAudioFiles.enumerated() {
            do {
                await MainActor.run {
                    saveProgress = (current: index + 1, total: allAudioFiles.count, trackName: file.name)
                }
                let data = try await driveService.downloadFileData(fileId: file.id)
                guard !data.isEmpty else {
                    #if DEBUG
                    print("[SaveToLocal] Empty data for \(file.name), skipping")
                    #endif
                    continue
                }
                let destURL = albumDir.appendingPathComponent(file.name)
                try data.write(to: destURL)
                downloadedTracks.append(DownloadedTrack(
                    name: file.name,
                    mimeType: file.mimeType,
                    fileSize: Int64(data.count),
                    relativePath: "LocalAlbums/\(localAlbumId)/\(file.name)"
                ))
            } catch {
                #if DEBUG
                print("[SaveToLocal] Failed to download \(file.name): \(error)")
                #endif
            }
        }
        #if DEBUG
        print("[SaveToLocal] Downloaded \(downloadedTracks.count)/\(allAudioFiles.count) tracks")
        #endif

        // Fetch metadata from .addit-data
        var albumArtist: String? = album.artistName
        var tracklist: [String]? = album.cachedTracklist.isEmpty ? nil : album.cachedTracklist
        do {
            if let additDataItem = try await driveService.findFile(named: ".addit-data", inFolder: album.googleFolderId) {
                let data = try await driveService.downloadFileData(fileId: additDataItem.id)
                let metadata = try JSONDecoder().decode(AdditMetadata.self, from: data)
                if let artist = metadata.artist { albumArtist = artist }
                tracklist = metadata.tracklist
            }
        } catch {
            #if DEBUG
            print("[SaveToLocal] Failed to fetch .addit-data: \(error)")
            #endif
        }

        // Fetch cover image
        var coverRelativePath: String?
        do {
            if let coverItem = try await driveService.findCoverImage(inFolder: album.googleFolderId) {
                let coverData = try await driveService.downloadFileData(fileId: coverItem.id)
                let coverURL = albumDir.appendingPathComponent("cover.jpg")
                try coverData.write(to: coverURL)
                coverRelativePath = "LocalAlbums/\(localAlbumId)/cover.jpg"
            }
        } catch {
            #if DEBUG
            print("[SaveToLocal] Failed to fetch cover: \(error)")
            #endif
        }

        // Find the highest displayOrder across all local albums
        let localDescriptor = FetchDescriptor<Album>(
            predicate: #Predicate { $0.storageSourceRaw == "localStorage" }
        )
        let existingLocalAlbums = (try? modelContext.fetch(localDescriptor)) ?? []
        let nextOrder = (existingLocalAlbums.map(\.displayOrder).max() ?? 0) + 1

        // Insert album and tracks atomically
        let newAlbum = Album(
            googleFolderId: "local_\(localAlbumId)",
            name: album.name,
            artistName: albumArtist,
            trackCount: downloadedTracks.count,
            dateAdded: .now,
            canEdit: true,
            isFolderOwner: true,
            displayOrder: nextOrder,
            storageSource: .localStorage
        )
        newAlbum.localCoverPath = coverRelativePath
        if let tracklist, !tracklist.isEmpty {
            newAlbum.cachedTracklist = tracklist
        }
        modelContext.insert(newAlbum)

        // Determine track order from tracklist
        let orderedTrackNames: [String]? = tracklist?.filter { !$0.hasPrefix(AdditMetadata.discMarkerPrefix) }

        for (index, dl) in downloadedTracks.enumerated() {
            let trackNumber: Int
            if let orderedNames = orderedTrackNames,
               let pos = orderedNames.firstIndex(of: dl.name) {
                trackNumber = pos + 1
            } else {
                trackNumber = index + 1
            }

            let track = Track(
                googleFileId: "local_\(UUID().uuidString)",
                name: dl.name,
                album: newAlbum,
                mimeType: dl.mimeType,
                fileSize: dl.fileSize,
                trackNumber: trackNumber,
                localFilePath: dl.relativePath
            )
            modelContext.insert(track)
        }

        try? modelContext.save()
        #if DEBUG
        print("[SaveToLocal] Saved album with \(downloadedTracks.count) tracks")
        #endif

        await MainActor.run {
            isSavingToLocal = false
            saveProgress = (0, 0, "")
            // Switch to Local Library and navigate back
            storageSource = StorageSource.localStorage.rawValue
            dismiss()
        }
    }

    func saveToGoogleDrive(parentId: String, markStarred: Bool) async {
        guard !isSavingToDrive, album.isLocal else { return }
        await MainActor.run {
            isSavingToDrive = true
            uploadProgress = (0, 0, "")
        }

        // This album is LOCAL, so the album-routed `driveService` property
        // would fall back to Google. Uploading targets the ACTIVE
        // account's provider — shadow the property for this function.
        let driveService = cloudRouter.activeService

        let fm = FileManager.default
        let localTracks = sortedTracks
        let totalSteps = localTracks.count + 2 // tracks + .addit-data + cover

        do {
            // 1. Create the destination folder in Drive
            await MainActor.run {
                uploadProgress = (current: 0, total: totalSteps, trackName: "Creating folder...")
            }
            let driveFolder = try await driveService.createFolder(name: album.name, inParent: parentId)

            // Star the new folder if the user picked the Starred tab
            if markStarred {
                try? await driveService.setStarred(fileId: driveFolder.id, starred: true)
            }

            // 2. Upload .addit-data with tracklist + artist
            await MainActor.run {
                uploadProgress = (current: 1, total: totalSteps, trackName: ".addit-data")
            }
            let tracklist: [String]
            if !album.cachedTracklist.isEmpty {
                tracklist = album.cachedTracklist
            } else {
                tracklist = localTracks.map(\.name)
            }
            let metadata = AdditMetadata(tracklist: tracklist, artist: album.artistName)
            let additData = try JSONEncoder().encode(metadata)
            let additDataItem = try await driveService.createFile(
                name: ".addit-data",
                mimeType: "application/json",
                inFolder: driveFolder.id,
                data: additData
            )

            // 3. Upload cover.jpg if present
            var uploadedCoverItem: DriveItem?
            if let coverPath = album.resolvedLocalCoverPath,
               fm.fileExists(atPath: coverPath),
               let coverData = try? Data(contentsOf: URL(fileURLWithPath: coverPath)) {
                await MainActor.run {
                    uploadProgress = (current: 2, total: totalSteps, trackName: "cover.jpg")
                }
                uploadedCoverItem = try? await driveService.createFile(
                    name: "cover.jpg",
                    mimeType: "image/jpeg",
                    inFolder: driveFolder.id,
                    data: coverData
                )
            }

            // 4. Upload each audio track
            struct UploadedTrack {
                let driveItem: DriveItem
                let mimeType: String
                let fileSize: Int64
                let trackNumber: Int
            }
            var uploadedTracks: [UploadedTrack] = []

            for (index, track) in localTracks.enumerated() {
                guard let url = track.localFileURL,
                      fm.fileExists(atPath: url.path) else {
                    #if DEBUG
                    print("[SaveToDrive] Skipping missing file: \(track.name)")
                    #endif
                    continue
                }
                await MainActor.run {
                    uploadProgress = (current: 2 + index + 1, total: totalSteps, trackName: track.name)
                }
                let data = try Data(contentsOf: url)
                let mime = track.mimeType.isEmpty ? "audio/mpeg" : track.mimeType
                let driveItem = try await driveService.createFile(
                    name: track.name,
                    mimeType: mime,
                    inFolder: driveFolder.id,
                    data: data
                )
                uploadedTracks.append(UploadedTrack(
                    driveItem: driveItem,
                    mimeType: mime,
                    fileSize: Int64(data.count),
                    trackNumber: track.trackNumber
                ))
            }

            #if DEBUG
            print("[SaveToDrive] Uploaded \(uploadedTracks.count)/\(localTracks.count) tracks")
            #endif

            // 5. Create the new Drive Album record in shared store
            let existingAlbums = (try? modelContext.fetch(FetchDescriptor<Album>())) ?? []
            let nextOrder = (existingAlbums.map(\.displayOrder).max() ?? -1) + 1

            let newAlbum = Album(
                googleFolderId: driveFolder.id,
                name: album.name,
                artistName: album.artistName,
                trackCount: uploadedTracks.count,
                dateAdded: .now,
                canEdit: true,
                isFolderOwner: true,
                displayOrder: nextOrder,
                storageSource: authService.activeProvider.storageSource
            )
            newAlbum.additDataFileId = additDataItem.id
            newAlbum.cachedTracklist = tracklist
            if let coverItem = uploadedCoverItem {
                newAlbum.coverFileId = coverItem.id
                newAlbum.coverMimeType = "image/jpeg"
                newAlbum.coverModifiedTime = coverItem.modifiedTime
                newAlbum.coverUpdatedAt = .now
            }
            if let email = authService.userEmail {
                newAlbum.accountId = AccountManager.storageIdentifier(for: email)
            }
            modelContext.insert(newAlbum)

            for uploaded in uploadedTracks {
                let track = Track(
                    googleFileId: uploaded.driveItem.id,
                    name: uploaded.driveItem.name,
                    album: newAlbum,
                    mimeType: uploaded.mimeType,
                    fileSize: uploaded.fileSize,
                    trackNumber: uploaded.trackNumber,
                    modifiedTime: uploaded.driveItem.modifiedTime
                )
                modelContext.insert(track)
            }

            try? modelContext.save()
            #if DEBUG
            print("[SaveToDrive] Created Drive album '\(album.name)' with \(uploadedTracks.count) tracks")
            #endif

            await MainActor.run {
                isSavingToDrive = false
                uploadProgress = (0, 0, "")
                // Switch to Google Drive Library and navigate back
                storageSource = StorageSource.googleDrive.rawValue
                dismiss()
            }
        } catch {
            #if DEBUG
            print("[SaveToDrive] Failed: \(error)")
            #endif
            await MainActor.run {
                isSavingToDrive = false
                uploadProgress = (0, 0, "")
                saveToDriveError = error.localizedDescription
            }
        }
    }

    /// Export a track to the iOS share sheet. This is deliberately
    /// share-*only*: if the track isn't already on-device (local file or
    /// offline cache) we fetch it straight to a temp file and never touch the
    /// persistent audio cache — so "send a song to a friend" leaves no
    /// residue once the share sheet's temp file is purged (we delete it on
    /// dismiss; iOS reclaims the temp dir regardless). If a local/cached copy
    /// exists we reuse those bytes via a hardlink (near-zero cost) rather than
    /// re-downloading or duplicating on disk. All file I/O runs off the main
    /// actor so playback doesn't stutter during the copy.
    func exportTrack(_ track: Track) {
        let fileId = track.googleFileId
        // Use the stored filename verbatim so the exported file keeps its
        // original extension case (e.g. "wav", not the uppercased "WAV" that
        // `fileExtension` produces for the on-screen badge).
        let niceName = track.name
        // A local track already lives on-device; a cached cloud track has an
        // offline copy. Either is a local source we can reuse without hitting
        // the network. Only a cloud track with neither needs a download.
        let localSource = track.localFileURL ?? cacheService.cachedFileURL(for: track)
        let client = driveService
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    let fm = FileManager.default
                    let dest = fm.temporaryDirectory.appendingPathComponent(niceName)
                    if fm.fileExists(atPath: dest.path) {
                        try fm.removeItem(at: dest)
                    }
                    if let localSource {
                        // Reuse the existing on-device copy: a hardlink shares
                        // the same bytes, so deleting the temp file later
                        // doesn't disturb the original. Copy as a fallback in
                        // case temp and source ever land on different volumes.
                        do { try fm.linkItem(at: localSource, to: dest) }
                        catch { try fm.copyItem(at: localSource, to: dest) }
                    } else {
                        try await client.downloadFile(fileId: fileId, to: dest)
                    }
                    return dest
                }.value
                shareFileURL = url
            } catch {
                #if DEBUG
                print("Failed to prepare track for sharing: \(error)")
                #endif
            }
        }
    }
}
