import SwiftUI
import SwiftData
import UIKit
import PhotosUI

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(GoogleAuthService.self) private var authService
    @Environment(GoogleDriveService.self) private var driveService
    @Environment(AudioPlayerService.self) private var playerService
    @Environment(AlbumArtService.self) private var albumArtService
    @Query(sort: \Album.dateAdded, order: .reverse) private var albums: [Album]
    @State private var showAddAlbum = false
    @State private var showSettings = false
    @State private var selectedAlbum: Album?
    @State private var metadataEditorAlbum: Album?

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        ZStack {
            ScrollView {
                if albums.isEmpty {
                    ContentUnavailableView(
                        "No Albums Yet",
                        systemImage: "music.note.list",
                        description: Text("Tap + to add folders from Google Drive")
                    )
                    .padding(.top, 100)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(albums) { album in
                            Button {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                                    selectedAlbum = album
                                }
                            } label: {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    metadataEditorAlbum = album
                                } label: {
                                    Label("Edit", systemImage: "pencil")
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

            if let selectedAlbum {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                            self.selectedAlbum = nil
                        }
                    }
                    .transition(.opacity)

                FloatingAlbumPanel(album: selectedAlbum) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                        self.selectedAlbum = nil
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 24)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.95).combined(with: .opacity),
                    removal: .opacity
                ))
                .zIndex(1)
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddAlbum = true } label: {
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
                        authService.signOut()
                    }
                } label: {
                    Image(systemName: "person.crop.circle")
                }
            }
        }
        .sheet(isPresented: $showAddAlbum) {
            AddAlbumView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(item: $metadataEditorAlbum) { album in
            AlbumMetadataEditorSheet(album: album)
        }
        .safeAreaInset(edge: .bottom) {
            if playerService.currentTrack != nil {
                Color.clear.frame(height: 64)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: selectedAlbum != nil)
    }

}

struct FloatingAlbumPanel: View {
    let album: Album
    let onClose: () -> Void

