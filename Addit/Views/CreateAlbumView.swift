import SwiftUI
import SwiftData

struct CreateAlbumView: View {
    let onCreate: (Album) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(CloudServiceRouter.self) private var cloudRouter
    @Environment(CloudAuthCoordinator.self) private var authService

    private var driveService: any CloudDriveService {
        cloudRouter.activeService
    }

    @State private var selectedSource: FolderSource = .personal
    @State private var showNameAlert = false
    @State private var newFolderName = "New Album"
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var targetParentId: String?
    @State private var targetShouldStar: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Source", selection: $selectedSource) {
                    ForEach(FolderSource.availableCases(for: driveService), id: \.self) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                ParentFolderBrowserView(
                    folderId: nil,
                    folderName: selectedSource.rawValue,
                    source: selectedSource,
                    onSelectParent: { parentId, markStarred in
                        targetParentId = parentId
                        targetShouldStar = markStarred
                        newFolderName = "New Album"
                        showNameAlert = true
                    }
                )
                .id(selectedSource)
            }
            .navigationDestination(for: DriveItem.self) { folder in
                ParentFolderBrowserView(
                    folderId: folder.id,
                    folderName: folder.name,
                    source: selectedSource,
                    onSelectParent: { parentId, markStarred in
                        targetParentId = parentId
                        targetShouldStar = markStarred
                        newFolderName = "New Album"
                        showNameAlert = true
                    }
                )
            }
            .navigationTitle("Choose Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .alert("New Album", isPresented: $showNameAlert) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                guard let parentId = targetParentId else { return }
                let markStarred = targetShouldStar
                Task { await createFolder(name: newFolderName, inParent: parentId, markStarred: markStarred) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the new folder")
        }
        .alert("Error", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .disabled(isCreating)
        .overlay {
            if isCreating {
                Color.black.opacity(0.1).ignoresSafeArea()
                ProgressView("Creating...")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func createFolder(name: String, inParent parentId: String, markStarred: Bool) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        isCreating = true
        defer { isCreating = false }

        do {
            // Create folder in Drive
            let folder = try await driveService.createFolder(name: trimmedName, inParent: parentId)

            // Star the new folder if the user picked the Starred tab
            if markStarred {
                try? await driveService.setStarred(fileId: folder.id, starred: true)
            }

            // Initialize .addit-data with empty tracklist
            let metadata = AdditMetadata(tracklist: [])
            let data = try JSONEncoder().encode(metadata)
            _ = try await driveService.createFile(
                name: ".addit-data",
                mimeType: "application/json",
                inFolder: folder.id,
                data: data
            )

            // Create local Album record
            let existingAlbums = (try? modelContext.fetch(FetchDescriptor<Album>())) ?? []
            let nextOrder = (existingAlbums.map(\.displayOrder).max() ?? -1) + 1

            let album = Album(
                googleFolderId: folder.id,
                name: folder.name,
                trackCount: 0,
                canEdit: true,
                isFolderOwner: true,
                displayOrder: nextOrder,
                // Stamp with the provider the folder was created in —
                // this is what routes every subsequent API call for it.
                storageSource: authService.activeProvider.storageSource
            )
            if let email = authService.userEmail {
                album.accountId = AccountManager.storageIdentifier(for: email)
            }
            modelContext.insert(album)
            try modelContext.save()

            dismiss()

            // Small delay to let the sheet dismiss before opening the editor
            try? await Task.sleep(for: .milliseconds(300))
            await MainActor.run {
                onCreate(album)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Parent Folder Browser

/// A folder browser for choosing WHERE to create a new folder.
/// Similar to FolderBrowserView but shows a "Create Here" button instead of "Add to Library".
struct ParentFolderBrowserView: View {
    let folderId: String?
    let folderName: String
    let source: FolderSource
    var buttonLabel: String = "Create Here"
    var buttonIcon: String = "plus"
    /// Callback receives the destination parent id and whether the new folder
    /// should be marked as starred (true when the user is at the root of the
    /// Starred tab — since "Starred" is a flag, not a real parent folder).
    let onSelectParent: (_ parentId: String, _ markStarred: Bool) -> Void

    @Environment(CloudServiceRouter.self) private var cloudRouter
    private var driveService: any CloudDriveService {
        cloudRouter.activeService
    }
    @State private var subfolders: [DriveItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var isRoot: Bool { folderId == nil }

    /// Returns the parent folder ID for creating a new folder, or nil if creation isn't allowed here.
    /// At root level: allowed for Personal/Starred (using "root"), not for Shared.
    /// Inside a folder: always allowed using the folder's ID.
    private var createParentId: String? {
        if let folderId {
            return folderId
        }
        // At root level — only Personal and Starred can create at Drive root
        if source == .personal || source == .starred {
            return "root"
        }
        return nil
    }

    /// New folders should be starred when the user explicitly chose the Starred
    /// tab's root as the destination. "Starred" isn't a real parent folder — it's
    /// a boolean flag on the file — so we star it after creating.
    private var shouldStar: Bool {
        isRoot && source == .starred
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
            } else if subfolders.isEmpty {
                if isRoot {
                    ContentUnavailableView(
                        source.emptyTitle,
                        systemImage: source.icon,
                        description: Text(source.emptyDescription)
                    )
                } else {
                    ContentUnavailableView(
                        "No Subfolders",
                        systemImage: "folder",
                        description: Text("You can still create a new album here")
                    )
                }
            } else {
                List {
                    Section(isRoot ? "Folders" : "Subfolders") {
                        ForEach(subfolders) { folder in
                            NavigationLink(value: folder) {
                                Label(folder.name, systemImage: "folder.fill")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(isRoot ? "" : folderName)
        .navigationBarTitleDisplayMode(isRoot ? .inline : .large)
        .toolbar {
            if !isLoading, let parentId = createParentId {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onSelectParent(parentId, shouldStar)
                    } label: {
                        Label(buttonLabel, systemImage: buttonIcon)
                    }
                }
            }
        }
        .task {
            await loadFolders()
        }
    }

    private func loadFolders() async {
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
            } else {
                let response = try await driveService.listSubfolders(inFolder: folderId!)
                subfolders = response.files
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
