import SwiftUI
import SwiftData

enum FolderSource: String, CaseIterable {
    case personal = "Personal"
    case starred = "Starred"
    case shared = "Shared"

    var icon: String {
        switch self {
        case .personal: return "folder.fill"
        case .starred: return "star.fill"
        case .shared: return "person.2.fill"
        }
    }

    var emptyTitle: String {
        switch self {
        case .personal: return "No Folders"
        case .starred: return "No Starred Folders"
        case .shared: return "No Shared Folders"
        }
    }

    var emptyDescription: String {
        switch self {
        case .personal: return "No folders found in your Google Drive"
        case .starred: return "You haven't starred any folders"
        case .shared: return "No folders have been shared with you"
        }
    }
}

struct AddAlbumView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(GoogleDriveService.self) private var driveService
    @Environment(GoogleAuthService.self) private var authService

    @State private var selectedSource: FolderSource = .personal
    @State private var searchText = ""
    @State private var addedSuccessfully = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Source", selection: $selectedSource) {
                    ForEach(FolderSource.allCases, id: \.self) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                FolderBrowserView(
                    folderId: nil,
                    folderName: selectedSource.rawValue,
                    source: selectedSource,
                    existingFolderIds: existingFolderIds(),
                    onAdd: { folder, audioFiles in
                        addToLibrary(folder: folder, audioFiles: audioFiles)
                    }
                )
                .id(selectedSource)
            }
            .navigationDestination(for: DriveItem.self) { folder in
                FolderBrowserView(
                    folderId: folder.id,
                    folderName: folder.name,
                    source: selectedSource,
                    existingFolderIds: existingFolderIds(),
                    onAdd: { folder, audioFiles in
                        addToLibrary(folder: folder, audioFiles: audioFiles)
                    }
                )
            }
            .searchable(text: $searchText, prompt: "Search folders")
            .navigationTitle("Add Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Failed to Save", isPresented: .init(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "Unknown error")
            }
            .onChange(of: addedSuccessfully) { _, success in
                if success { dismiss() }
            }
        }
    }

    private func existingFolderIds() -> Set<String> {
        let accountId = authService.userEmail.map { AccountManager.storageIdentifier(for: $0) }
        let descriptor = FetchDescriptor<Album>(
            predicate: #Predicate { $0.accountId == accountId }
        )
        let albums = (try? modelContext.fetch(descriptor)) ?? []
        return Set(albums.map(\.googleFolderId))
    }

    private func addToLibrary(folder: DriveItem, audioFiles: [DriveItem]) {
        let existingAlbums = (try? modelContext.fetch(FetchDescriptor<Album>())) ?? []
        let nextOrder = (existingAlbums.map(\.displayOrder).max() ?? -1) + 1

        let album = Album(
            googleFolderId: folder.id,
            name: folder.name,
            trackCount: audioFiles.count,
            canEdit: folder.canEdit,
            displayOrder: nextOrder
        )
        if let email = authService.userEmail {
            album.accountId = AccountManager.storageIdentifier(for: email)
        }
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

        do {
            try modelContext.save()
            Task {
                // Resolve folder ownership
                let folderMeta = try? await driveService.getFileMetadata(fileId: folder.id)
                album.isFolderOwner = folderMeta?.ownedByMe ?? false
                try? modelContext.save()

                await initializeAdditData(for: album, audioFiles: audioFiles)
                await loadAdditMetadata(for: album)
                if album.isFolderOwner {
                    await claimCoverOwnership(for: album)
                }
                await syncCoverArt(for: album, folderId: folder.id)
            }
            addedSuccessfully = true
        } catch {
            saveError = error.localizedDescription
        }
    }

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

    private func syncCoverArt(for album: Album, folderId: String) async {
        let coverItem = try? await driveService.findCoverImage(inFolder: folderId)
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

struct FolderBrowserView: View {
    let folderId: String?
    let folderName: String
    let source: FolderSource
    let existingFolderIds: Set<String>
    let onAdd: (DriveItem, [DriveItem]) -> Void

    @Environment(GoogleDriveService.self) private var driveService
    @State private var subfolders: [DriveItem] = []
    @State private var audioFiles: [DriveItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var isRoot: Bool { folderId == nil }

    private var currentFolder: DriveItem? {
        guard let folderId else { return nil }
        return DriveItem(
            id: folderId,
            name: folderName,
            mimeType: "application/vnd.google-apps.folder",
            size: nil,
            parents: nil,
            capabilities: nil,
            ownedByMe: nil,
            modifiedTime: nil
        )
    }

    private var alreadyAdded: Bool {
        guard let folderId else { return false }
        return existingFolderIds.contains(folderId)
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Error",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if subfolders.isEmpty && audioFiles.isEmpty {
                if isRoot {
                    ContentUnavailableView(
                        source.emptyTitle,
                        systemImage: source.icon,
                        description: Text(source.emptyDescription)
                    )
                } else {
                    ContentUnavailableView(
                        "Empty Folder",
                        systemImage: "folder",
                        description: Text("This folder is empty")
                    )
                }
            } else {
                List {
                    if !subfolders.isEmpty {
                        Section(isRoot ? "Folders" : "Subfolders") {
                            ForEach(subfolders) { folder in
                                NavigationLink(value: folder) {
                                    Label(folder.name, systemImage: "folder.fill")
                                }
                            }
                        }
                    }

                    if !audioFiles.isEmpty {
                        Section("\(audioFiles.count) audio file\(audioFiles.count == 1 ? "" : "s")") {
                            ForEach(audioFiles) { file in
                                Label(file.name, systemImage: "music.note")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(isRoot ? "" : folderName)
        .navigationBarTitleDisplayMode(isRoot ? .inline : .large)
        .toolbar {
            if !isRoot && !audioFiles.isEmpty && !isLoading {
                ToolbarItem(placement: .confirmationAction) {
                    if alreadyAdded {
                        Label("Added", systemImage: "checkmark")
                            .foregroundStyle(.secondary)
                    } else if let currentFolder {
                        Button {
                            onAdd(currentFolder, audioFiles)
                        } label: {
                            Label("Add to Library", systemImage: "plus")
                        }
                    }
                }
            }
        }
        .task {
            await loadContents()
        }
    }

    private func loadContents() async {
        isLoading = true
        errorMessage = nil

        do {
            if isRoot {
                let response: DriveFileListResponse
                switch source {
                case .personal:
                    response = try await driveService.listFolders()
                case .starred:
                    response = try await driveService.listStarredFolders()
                case .shared:
                    response = try await driveService.listSharedFolders()
                }
                subfolders = response.files
                audioFiles = []
            } else {
                async let foldersResponse = driveService.listSubfolders(inFolder: folderId!)
                async let audioResponse = driveService.listAudioFiles(inFolder: folderId!)

                let folders = try await foldersResponse
                let audio = try await audioResponse

                subfolders = folders.files
                audioFiles = audio.files
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

struct CopyAlbumFromDriveView: View {
    let onCopy: (DriveItem, [DriveItem]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedSource: FolderSource = .personal
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Source", selection: $selectedSource) {
                    ForEach(FolderSource.allCases, id: \.self) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                FolderBrowserView(
                    folderId: nil,
                    folderName: selectedSource.rawValue,
                    source: selectedSource,
                    existingFolderIds: [],
                    onAdd: { folder, audioFiles in
                        onCopy(folder, audioFiles)
                        dismiss()
                    }
                )
                .id(selectedSource)
            }
            .navigationDestination(for: DriveItem.self) { folder in
                FolderBrowserView(
                    folderId: folder.id,
                    folderName: folder.name,
                    source: selectedSource,
                    existingFolderIds: [],
                    onAdd: { folder, audioFiles in
                        onCopy(folder, audioFiles)
                        dismiss()
                    }
                )
            }
            .searchable(text: $searchText, prompt: "Search folders")
            .navigationTitle("Copy from Google Drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