    var body: some View {
        GeometryReader { proxy in
            NavigationStack {
                AlbumDetailView(album: album, embeddedInPanel: true)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                onClose()
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .accessibilityLabel("Close")
                        }
                    }
            }
            .frame(
                width: min(700, proxy.size.width - 24),
                height: min(760, proxy.size.height * 0.86)
            )
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            }
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.16), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 120)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
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
    @State private var additDataFolderId: String?
    @State private var selectedCoverPhoto: PhotosPickerItem?
    @State private var isUploadingCover = false
    @State private var coverUploadErrorMessage: String?
    @State private var coverImage: UIImage?
    @State private var reorderedTracks: [Track] = []
    @State private var editedTrackNames: [String: String] = [:]
    @State private var tracklistFileId: String?
    @State private var isSavingOrder = false
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
                    if !reorderedTracks.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            List {
                                ForEach(reorderedTracks) { track in
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
                                    }
                                }
                                .onMove { source, destination in
                                    reorderedTracks.move(fromOffsets: source, toOffset: destination)
                                }
                            }
                            .listStyle(.plain)
                            .environment(\.editMode, .constant(.active))
                            .frame(height: CGFloat(reorderedTracks.count) * 44)
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
                reorderedTracks = album.tracks.sorted { $0.trackNumber < $1.trackNumber }
                let resolution = await albumArtService.resolveAlbumArt(for: album)
                coverImage = resolution.image
                await resolveAdditDataFolder()
                await resolveTracklistFileId()
            }
            .onChange(of: selectedCoverPhoto) { _, newValue in
                if newValue != nil {
                    Task { await uploadSelectedCover() }
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
        }
    }

    private func saveMetadata() async {
        let trimmedTitle = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        isSaving = true
        defer { isSaving = false }

        let trimmedArtist = editedArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        let newArtist: String? = trimmedArtist.isEmpty ? nil : trimmedArtist

        let previousName = album.name
        let previousArtist = album.artistName

        album.name = trimmedTitle
        album.artistName = newArtist
        try? modelContext.save()

        do {
            // Rename the actual Drive folder
            try await driveService.renameFile(fileId: album.googleFolderId, newName: trimmedTitle)

            // Save artist to addit-data metadata file
            let folderId = additDataFolderId ?? album.googleFolderId
            try await upsertMetadataFile(
                named: ".addit-artist",
                content: newArtist ?? "",
                inFolder: folderId
            )

            // Rename changed tracks in Drive
            try await renameChangedTracks()

            // Save track order (uses updated names)
            try await saveTrackOrder(inFolder: folderId)

            dismiss()
        } catch {
            // Revert local changes on failure
            album.name = previousName
            album.artistName = previousArtist
            try? modelContext.save()
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func uploadSelectedCover() async {
        guard let selectedCoverPhoto, !isUploadingCover else { return }

        isUploadingCover = true
        defer {
            isUploadingCover = false
            self.selectedCoverPhoto = nil
        }

        do {
            guard let selectedData = try await selectedCoverPhoto.loadTransferable(type: Data.self) else {
                throw CoverUploadError.unreadableSelection
            }
            guard let image = UIImage(data: selectedData),
                  let jpegData = image.jpegData(compressionQuality: 0.9) else {
                throw CoverUploadError.invalidImageData
            }

            let previousCoverFileId = album.coverFileId
            let additDataFolder = try await driveService.findOrCreateFolder(named: "addit-data", inParent: album.googleFolderId)
            let coverItem = try await driveService.upsertCoverImage(inFolder: additDataFolder.id, data: jpegData)

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
            album.coverUpdatedAt = .now
            try? modelContext.save()
            albumArtService.bumpRefreshToken(for: album.googleFolderId)
        } catch {
            coverUploadErrorMessage = error.localizedDescription
        }
    }

    private func upsertMetadataFile(named name: String, content: String, inFolder folderId: String) async throws {
        guard let data = content.data(using: .utf8) else { return }
        if let existing = try await driveService.findFile(named: name, inFolder: folderId) {
            try await driveService.updateFileData(fileId: existing.id, data: data, mimeType: "text/plain")
        } else {
            _ = try await driveService.createFile(
                name: name,
                mimeType: "text/plain",
                inFolder: folderId,
                data: data
            )
        }
    }

    private func resolveAdditDataFolder() async {
        do {
            if let item = try await driveService.findFile(named: "addit-data", inFolder: album.googleFolderId),
               item.isFolder {
                additDataFolderId = item.id
                return
            }
        } catch {
            // Best effort
        }
        additDataFolderId = nil
    }

    private func resolveTracklistFileId() async {
        do {
            if let folderId = additDataFolderId,
               let item = try await driveService.findFile(named: ".addit-tracklist", inFolder: folderId) {
                tracklistFileId = item.id
                return
            }
            if let item = try await driveService.findFile(named: ".addit-tracklist", inFolder: album.googleFolderId) {
                tracklistFileId = item.id
                return
            }
        } catch {
            // Best effort
        }
        tracklistFileId = nil
    }

    private func renameChangedTracks() async throws {
        for track in reorderedTracks {
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

    private func saveTrackOrder(inFolder folderId: String) async throws {
        let content = reorderedTracks.map(\.name).joined(separator: "\n")
        guard let data = content.data(using: .utf8) else { return }

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

        for (index, track) in reorderedTracks.enumerated() {
            track.trackNumber = index + 1
        }
        try? modelContext.save()
    }
}

struct AlbumArtworkThumbnail: View {
    let album: Album
    @Environment(\.modelContext) private var modelContext
    @Environment(AlbumArtService.self) private var albumArtService
    @Environment(ThemeService.self) private var themeService
    @State private var image: UIImage?
    private let thumbnailSize: CGFloat = 148

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
            .frame(width: thumbnailSize, height: thumbnailSize)
            .overlay {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .task(id: artworkTaskID) {
                let resolution = await albumArtService.resolveAlbumArt(for: album)
                image = resolution.image
                albumArtService.applyResolution(resolution, to: album, modelContext: modelContext)
            }
    }
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
