import SwiftUI
import SwiftData

enum FolderSource: String, CaseIterable {
    case personal = "Personal"
    case starred = "Starred"
    case shared = "Shared"

    /// Tabs available for a given drive client — OneDrive has no
    /// starred/favorites concept, so its Starred tab is omitted.
    static func availableCases(for service: any CloudDriveService) -> [FolderSource] {
        allCases.filter { $0 != .starred || service.supportsStarred }
    }

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
        case .personal: return "No folders found in your cloud drive"
        case .starred: return "You haven't starred any folders"
        case .shared: return "No folders have been shared with you"
        }
    }
}

struct AddAlbumView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(CloudServiceRouter.self) private var cloudRouter
    @Environment(CloudAuthCoordinator.self) private var authService

    /// Client for the ACTIVE account's provider — browsing happens in
    /// whatever cloud the signed-in account lives on.
    private var driveService: any CloudDriveService {
        cloudRouter.activeService
    }

    @State private var selectedSource: FolderSource = .personal
    @State private var searchText = ""
    @State private var addedSuccessfully = false
    @State private var saveError: String?

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

                FolderBrowserView(
                    folderId: nil,
                    folderName: selectedSource.rawValue,
                    source: selectedSource,
                    existingFolderIds: existingFolderIds(),
                    onAdd: { folder, audioFiles in
                        addToLibrary(folder: folder, audioFiles: audioFiles)
                    },
                    searchQuery: searchText,
                    allowsMultiSelect: true,
                    onAddBatch: { items in
                        for item in items {
                            addToLibrary(folder: item.folder, audioFiles: item.files, thenDismiss: false)
                        }
                    }
                )
                .id(selectedSource)
            }
            .flatSlideNavigation()
            .navigationDestination(for: DriveItem.self) { folder in
                FolderBrowserView(
                    folderId: folder.id,
                    folderName: folder.name,
                    source: selectedSource,
                    existingFolderIds: existingFolderIds(),
                    onAdd: { folder, audioFiles in
                        addToLibrary(folder: folder, audioFiles: audioFiles)
                    },
                    allowsMultiSelect: true,
                    onAddBatch: { items in
                        for item in items {
                            addToLibrary(folder: item.folder, audioFiles: item.files, thenDismiss: false)
                        }
                    }
                )
            }
            .searchable(text: $searchText, prompt: "Search folders")
            .navigationTitle("Add Album")
            .navigationBarTitleDisplayMode(.inline)
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
        .presentationDragIndicator(.visible)
    }

    private func existingFolderIds() -> Set<String> {
        let accountId = authService.userEmail.map { AccountManager.storageIdentifier(for: $0) }
        let descriptor = FetchDescriptor<Album>(
            predicate: #Predicate { $0.accountId == accountId }
        )
        let albums = (try? modelContext.fetch(descriptor)) ?? []
        return Set(albums.map(\.googleFolderId))
    }

    /// `thenDismiss` is false for batch adds. `addedSuccessfully` is wired to
    /// `dismiss()`, so a batch that set it would close the sheet after its
    /// first album and abandon the rest of the selection.
    private func addToLibrary(folder: DriveItem, audioFiles: [DriveItem], thenDismiss: Bool = true) {
        let importer = AlbumImporter(driveService: driveService, modelContext: modelContext)
        do {
            let album = try importer.insert(
                folder: folder,
                audioFiles: audioFiles,
                accountId: authService.userEmail.map { AccountManager.storageIdentifier(for: $0) },
                // Stamp the album with the provider it was browsed from —
                // this is what routes every subsequent API call for it.
                storageSource: authService.activeProvider.storageSource
            )
            Task { await importer.finishImport(of: album, audioFiles: audioFiles) }
            if thenDismiss { addedSuccessfully = true }
        } catch {
            saveError = error.localizedDescription
        }
    }
}

struct FolderBrowserView: View {
    let folderId: String?
    let folderName: String
    let source: FolderSource
    let existingFolderIds: Set<String>
    let onAdd: (DriveItem, [DriveItem]) -> Void
    /// Which cloud to browse. `nil` means the account you're currently in,
    /// which is what every flow wants except "Copy from…", where the point is
    /// to reach a cloud other than the active one.
    var provider: AccountProvider? = nil
    /// Live text from the host's search bar. Non-empty swaps this folder's
    /// contents for drive-wide folder search results.
    ///
    /// Only the *root* browser is given this. `.searchable` is attached to the
    /// host's root content, so pushed folders never show a search bar — and
    /// handing them the query anyway would mean tapping a result opened a view
    /// that immediately showed the same results again instead of the folder.
    var searchQuery: String = ""
    /// Offers "Select", for adding several folders as albums in one go. Only
    /// the add-album flow wants it — "Copy from…" copies one album at a time
    /// and its callback dismisses, so a second selection would have nowhere
    /// to land.
    var allowsMultiSelect: Bool = false
    /// Receives a whole selection at once. Separate from `onAdd` because the
    /// host treats the two differently — a single add closes the picker, a
    /// batch leaves it open so you can keep going and see what's now marked
    /// "Added".
    var onAddBatch: (([(folder: DriveItem, files: [DriveItem])]) -> Void)? = nil

