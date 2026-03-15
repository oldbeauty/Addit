import SwiftUI
import SwiftData
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(GoogleAuthService.self) private var authService
    @Environment(GoogleDriveService.self) private var driveService
    @Environment(AudioPlayerService.self) private var playerService
    @Environment(AlbumArtService.self) private var albumArtService
    @Environment(AudioCacheService.self) private var cacheService
    @Query(sort: \Album.displayOrder) private var albums: [Album]
    @State private var showAddAlbum = false
    @State private var showCreateAlbum = false
    @State private var showSettings = false
    @State private var metadataEditorAlbum: Album?
    @State private var isArranging = false

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        Group {
            if albums.isEmpty {
                ScrollView {
                    ContentUnavailableView(
                        "No Albums Yet",
                        systemImage: "music.note.list",
                        description: Text("Tap + to add folders from Google Drive")
                    )
                    .padding(.top, 100)
                }
            } else if isArranging {
                List {
                    ForEach(albums) { album in
                        HStack(spacing: 12) {
                            AlbumArtworkThumbnail(album: album, size: 48)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.name)
                                    .font(.body.bold())
                                    .lineLimit(1)
                                Text(album.artistName ?? "Unknown Artist")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .onMove { source, destination in
                        var ordered = albums.map { $0 }
                        ordered.move(fromOffsets: source, toOffset: destination)
                        for (index, album) in ordered.enumerated() {
                            album.displayOrder = index
                        }
                    }
                }
                .environment(\.editMode, .constant(.active))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(albums) { album in
                            NavigationLink(value: album) {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    metadataEditorAlbum = album
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                Button {
                                    isArranging = true
                                } label: {
                                    Label("Arrange", systemImage: "arrow.up.arrow.down")
                                }
                                Button("Remove from Library", role: .destructive) {
                                    modelContext.delete(album)
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(isArranging ? "Arrange Library" : "Library")
        .navigationDestination(for: Album.self) { album in
            AlbumDetailView(album: album)
        }
        .toolbar {
            if isArranging {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        try? modelContext.save()
                        isArranging = false
                    }
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showAddAlbum = true
                        } label: {
                            Label("Add Existing", systemImage: "folder.badge.plus")
                        }
                        Button {
                            showCreateAlbum = true
                        } label: {
                            Label("Create New", systemImage: "plus.rectangle.on.folder")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        if let name = authService.userName {
                            Text(name)
                        }
                        Button {
                            showSettings = true
                        } label: {
                            Text("Settings")
                        }
                        .tint(.secondary)
                        Button("Sign Out", role: .destructive) {
                            signOutAndClearData()
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddAlbum) {
            AddAlbumView()
        }
        .sheet(isPresented: $showCreateAlbum) {
            CreateAlbumView { newAlbum in
                metadataEditorAlbum = newAlbum
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(item: $metadataEditorAlbum) { album in
            AlbumMetadataEditorSheet(album: album)
        }
        .task {
            initializeDisplayOrder()
        }
        .safeAreaInset(edge: .bottom) {
            if playerService.currentTrack != nil {
                Color.clear.frame(height: 64)
            }
        }
    }

    private func initializeDisplayOrder() {
        let needsInit = albums.count > 1 && albums.allSatisfy { $0.displayOrder == 0 }
        guard needsInit else { return }
        let sorted = albums.sorted { $0.dateAdded > $1.dateAdded }
        for (index, album) in sorted.enumerated() {
            album.displayOrder = index
        }
        try? modelContext.save()
    }

    private func signOutAndClearData() {
        // Stop playback
        playerService.pause()
        playerService.queue.removeAll()
        playerService.userQueue.removeAll()
        playerService.currentIndex = 0

        // Delete all albums and tracks from SwiftData
        for album in albums {
            modelContext.delete(album)
        }
        try? modelContext.save()

        // Clear caches
        try? cacheService.clearCache()
        albumArtService.clearCache()

        // Sign out
        authService.signOut()
    }

}

struct AlbumCard: View {
    let album: Album

    private var subtitle: String {
        let trimmedArtist = album.artistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedArtist.isEmpty ? "Unknown Artist" : trimmedArtist
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumArtworkThumbnail(album: album)

            Text(album.name)
                .font(.subheadline.bold())
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct AlbumMetadataEditorSheet: View {
    let album: Album
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(GoogleDriveService.self) private var driveService
    @Environment(AlbumArtService.self) private var albumArtService
    @Environment(ThemeService.self) private var themeService
    @State private var editedTitle = ""
    @State private var editedArtist = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var selectedCoverPhoto: PhotosPickerItem?
    @State private var isUploadingCover = false
    @State private var coverUploadErrorMessage: String?
    @State private var coverImage: UIImage?
    @State private var imageToCrop: CropItem?
    @State private var reorderedItems: [TracklistItem] = []
    @State private var editedTrackNames: [String: String] = [:]
    @State private var additDataFileId: String?
    @State private var additDataOwnedByMe: Bool = true
    @State private var isSavingOrder = false
    @State private var trackToDelete: Track?
    @State private var showAddTrackSheet = false
    @State private var showDocumentPicker = false
    @State private var isUploadingTracks = false
    @FocusState private var focusedField: EditField?

    private enum EditField: Hashable {
        case title, artist, track(String)
    }

    private let coverSize: CGFloat = 180

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Cover art
                    PhotosPicker(selection: $selectedCoverPhoto, matching: .images) {
                        ZStack {
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
                                    if let coverImage {
                                        Image(uiImage: coverImage)
                                            .resizable()
                                            .scaledToFill()
                                    } else {
                                        Image(systemName: "music.note")
                                            .font(.system(size: 48))
                                            .foregroundStyle(.white.opacity(0.8))
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .padding(4)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                                        .foregroundStyle(.secondary.opacity(0.6))
                                }

                            if isUploadingCover {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(.ultraThinMaterial)
                                    .frame(width: coverSize, height: coverSize)
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isUploadingCover)

                    // Title and artist – left-aligned with cover edge
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            TextField("Album title", text: $editedTitle)
                                .font(.title2.bold())
                                .multilineTextAlignment(.leading)
                                .focused($focusedField, equals: .title)

                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 6) {
                            TextField("Artist", text: $editedArtist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .focused($focusedField, equals: .artist)

                            Image(systemName: "pencil")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: coverSize + 8, alignment: .leading)

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }

                    // Arrange tracklist
                    HStack {
                        if !reorderedItems.isEmpty {
                            Button {
                                addDiscMarker()
                            } label: {
                                Label("Add disc marker", systemImage: "plus")
                                    .font(.subheadline)
                            }
                            .disabled(reorderedItems.filter(\.isDiscMarker).count >= 100)
                        }

                        Spacer()

                        if album.canEdit {
                            Menu {
                                Button {
                                    showAddTrackSheet = true
                                } label: {
                                    Label("From Google Drive", systemImage: "cloud")
                                }
                                Button {
                                    showDocumentPicker = true
                                } label: {
                                    Label("From iPhone", systemImage: "iphone")
                                }
                            } label: {
                                Label("Add tracks", systemImage: "plus.circle")
                                    .font(.subheadline)
                            }
                            .disabled(isUploadingTracks)
                        }
                    }
                    .padding(.horizontal)

                    if !reorderedItems.isEmpty {

                        VStack(alignment: .leading, spacing: 0) {
                            List {
                                ForEach(Array(reorderedItems.enumerated()), id: \.element.id) { index, item in
                                    Group {
                                        switch item {
                                        case .track(let track):
                                            HStack(spacing: 6) {
                                                TextField(
                                                    track.displayName,
                                                    text: Binding(
                                                        get: { editedTrackNames[track.googleFileId] ?? track.displayName },
                                                        set: { editedTrackNames[track.googleFileId] = $0 }
                                                    )
                                                )
                                                .font(.body)
                                                .lineLimit(1)
                                                .focused($focusedField, equals: .track(track.googleFileId))

                                                Image(systemName: "pencil")
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)

                                                if album.canEdit {
                                                    Button {
                                                        trackToDelete = track
                                                    } label: {
                                                        Image(systemName: "trash")
                                                            .font(.caption)
                                                            .foregroundStyle(.red)
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                        case .discMarker:
                                            let discNumber = reorderedItems[0...index].filter(\.isDiscMarker).count
                                            HStack {
                                                Text("Disc \(discNumber)")
                                                    .font(.subheadline.bold())
                                                    .foregroundStyle(.secondary)
                                                Spacer()
                                                Button {
                                                    reorderedItems.remove(at: index)
                                                } label: {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .foregroundStyle(.tertiary)
                                                        .font(.body)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }
                                }
                                .onMove { source, destination in
                                    reorderedItems.move(fromOffsets: source, toOffset: destination)
                                }
                            }
                            .listStyle(.plain)
                            .environment(\.editMode, .constant(.active))
                            .frame(height: CGFloat(reorderedItems.count) * 44)
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.top, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            focusedField = nil
                            Task { await saveMetadata() }
                        }
                        .disabled(editedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .task {
                editedTitle = album.name
                editedArtist = album.artistName ?? ""
                let resolution = await albumArtService.resolveAlbumArt(for: album)
                coverImage = resolution.image
                await resolveFolderOwnership()
                await resolveAdditDataFileId()
                await loadTracklistItems()
            }
            .onChange(of: selectedCoverPhoto) { _, newValue in
                guard let newValue else { return }
                Task {
                    guard let data = try? await newValue.loadTransferable(type: Data.self),
                          let loaded = UIImage(data: data) else {
                        coverUploadErrorMessage = "The selected photo couldn't be loaded."
                        selectedCoverPhoto = nil
                        return
                    }
                    selectedCoverPhoto = nil
                    imageToCrop = CropItem(image: loaded)
                }
            }
            .alert(
                "Couldn't Change Album Cover",
                isPresented: Binding(
                    get: { coverUploadErrorMessage != nil },
                    set: { if !$0 { coverUploadErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(coverUploadErrorMessage ?? "")
            }
            .alert("Delete Track?", isPresented: Binding(
                get: { trackToDelete != nil },
                set: { if !$0 { trackToDelete = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let track = trackToDelete {
                        Task { await deleteTrack(track) }
                    }
                }
                Button("Cancel", role: .cancel) { trackToDelete = nil }
            } message: {
                Text("This will delete \"\(trackToDelete?.name ?? "")\" from \"\(album.name)\" in Google Drive.")
            }
            .fullScreenCover(item: $imageToCrop) { item in
                ImageCropperView(
                    image: item.image,
                    onCropped: { croppedImage in
                        imageToCrop = nil
                        Task { await uploadCroppedCover(croppedImage) }
                    },
                    onCancelled: {
                        imageToCrop = nil
                    }
                )
            }
            .fileImporter(
                isPresented: $showDocumentPicker,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: true
            ) { result in
                Task { await handlePickedFiles(result) }
            }
            .sheet(isPresented: $showAddTrackSheet) {
                DriveAudioPickerView(targetFolderId: album.googleFolderId) { files in
                    Task { await handleDriveFilesAdded(files) }
                }
            }
            .overlay {
                if isUploadingTracks {
                    ZStack {
                        Color.black.opacity(0.3)
                        ProgressView("Adding tracks...")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .ignoresSafeArea()
                }
            }
        }
    }

    private func saveMetadata() async {
        let trimmedTitle = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        isSaving = true
        defer { isSaving = false }

        let trimmedArtist = editedArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        let newArtist: String? = trimmedArtist.isEmpty ? nil : trimmedArtist

        // Snapshot current state for rollback
        let previousName = album.name
        let previousArtist = album.artistName
        let allTracks = reorderedItems.compactMap(\.asTrack)
        let previousTrackNames = Dictionary(uniqueKeysWithValues: allTracks.map { ($0.googleFileId, $0.name) })
        let previousTrackNumbers = Dictionary(uniqueKeysWithValues: allTracks.map { ($0.googleFileId, $0.trackNumber) })

        album.name = trimmedTitle
        album.artistName = newArtist
        try? modelContext.save()

        do {
            // Rename the actual Drive folder
            try await driveService.renameFile(fileId: album.googleFolderId, newName: trimmedTitle)

            // Rename changed tracks in Drive
            try await renameChangedTracks()

            // Save unified .addit-data (tracklist + artist)
            try await saveAdditData(inFolder: album.googleFolderId, artist: newArtist)

            dismiss()
        } catch {
            // Revert all local changes on failure
            album.name = previousName
            album.artistName = previousArtist
            for item in reorderedItems {
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
            errorMessage = error.localizedDescription
        }
    }

    private func uploadCroppedCover(_ croppedImage: UIImage) async {
        guard !isUploadingCover else { return }

        isUploadingCover = true
        defer { isUploadingCover = false }

        do {
            guard let jpegData = croppedImage.jpegData(compressionQuality: 0.9) else {
                throw CoverUploadError.invalidImageData
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
            coverImage = cachedImage

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

    private func saveAdditData(inFolder folderId: String, artist: String?) async throws {
        // Build interleaved tracklist with disc markers
        var discNumber = 0
        let tracklist: [String] = reorderedItems.map { item in
            switch item {
            case .track(let track):
                return track.name
            case .discMarker:
                discNumber += 1
                return "\(AdditMetadata.discMarkerPrefix)Disc \(discNumber)"
            }
        }

        let metadata = AdditMetadata(
            tracklist: tracklist,
            artist: artist
        )
        let data = try JSONEncoder().encode(metadata)

        if let existingId = additDataFileId {
            if album.isFolderOwner && !additDataOwnedByMe {
                // Claim ownership: remove the file we don't own and create a new one
                try await driveService.removeFileFromFolder(fileId: existingId, folderId: folderId)
                let item = try await driveService.createFile(
                    name: ".addit-data",
                    mimeType: "application/json",
                    inFolder: folderId,
                    data: data
                )
                additDataFileId = item.id
                additDataOwnedByMe = true
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
            additDataFileId = item.id
            additDataOwnedByMe = true
        }

        // Assign track numbers (skip disc markers)
        var trackNumber = 1
        for item in reorderedItems {
            if case .track(let track) = item {
                track.trackNumber = trackNumber
                trackNumber += 1
            }
        }
        try? modelContext.save()
    }

    private func addDiscMarker() {
        let existingDiscCount = reorderedItems.filter(\.isDiscMarker).count
        guard existingDiscCount < 100 else { return }

        let newMarker = TracklistItem.discMarker(id: UUID(), label: "")

        if existingDiscCount == 0 {
            reorderedItems.insert(newMarker, at: 0)
        } else if let lastDiscIndex = reorderedItems.lastIndex(where: \.isDiscMarker) {
            reorderedItems.insert(newMarker, at: lastDiscIndex + 1)
        }
    }

    private func deleteTrack(_ track: Track) async {
        do {
            try await driveService.deleteFile(fileId: track.googleFileId)
            reorderedItems.removeAll { $0.id == track.googleFileId }
            editedTrackNames.removeValue(forKey: track.googleFileId)
            modelContext.delete(track)
            album.trackCount = max(0, album.trackCount - 1)
            try? modelContext.save()
        } catch {
            errorMessage = "Failed to delete: \(error.localizedDescription)"
        }
        trackToDelete = nil
    }

    private func handlePickedFiles(_ result: Result<[URL], Error>) async {
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

                let driveItem = try await driveService.createFile(
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
                    trackNumber: reorderedItems.compactMap(\.asTrack).count + 1
                )
                modelContext.insert(track)
                reorderedItems.append(.track(track))
                album.trackCount += 1
            } catch {
                errorMessage = "Upload failed: \(error.localizedDescription)"
            }
        }
        try? modelContext.save()
    }

    private func handleDriveFilesAdded(_ files: [DriveItem]) async {
        isUploadingTracks = true
        defer { isUploadingTracks = false }

        for file in files {
            do {
                let copiedItem = try await driveService.copyFile(
                    fileId: file.id,
                    toFolder: album.googleFolderId
                )

                let track = Track(
                    googleFileId: copiedItem.id,
                    name: copiedItem.name,
                    album: album,
                    mimeType: copiedItem.mimeType,
                    fileSize: copiedItem.fileSizeBytes,
                    trackNumber: reorderedItems.compactMap(\.asTrack).count + 1
                )
                modelContext.insert(track)
                reorderedItems.append(.track(track))
                album.trackCount += 1
            } catch {
                errorMessage = "Copy failed: \(error.localizedDescription)"
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

    private func loadTracklistItems() async {
        let sortedTracks = album.tracks.sorted { $0.trackNumber < $1.trackNumber }

        // Try to load existing addit-data to get disc markers
        if let fileId = additDataFileId {
            do {
                let data = try await driveService.downloadFileData(fileId: fileId)
                if let metadata = try? JSONDecoder().decode(AdditMetadata.self, from: data),
                   let tracklist = metadata.tracklist {
                    var items: [TracklistItem] = []
                    var matchedIds = Set<String>()

                    for entry in tracklist {
                        if entry.hasPrefix(AdditMetadata.discMarkerPrefix) {
                            let label = String(entry.dropFirst(AdditMetadata.discMarkerPrefix.count))
                            items.append(.discMarker(id: UUID(), label: label))
                        } else if let track = sortedTracks.first(where: { $0.name == entry && !matchedIds.contains($0.googleFileId) }) {
                            items.append(.track(track))
                            matchedIds.insert(track.googleFileId)
                        }
                    }

                    // Append any tracks not in the tracklist
                    for track in sortedTracks where !matchedIds.contains(track.googleFileId) {
                        items.append(.track(track))
                    }

                    reorderedItems = items
                    return
                }
            } catch {
                // Fall through to default
            }
        }

        // Default: just tracks, no disc markers
        reorderedItems = sortedTracks.map { .track($0) }
    }

    private func resolveFolderOwnership() async {
        do {
            let folderMeta = try await driveService.getFileMetadata(fileId: album.googleFolderId)
            if let ownedByMe = folderMeta.ownedByMe, ownedByMe != album.isFolderOwner {
                album.isFolderOwner = ownedByMe
                try? modelContext.save()
            }
        } catch {
            // Best effort — keep existing value
        }
    }

    private func resolveAdditDataFileId() async {
        do {
            if let item = try await driveService.findFile(named: ".addit-data", inFolder: album.googleFolderId) {
                additDataFileId = item.id
                additDataOwnedByMe = item.ownedByMe ?? true
                return
            }
        } catch {
            // Best effort
        }
        additDataFileId = nil
        additDataOwnedByMe = true
    }

    private func renameChangedTracks() async throws {
        for item in reorderedItems {
            guard case .track(let track) = item else { continue }
            guard let editedName = editedTrackNames[track.googleFileId] else { continue }
            let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Preserve the original file extension
            let ext = (track.name as NSString).pathExtension
            let newFileName = ext.isEmpty ? trimmed : "\(trimmed).\(ext)"
            guard newFileName != track.name else { continue }

            try await driveService.renameFile(fileId: track.googleFileId, newName: newFileName)
            track.name = newFileName
        }
        try? modelContext.save()
    }

}

struct AlbumArtworkThumbnail: View {
    let album: Album
    var size: CGFloat = 148
    @Environment(\.modelContext) private var modelContext
    @Environment(AlbumArtService.self) private var albumArtService
    @Environment(ThemeService.self) private var themeService
    @State private var image: UIImage?

    private var artworkTaskID: String {
        let refreshMarker = albumArtService.lastUpdatedAlbumFolderId == album.googleFolderId
            ? albumArtService.artworkRefreshVersion
            : 0
        return "\(album.coverArtTaskID)-\(refreshMarker)"
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(
                LinearGradient(
                    colors: [themeService.accentColor.opacity(0.6), themeService.accentColor.opacity(0.3)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.27))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onAppear {
                // Show cached image instantly — no async, no file I/O
                if image == nil, let coverFileId = album.coverFileId {
                    image = albumArtService.cachedImage(for: coverFileId)
                }
            }
            .task(id: artworkTaskID) {
                // Resolve fully (disk cache + network) in background
                let resolution = await albumArtService.resolveAlbumArt(for: album)
                if resolution.image != nil || image == nil {
                    image = resolution.image
                }
                albumArtService.applyResolution(resolution, to: album, modelContext: modelContext)
            }
    }
}

private struct CropItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

private enum CoverUploadError: LocalizedError {
    case unreadableSelection
    case invalidImageData

    var errorDescription: String? {
        switch self {
        case .unreadableSelection:
            return "The selected photo couldn't be loaded."
        case .invalidImageData:
            return "The selected photo couldn't be converted to a JPEG cover."
        }
    }
}
