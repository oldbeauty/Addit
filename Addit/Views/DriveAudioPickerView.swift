import SwiftUI

@Observable
private class AudioSelection {
    var files: [DriveItem] = []

    func isSelected(_ file: DriveItem) -> Bool {
        files.contains(where: { $0.id == file.id })
    }

    func toggle(_ file: DriveItem) {
        if let index = files.firstIndex(where: { $0.id == file.id }) {
            files.remove(at: index)
        } else {
            files.append(file)
        }
    }
}

struct DriveAudioPickerView: View {
    let targetFolderId: String
    let onFilesAdded: ([DriveItem]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(CloudServiceRouter.self) private var cloudRouter
    @State private var selectedSource: FolderSource = .personal
    @State private var selection = AudioSelection()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Source", selection: $selectedSource) {
                    ForEach(FolderSource.availableCases(for: cloudRouter.activeService), id: \.self) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                AudioFileBrowserView(
                    folderId: nil,
                    folderName: selectedSource.rawValue,
                    source: selectedSource,
                    selection: selection,
                    excludeFolderId: targetFolderId,
                    onCancel: { dismiss() },
                    onAdd: {
                        onFilesAdded(selection.files)
                        dismiss()
                    }
                )
                .id(selectedSource)
            }
            .flatSlideNavigation()
            .navigationDestination(for: DriveItem.self) { folder in
                AudioFileBrowserView(
                    folderId: folder.id,
                    folderName: folder.name,
                    source: selectedSource,
                    selection: selection,
                    excludeFolderId: targetFolderId,
                    onCancel: { dismiss() },
                    onAdd: {
                        onFilesAdded(selection.files)
                        dismiss()
                    }
                )
            }
        }
    }
}

private struct AudioFileRow: View {
    let file: DriveItem
    let selection: AudioSelection

    var body: some View {
        Button {
            selection.toggle(file)
        } label: {
            HStack {
                Label(file.name, systemImage: "music.note")
                Spacer()
                if selection.isSelected(file) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AudioFileBrowserView: View {
    let folderId: String?
    let folderName: String
    let source: FolderSource
    let selection: AudioSelection
    let excludeFolderId: String
    let onCancel: () -> Void
    let onAdd: () -> Void

    @Environment(CloudServiceRouter.self) private var cloudRouter
    private var driveService: any CloudDriveService {
        cloudRouter.activeService
    }
    @State private var subfolders: [DriveItem] = []
    @State private var audioFiles: [DriveItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var isRoot: Bool { folderId == nil }

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
                emptyView
            } else {
                contentList
            }
        }
        .navigationTitle(isRoot ? "Add Tracks" : folderName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if isRoot {
                    Button("Cancel") { onCancel() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                let count = selection.files.count
                Button(count > 0 ? "Add (\(count))" : "Add") {
                    onAdd()
                }
                .disabled(selection.files.isEmpty)
            }
        }
        .task {
            await loadContents()
        }
    }

    @ViewBuilder
    private var emptyView: some View {
        if isRoot {
            ContentUnavailableView(
                source.emptyTitle,
                systemImage: source.icon,
                description: Text(source.emptyDescription)
            )
        } else {
            ContentUnavailableView(
                "No Audio Files",
                systemImage: "music.note",
                description: Text("This folder has no audio files")
            )
        }
    }

    private var contentList: some View {
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
                        AudioFileRow(file: file, selection: selection)
                    }
                }
            }
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
                subfolders = response.files.filter { $0.id != excludeFolderId }
                audioFiles = []
            } else {
                async let foldersResponse = driveService.listSubfolders(inFolder: folderId!)
                async let audioResponse = driveService.listAudioFiles(inFolder: folderId!)

                let folders = try await foldersResponse
                let audio = try await audioResponse

                subfolders = folders.files.filter { $0.id != excludeFolderId }
                audioFiles = audio.files
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