    @Environment(CloudServiceRouter.self) private var cloudRouter
    private var driveService: any CloudDriveService {
        guard let provider else { return cloudRouter.activeService }
        return cloudRouter.service(for: provider.storageSource)
    }
    @State private var subfolders: [DriveItem] = []
    @State private var audioFiles: [DriveItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchResults: [DriveItem] = []
    @State private var isSearching = false
    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var isAddingSelection = false
    /// Set when a batch finished with folders that held no audio — they can't
    /// become albums, and silently adding four of six selections would read as
    /// the feature dropping them.
    @State private var skippedNotice: String?
    /// Folders added since this browser appeared. `existingFolderIds` is
    /// captured when the view is built and the host fetches it manually rather
    /// than with `@Query`, so it doesn't refresh after an add — without this,
    /// a just-added folder still looked addable and selecting it again would
    /// make a duplicate album.
    @State private var addedThisSession: Set<String> = []
    /// Kept separate from `errorMessage` so a failed search doesn't wipe out
    /// the browse state behind it.
    @State private var searchError: String?

    private var isRoot: Bool { folderId == nil }

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var isSearchActive: Bool { !trimmedQuery.isEmpty }

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
        return isAdded(folderId)
    }

    private func isAdded(_ id: String) -> Bool {
        existingFolderIds.contains(id) || addedThisSession.contains(id)
    }

    /// What "Select All" can actually reach. Already-added folders stay in the
    /// list but aren't selectable, so counting them would leave the button
    /// unable to arrive at the state it promises.
    private var selectableFolders: [DriveItem] {
        subfolders.filter { !isAdded($0.id) }
    }

    private var everythingSelected: Bool {
        let selectable = selectableFolders
        return !selectable.isEmpty && selectable.allSatisfy { selection.contains($0.id) }
    }

