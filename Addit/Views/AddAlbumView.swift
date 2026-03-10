import SwiftUI
import SwiftData

struct AddAlbumView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(GoogleDriveService.self) private var driveService

    @State private var folders: [DriveItem] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedFolder: DriveItem?
    @State private var addedSuccessfully = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && folders.isEmpty {
                    ProgressView("Loading folders...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Error",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else if folders.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if folders.isEmpty {
                    ContentUnavailableView(
                        "No Folders Found",
                        systemImage: "folder",
                        description: Text("No folders found in your Google Drive")
                    )
                } else {
                    List(folders) { folder in
                        Button {
                            selectedFolder = folder
                        } label: {
                            Label(folder.name, systemImage: "folder.fill")
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search folders")
            .onChange(of: searchText) { _, newValue in
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    await loadFolders(search: newValue)
                }
            }
            .navigationTitle("Add Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(item: $selectedFolder, onDismiss: {
                if addedSuccessfully {
                    dismiss()
                }
            }) { folder in
                FolderPreviewSheet(
                    folder: folder,
                    existingFolderIds: existingFolderIds(),
                    onAdd: { audioFiles in
                        addToLibrary(folder: folder, audioFiles: audioFiles)
                    }
                )
            }
            .alert("Failed to Save", isPresented: .init(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "Unknown error")
            }
            .task {
                await loadFolders()
            }
        }
    }

    private func existingFolderIds() -> Set<String> {
        let descriptor = FetchDescriptor<Album>()
        let albums = (try? modelContext.fetch(descriptor)) ?? []
        return Set(albums.map(\.googleFolderId))
    }

    private func addToLibrary(folder: DriveItem, audioFiles: [DriveItem]) {
        let album = Album(
            googleFolderId: folder.id,
            name: folder.name,
            trackCount: audioFiles.count,
            canEdit: folder.canAddChildren
        )
        modelContext.insert(album)

        for (index, file) in audioFiles.enumerated() {
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

        do {
            try modelContext.save()
            addedSuccessfully = true
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func loadFolders(search: String = "") async {
        isLoading = true
        errorMessage = nil
        do {
            let response: DriveFileListResponse
            if search.isEmpty {
                response = try await driveService.listFolders()
            } else {
                response = try await driveService.searchFolders(query: search)
            }
            folders = response.files
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct FolderPreviewSheet: View {
    let folder: DriveItem
    let existingFolderIds: Set<String>
    let onAdd: ([DriveItem]) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(GoogleDriveService.self) private var driveService

    @State private var audioFiles: [DriveItem] = []
    @State private var isLoading = true
    @State private var isAdding = false
    @State private var errorMessage: String?

    private var alreadyAdded: Bool {
        existingFolderIds.contains(folder.id)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading tracks...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Error",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else if audioFiles.isEmpty {
                    ContentUnavailableView(
                        "No Audio Files",
                        systemImage: "music.note",
                        description: Text("This folder doesn't contain any audio files")
                    )
                } else {
                    List {
                        Section("\(audioFiles.count) audio file\(audioFiles.count == 1 ? "" : "s")") {
                            ForEach(audioFiles) { file in
                                Label(file.name, systemImage: "music.note")
                            }
                        }
                    }
                }
            }
            .navigationTitle(folder.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !audioFiles.isEmpty {
                        if alreadyAdded || isAdding {
                            if isAdding {
                                ProgressView()
                            } else {
                                Label("Added", systemImage: "checkmark")
                            }
                        } else {
                            Button {
                                isAdding = true
                                onAdd(audioFiles)
                                dismiss()
                            } label: {
                                Label("Add to Library", systemImage: "plus")
                            }
                        }
                    }
                }
            }
            .task {
                await loadAudioFiles()
            }
        }
    }

    private func loadAudioFiles() async {
        isLoading = true
        do {
            let response = try await driveService.listAudioFiles(inFolder: folder.id)
            audioFiles = response.files
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