    var body: some View {
        Group {
            if isSearchActive {
                searchLayer
            } else if isLoading {
                LoadingIndicator(label: "Loading...")
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
                                if isSelecting {
                                    selectableRow(folder)
                                } else {
                                    NavigationLink(value: folder) {
                                        Label(folder.name, systemImage: "folder.fill")
                                    }
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
            if !isRoot && !audioFiles.isEmpty && !isLoading && !isSearchActive && !isSelecting {
                ToolbarItem(placement: .confirmationAction) {
                    if alreadyAdded {
                        Label("Added", systemImage: "checkmark")
                            .foregroundStyle(.secondary)
                    } else if let currentFolder {
                        Button {
                            onAdd(currentFolder, audioFiles)
                            addedThisSession.insert(currentFolder.id)
                        } label: {
                            Label("Add to Library", systemImage: "plus")
                        }
                    }
                }
            }
            // Sits beside the "+" wherever a folder has both audio of its own
            // and subfolders.
            //
            // The exit is an X rather than a word: "Done" reads as if it kept
            // the selection, which it doesn't, and a third label beside
            // "Select All" and "Confirm n" is what tips this bar into an
            // overflow menu.
            if allowsMultiSelect && !subfolders.isEmpty && !isLoading && !isSearchActive {
                ToolbarItem(placement: .topBarTrailing) {
                    if isSelecting {
                        HStack(spacing: 12) {
                            // Flips to "Deselect All" once it has nothing left
                            // to do — otherwise the obvious way to undo a
                            // fat-fingered select-all is tapping every row.
                            Button(everythingSelected ? "Deselect All" : "Select All") {
                                selection = everythingSelected
                                    ? []
                                    : Set(selectableFolders.map(\.id))
                            }
                            .disabled(selectableFolders.isEmpty || isAddingSelection)

                            Button {
                                Task { await addSelected() }
                            } label: {
                                if isAddingSelection {
                                    ProgressView()
                                } else {
                                    Text("Confirm \(selection.count)")
                                        .fontWeight(.semibold)
                                }
                            }
                            .disabled(selection.isEmpty || isAddingSelection)

                            Button {
                                isSelecting = false
                                selection.removeAll()
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .disabled(isAddingSelection)
                            .accessibilityLabel("Stop selecting")
                        }
                    } else {
                        Button("Select") { isSelecting = true }
                    }
                }
            }
        }
        .alert("Some Folders Skipped", isPresented: Binding(
            get: { skippedNotice != nil },
            set: { if !$0 { skippedNotice = nil } }
        )) {
            Button("OK", role: .cancel) { skippedNotice = nil }
        } message: {
            Text(skippedNotice ?? "")
        }
        .task {
            await loadContents()
        }
        .task(id: trimmedQuery) {
            await runSearch()
        }
    }

    /// A folder row in select mode. Already-added folders stay visible but
    /// unselectable — hiding them would make the list shift under the user
    /// between visits, and greying them answers "did I already add this?".
    @ViewBuilder
    private func selectableRow(_ folder: DriveItem) -> some View {
        let added = isAdded(folder.id)
        let picked = selection.contains(folder.id)
        Button {
            if picked { selection.remove(folder.id) } else { selection.insert(folder.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: added ? "checkmark.circle" : (picked ? "checkmark.circle.fill" : "circle"))
                    .font(.uiTitle3)
                    .foregroundStyle(added ? AnyShapeStyle(.tertiary)
                                           : (picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)))
                Label(folder.name, systemImage: "folder.fill")
                Spacer(minLength: 0)
                if added {
                    Text("Added")
                        .font(.uiFootnote)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(added || isAddingSelection)
        .foregroundStyle(added ? .secondary : .primary)
    }

    /// Adds every selected folder as an album.
    ///
    /// Each one needs its own `listAudioFiles` — the browse listing only gives
    /// folder names, and `onAdd` needs the tracks. Sequential rather than
    /// concurrent on purpose: both providers rate-limit, and a dozen parallel
    /// listings is how you turn a batch add into a wall of 403s.
    private func addSelected() async {
        guard !selection.isEmpty else { return }
        isAddingSelection = true
        defer { isAddingSelection = false }

        let chosen = subfolders.filter { selection.contains($0.id) }
        var empties: [String] = []
        var collected: [(folder: DriveItem, files: [DriveItem])] = []

        for folder in chosen {
            do {
                let response = try await driveService.listAudioFiles(inFolder: folder.id)
                guard !response.files.isEmpty else {
                    empties.append(folder.name)
                    continue
                }
                collected.append((folder, response.files))
                addedThisSession.insert(folder.id)
            } catch {
                empties.append(folder.name)
            }
        }

        if !collected.isEmpty {
            onAddBatch?(collected)
        }

        selection.removeAll()
        isSelecting = false
        if !empties.isEmpty {
            let names = empties.prefix(4).joined(separator: ", ")
            let more = empties.count > 4 ? ", and \(empties.count - 4) more" : ""
            skippedNotice = "No audio found in: \(names)\(more)."
        }
    }

    /// Results replace the folder listing entirely rather than filtering it —
    /// the point of searching here is to find an album buried somewhere in the
    /// drive, which filtering the current level could never surface.
    @ViewBuilder
    private var searchLayer: some View {
        if isSearching {
            LoadingIndicator(label: "Searching...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let searchError {
            ContentUnavailableView(
                "Search Failed",
                systemImage: "exclamationmark.triangle",
                description: Text(searchError)
            )
        } else if searchResults.isEmpty {
            ContentUnavailableView.search(text: trimmedQuery)
        } else {
            List {
                Section("\(searchResults.count) folder\(searchResults.count == 1 ? "" : "s")") {
                    ForEach(searchResults) { folder in
                        NavigationLink(value: folder) {
                            Label(folder.name, systemImage: "folder.fill")
                        }
                    }
                }
            }
        }
    }

    private func runSearch() async {
        guard isSearchActive else {
            searchResults = []
            searchError = nil
            isSearching = false
            return
        }
        isSearching = true
        searchError = nil

        // Debounce. `.task(id:)` restarts on every keystroke and cancels the
        // previous run, so sleeping first means only the query the user
        // actually stopped on reaches the network — a request per character is
        // slow and, on Drive, rate-limited.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }

        do {
            let response = try await driveService.searchFolders(query: trimmedQuery)
            guard !Task.isCancelled else { return }
            searchResults = response.files
        } catch {
            guard !Task.isCancelled else { return }
            searchResults = []
            searchError = error.localizedDescription
        }
        isSearching = false
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
    /// The cloud being copied *from*, chosen before this sheet opens. `nil`
    /// falls back to the active account.
    var provider: AccountProvider? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(CloudServiceRouter.self) private var cloudRouter
    @State private var selectedSource: FolderSource = .personal
    @State private var searchText = ""

    private var driveService: any CloudDriveService {
        guard let provider else { return cloudRouter.activeService }
        return cloudRouter.service(for: provider.storageSource)
    }

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

                FolderBrowserView(
                    folderId: nil,
                    folderName: selectedSource.rawValue,
                    source: selectedSource,
                    existingFolderIds: [],
                    onAdd: { folder, audioFiles in
                        onCopy(folder, audioFiles)
                        dismiss()
                    },
                    provider: provider,
                    searchQuery: searchText
                )
                .id(selectedSource)
            }
            .flatSlideNavigation()
            .navigationDestination(for: DriveItem.self) { folder in
                FolderBrowserView(
                    folderId: folder.id,
                    folderName: folder.name,
                    source: selectedSource,
                    existingFolderIds: [],
                    onAdd: { folder, audioFiles in
                        onCopy(folder, audioFiles)
                        dismiss()
                    },
                    provider: provider
                )
            }
            .searchable(text: $searchText, prompt: "Search folders")
            .navigationTitle("Copy from \(cloudRouter.activeProvider.displayName)")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDragIndicator(.visible)
    }
}
