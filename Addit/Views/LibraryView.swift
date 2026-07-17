import SwiftUI
import SwiftData
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(CloudAuthCoordinator.self) private var authService
    @Environment(CloudServiceRouter.self) private var cloudRouter
    @Environment(AudioPlayerService.self) private var playerService
    @Environment(AlbumArtService.self) private var albumArtService
    @Environment(AudioCacheService.self) private var cacheService
    @Query(sort: \Album.displayOrder) private var albums: [Album]
    @State private var showAddAlbum = false
    @State private var showCreateAlbum = false
    @State private var showSettings = false
    @State private var metadataEditorAlbum: Album?
    @State private var isArranging = false
    @AppStorage("libraryViewMode") private var isListMode = false
    @State private var accountToSignOut: String?
    @State private var showSignOutConfirmation = false
    @State private var showClearLocalConfirmation = false
    @State private var searchText = ""
    @State private var isSearchExpanded = false
    @FocusState private var isSearchFocused: Bool
    @AppStorage("storageSource") private var storageSource: String = StorageSource.googleDrive.rawValue
    @State private var showLocalImporter = false
    @State private var isImportingLocal = false
    @State private var importProgress: (current: Int, total: Int, trackName: String) = (0, 0, "")
    @State private var showLocalDriveAudioPicker = false
    @State private var showCopyFromDrive = false

    /// The library being viewed. The stored selection IS the truth —
    /// deliberately not derived from the active account. Google Drive,
    /// OneDrive, and Local are three parallel libraries; which one you're
    /// looking at is pure UI state, and the account backing each cloud
    /// library is tracked per-provider in AccountManager.
    private var currentSource: StorageSource {
        StorageSource(rawValue: storageSource) ?? .googleDrive
    }

    /// Display name of the VIEWED cloud library, for the title menu.
    private var viewedCloudLabel: String {
        currentSource == .oneDrive ? "OneDrive" : "Google Drive"
    }

    /// Display name of the ACTIVE provider — used by the Local library's
    /// "Add/Copy from …" import labels, which browse `cloudRouter.activeService`.
    private var cloudLabel: String {
        authService.activeProvider.displayName
    }

    private var libraryIsLocal: Bool { currentSource == .localStorage }

    /// The drive client for the active account's provider.
    private var driveService: any CloudDriveService {
        cloudRouter.activeService
    }

    // MARK: - Library switching
    //
    // Flipping libraries is synchronous: both providers' sessions stay
    // live in parallel, so viewing a different cloud is just a state
    // change — no auth call, no spinner. The only async case is picking a
    // cloud you have no account for, which prompts sign-in (and snaps
    // back to Local if cancelled).

    private func selectCloudLibrary(_ provider: AccountProvider) {
        storageSource = provider.storageSource.rawValue
        if !authService.selectProvider(provider) {
            Task {
                await authService.addAccount(provider: provider)
                if authService.accountManager.activeEmail(for: provider) == nil {
                    // Sign-in cancelled — show a library that can render.
                    storageSource = StorageSource.localStorage.rawValue
                }
            }
        }
    }

    private func selectLocalLibrary() {
        storageSource = StorageSource.localStorage.rawValue
    }

    /// Switch to a specific account (from the account switcher) and show
    /// its provider's library.
    private func selectAccount(_ account: Account) {
        storageSource = account.provider.storageSource.rawValue
        Task { await authService.switchAccount(to: account.email) }
    }

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    /// Account whose albums the viewed library shows — resolved from the
    /// VIEWED library's provider (not the global active account), so the
    /// album list is correct the instant a library flip happens.
    private var activeAccountId: String? {
        guard let provider = currentSource.provider,
              let email = authService.accountManager.activeEmail(for: provider) else { return nil }
        return AccountManager.storageIdentifier(for: email)
    }

    private var sourceAlbums: [Album] {
        if currentSource == .localStorage {
            // Local Library: show all local albums regardless of account
            return albums.filter { $0.storageSource == .localStorage }
        } else {
            // Cloud: show only albums of the active account's provider that
            // belong to the active account
            let accountId = activeAccountId
            return albums.filter { $0.storageSource == currentSource && $0.accountId == accountId }
        }
    }

    private var filteredAlbums: [Album] {
        let source = sourceAlbums
        if searchText.isEmpty { return source }
        let query = searchText.lowercased()
        return source.filter {
            $0.name.lowercased().contains(query) ||
            ($0.artistName?.lowercased().contains(query) ?? false)
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search albums", text: $searchText)
                .focused($isSearchFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    var body: some View {
        Group {
            if !searchText.isEmpty && filteredAlbums.isEmpty {
                VStack(spacing: 0) {
                    if isSearchExpanded { searchBar }
                    ContentUnavailableView.search(text: searchText)
                }
            } else if sourceAlbums.isEmpty {
                ScrollView {
                    ContentUnavailableView(
                        "No Albums Yet",
                        systemImage: "music.note.list",
                        description: Text(currentSource.isCloud
                            ? "Tap + to add folders from \(viewedCloudLabel)"
                            : "Tap + to import audio from your iPhone")
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
                                    .font(.uiBody.weight(.semibold))
                                    .fadingTruncation()
                                Text(album.artistName ?? "Unknown Artist")
                                    .font(.uiCaption)
                                    .foregroundStyle(.secondary)
                                    .fadingTruncation()
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
            } else if isListMode {
                List {
                    ForEach(filteredAlbums) { album in
                        NavigationLink(value: album) {
                            HStack(spacing: 12) {
                                AlbumArtworkThumbnail(album: album, size: 48)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.name)
                                        .font(.uiBody.bold())
                                        .fadingTruncation()
                                    Text(album.artistName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? album.artistName! : "Unknown Artist")
                                        .font(.uiCaption)
                                        .foregroundStyle(.secondary)
                                        .fadingTruncation()
                                }
                            }
                        }
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
                                removeAlbum(album)
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .safeAreaInset(edge: .top) {
                    if isSearchExpanded { searchBar }
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        if isSearchExpanded { searchBar }
                        LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filteredAlbums) { album in
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
        }
        .appBackground()
        .navigationTitle(isArranging ? "Arrange Library" : "")
        .onAppear {
            // Self-heal: a cloud library whose provider has no account
            // (e.g. its last account was signed out) can't render — fall
            // back to a library that can.
            if let provider = currentSource.provider,
               authService.accountManager.activeEmail(for: provider) == nil {
                if let active = authService.activeAccount {
                    storageSource = active.provider.storageSource.rawValue
                } else {
                    storageSource = StorageSource.localStorage.rawValue
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isArranging {
                ToolbarItem(placement: .principal) {
                    Menu {
                        Button {
                            selectCloudLibrary(.google)
                        } label: {
                            if currentSource == .googleDrive {
                                Label("Google Drive", systemImage: "checkmark")
                            } else {
                                Text("Google Drive")
                            }
                        }
                        Button {
                            selectCloudLibrary(.microsoft)
                        } label: {
                            if currentSource == .oneDrive {
                                Label("OneDrive", systemImage: "checkmark")
                            } else {
                                Text("OneDrive")
                            }
                        }
                        Button {
                            selectLocalLibrary()
                        } label: {
                            if libraryIsLocal {
                                Label("Local Library", systemImage: "checkmark")
                            } else {
                                Text("Local Library")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(libraryIsLocal ? "Local Library" : viewedCloudLabel)
                                .font(.uiHeadline)
                            Image(systemName: "chevron.down")
                                .font(.uiCaption.weight(.semibold))
                        }
                        .foregroundStyle(.primary)
                        .fixedSize()
                    }
                }
            }
        }
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
                    HStack(spacing: 16) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isSearchExpanded.toggle()
                                if !isSearchExpanded {
                                    searchText = ""
                                    isSearchFocused = false
                                } else {
                                    isSearchFocused = true
                                }
                            }
                        } label: {
                            Image(systemName: isSearchExpanded ? "xmark" : "magnifyingglass")
                        }
                        Button {
                            withAnimation { isListMode.toggle() }
                        } label: {
                            Image(systemName: isListMode ? "square.grid.2x2" : "list.bullet")
                        }
                        if currentSource.isCloud {
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
                        } else {
                            Menu {
                                Menu {
                                    Button {
                                        // Create empty local album
                                        createEmptyLocalAlbum()
                                    } label: {
                                        Label("Create Empty", systemImage: "rectangle.badge.plus")
                                    }
                                    Button {
                                        showLocalImporter = true
                                    } label: {
                                        Label("Add from iPhone", systemImage: "iphone")
                                    }
                                    Button {
                                        showLocalDriveAudioPicker = true
                                    } label: {
                                        Label("Add from \(cloudLabel)", systemImage: "cloud")
                                    }
                                } label: {
                                    Label("Create New", systemImage: "plus.rectangle.on.folder")
                                }
                                Button {
                                    showCopyFromDrive = true
                                } label: {
                                    Label("Copy from \(cloudLabel)", systemImage: "folder.badge.plus")
                                }
                            } label: {
                                Image(systemName: "plus")
                            }
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        if !authService.accountManager.accounts.isEmpty {
                            // Account list — Google and Microsoft accounts
                            // share one switcher; OneDrive accounts get a
                            // provider suffix so same-name accounts stay
                            // distinguishable. A checkmark marks each
                            // account that is currently *in use* (the live
                            // account for its provider), so when you have
                            // both a Google and a Microsoft account signed
                            // in, both show a checkmark even though you're
                            // only viewing one library at a time.
                            Section {
                                ForEach(authService.accountManager.accounts) { account in
                                    Menu {
                                        // "Switch to" only makes sense for accounts
                                        // that are NOT in use. In-use accounts (the
                                        // checkmarked ones) are switched between via
                                        // the library menu, not here.
                                        if !authService.accountManager.isInUse(account) {
                                            Button {
                                                selectAccount(account)
                                            } label: {
                                                Label("Switch to", systemImage: "arrow.right.arrow.left")
                                            }
                                        }
                                        Button(role: .destructive) {
                                            accountToSignOut = account.email
                                            showSignOutConfirmation = true
                                        } label: {
                                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                                        }
                                    } label: {
                                        Label {
                                            Text(account.provider == .microsoft
                                                 ? "\(account.name) · OneDrive"
                                                 : account.name)
                                        } icon: {
                                            if authService.accountManager.isInUse(account) {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                                Menu {
                                    Button {
                                        Task { await authService.addAccount(provider: .google) }
                                    } label: {
                                        Label("Google Account", systemImage: "person.crop.circle")
                                    }
                                    Button {
                                        Task { await authService.addAccount(provider: .microsoft) }
                                    } label: {
                                        Label("Microsoft Account", systemImage: "cloud")
                                    }
                                } label: {
                                    Label("Add Account", systemImage: "plus")
                                }
                            }
                        }

                        Section {
                            Button {
                                showSettings = true
                            } label: {
                                Label("Settings", systemImage: "gearshape")
                            }
                        }

                        if currentSource == .localStorage {
                            Section {
                                Button(role: .destructive) {
                                    showClearLocalConfirmation = true
                                } label: {
                                    Label("Erase \"Local Library\" in Addit", systemImage: "trash")
                                }
                            }
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
        .sheet(isPresented: $showLocalDriveAudioPicker) {
            DriveAudioPickerView(targetFolderId: "") { files in
                Task { await createLocalAlbumFromDriveFiles(files) }
            }
        }
        .sheet(isPresented: $showCopyFromDrive) {
            CopyAlbumFromDriveView { folder, audioFiles in
                Task { await copyDriveAlbumToLocal(folder: folder, audioFiles: audioFiles) }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(item: $metadataEditorAlbum) { album in
            AlbumMetadataEditorSheet(album: album)
        }
        .fileImporter(
            isPresented: $showLocalImporter,
            allowedContentTypes: [.audio, .folder],
            allowsMultipleSelection: true
        ) { result in
            Task { await handleLocalImport(result) }
        }
        .overlay {
            if isImportingLocal {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .overlay {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)

                            if importProgress.total > 0 {
                                Text("Track \(importProgress.current) of \(importProgress.total)")
                                    .font(.uiSubheadline.bold())

                                Text(importProgress.trackName)
                                    .font(.uiCaption)
                                    .foregroundStyle(.secondary)
                                    .fadingTruncation()

                                // Progress bar
                                GeometryReader { geo in
                                    let fraction = CGFloat(importProgress.current) / CGFloat(max(importProgress.total, 1))
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(Color.primary.opacity(0.1))
                                        Capsule()
                                            .fill(Color.primary.opacity(0.5))
                                            .frame(width: geo.size.width * fraction)
                                            .animation(.easeInOut(duration: 0.3), value: importProgress.current)
                                    }
                                }
                                .frame(height: 4)
                                .padding(.horizontal, 4)
                            } else {
                                Text("Importing...")
                                    .font(.uiSubheadline)
                            }
                        }
                        .frame(width: 220)
                        .padding(24)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
            }
        }
        .alert("Are you sure?", isPresented: $showSignOutConfirmation) {
            Button("Sign Out", role: .destructive) {
                if let email = accountToSignOut {
                    signOutAndClearData(for: email)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your library and downloads for this account will be erased, but no cloud data will be modified.")
        }
        .alert("Erase \"Local Library\"?", isPresented: $showClearLocalConfirmation) {
            Button("Erase", role: .destructive) {
                clearLocalStorage()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All imported albums and audio files will be permanently deleted.\n\nThis applies only to your \"Local Library\" within Addit, and will not modify any data outside of Addit, or data in your other Addit libraries.")
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

    private func clearLocalStorage() {
        // Stop playback if current track is local
        if playerService.currentTrack?.isLocal == true {
            playerService.pause()
            playerService.queue.removeAll()
            playerService.userQueue.removeAll()
            playerService.currentIndex = 0
        }

        // Delete all local albums from SwiftData
        let localAlbums = albums.filter { $0.isLocal }
        for album in localAlbums {
            modelContext.delete(album)
        }
        try? modelContext.save()

        // Wipe the entire LocalAlbums directory
        let localBase = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalAlbums", isDirectory: true)
        try? FileManager.default.removeItem(at: localBase)
    }

    private func removeAlbum(_ album: Album) {
        // Clean up local files if it's a local album
        if album.isLocal {
            let albumId = album.googleFolderId.replacingOccurrences(of: "local_", with: "")
            let localBase = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LocalAlbums", isDirectory: true)
                .appendingPathComponent(albumId, isDirectory: true)
            try? FileManager.default.removeItem(at: localBase)
        }
        // Cascade delete rule on Album.tracks handles track cleanup
        modelContext.delete(album)
        do {
            try modelContext.save()
            #if DEBUG
            print("[Library] Album deleted successfully: \(album.name)")
            #endif
        } catch {
            #if DEBUG
            print("[Library] Failed to save after delete: \(error)")
            #endif
        }
    }

    private func handleLocalImport(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result, !urls.isEmpty else { return }

        await MainActor.run { isImportingLocal = true }

        let fm = FileManager.default
        let localBase = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalAlbums", isDirectory: true)
        try? fm.createDirectory(at: localBase, withIntermediateDirectories: true)

        let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "aiff", "flac", "alac", "ogg", "wma", "caf"]

        // Start accessing all security-scoped resources upfront
        var accessedURLs: [URL] = []
        for url in urls {
            if url.startAccessingSecurityScopedResource() {
                accessedURLs.append(url)
            }
        }
        defer {
            for url in accessedURLs {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // Collect audio files — if a folder was selected, scan it; otherwise use files directly
        var audioFilesByAlbum: [(albumName: String, files: [URL])] = []

        for url in accessedURLs {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)

            if isDir.boolValue {
                // Folder selected — treat as one album
                let folderName = url.lastPathComponent
                let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                let audioFiles = contents.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                if !audioFiles.isEmpty {
                    audioFilesByAlbum.append((albumName: folderName, files: audioFiles))
                }
            } else if audioExtensions.contains(url.pathExtension.lowercased()) {
                // Individual files — group into one album
                audioFilesByAlbum.append((albumName: url.deletingPathExtension().lastPathComponent, files: [url]))
            }
        }

        // Merge individual files selected together into one album if multiple
        let singleFiles = audioFilesByAlbum.filter { $0.files.count == 1 && !accessedURLs.contains(where: { u in
            var isDir: ObjCBool = false
            fm.fileExists(atPath: u.path, isDirectory: &isDir)
            return isDir.boolValue
        })}
        if singleFiles.count > 1 {
            let merged = singleFiles.flatMap { $0.files }
            audioFilesByAlbum.removeAll { $0.files.count == 1 }
            let existingCount = albums.filter { $0.isLocal }.count
            audioFilesByAlbum.append((albumName: "Imported Album \(existingCount + 1)", files: merged))
        }

        var createdAlbums: [Album] = []
        for (albumName, files) in audioFilesByAlbum {
            let albumId = UUID().uuidString
            let albumDir = localBase.appendingPathComponent(albumId, isDirectory: true)
            try? fm.createDirectory(at: albumDir, withIntermediateDirectories: true)

            let album = Album(
                googleFolderId: "local_\(albumId)",
                name: albumName,
                trackCount: files.count,
                dateAdded: .now,
                canEdit: true,
                isFolderOwner: true,
                displayOrder: (albums.map(\.displayOrder).max() ?? 0) + 1,
                storageSource: .localStorage
            )
            modelContext.insert(album)
            createdAlbums.append(album)

            for (index, fileURL) in files.enumerated() {
                let fileName = fileURL.lastPathComponent
                await MainActor.run {
                    importProgress = (current: index + 1, total: files.count, trackName: fileName)
                }
                let destURL = albumDir.appendingPathComponent(fileName)

                // Copy file to app's local storage (read/write to avoid sandbox restrictions)
                if !fm.fileExists(atPath: destURL.path) {
                    if let data = try? Data(contentsOf: fileURL) {
                        try? data.write(to: destURL)
                    }
                }

                let fileSize = (try? fm.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0
                let mimeType = mimeTypeForExtension(destURL.pathExtension)

                let track = Track(
                    googleFileId: "local_\(UUID().uuidString)",
                    name: fileName,
                    album: album,
                    mimeType: mimeType,
                    fileSize: fileSize,
                    trackNumber: index + 1,
                    localFilePath: "LocalAlbums/\(albumId)/\(fileName)"
                )
                modelContext.insert(track)
            }
        }

        try? modelContext.save()
        await MainActor.run { isImportingLocal = false; importProgress = (0, 0, "") }
    }

    private func createEmptyLocalAlbum() {
        let existingCount = albums.filter { $0.isLocal }.count
        let albumId = UUID().uuidString
        let fm = FileManager.default
        let albumDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalAlbums", isDirectory: true)
            .appendingPathComponent(albumId, isDirectory: true)
        try? fm.createDirectory(at: albumDir, withIntermediateDirectories: true)

        let album = Album(
            googleFolderId: "local_\(albumId)",
            name: "Imported Album \(existingCount + 1)",
            trackCount: 0,
            dateAdded: .now,
            canEdit: true,
            isFolderOwner: true,
            displayOrder: (albums.map(\.displayOrder).max() ?? 0) + 1,
            storageSource: .localStorage
        )
        modelContext.insert(album)
        try? modelContext.save()
        metadataEditorAlbum = album
    }

    private func createLocalAlbumFromDriveFiles(_ files: [DriveItem]) async {
        guard !files.isEmpty else { return }
        await MainActor.run { isImportingLocal = true }

        let fm = FileManager.default
        let existingCount = albums.filter { $0.isLocal }.count
        let albumId = UUID().uuidString
        let albumDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalAlbums", isDirectory: true)
            .appendingPathComponent(albumId, isDirectory: true)
        try? fm.createDirectory(at: albumDir, withIntermediateDirectories: true)

        let album = Album(
            googleFolderId: "local_\(albumId)",
            name: "Imported Album \(existingCount + 1)",
            trackCount: files.count,
            dateAdded: .now,
            canEdit: true,
            isFolderOwner: true,
            displayOrder: (albums.map(\.displayOrder).max() ?? 0) + 1,
            storageSource: .localStorage
        )
        modelContext.insert(album)

        for (index, file) in files.enumerated() {
            do {
                await MainActor.run {
                    importProgress = (current: index + 1, total: files.count, trackName: file.name)
                }
                let data = try await driveService.downloadFileData(fileId: file.id)
                let destURL = albumDir.appendingPathComponent(file.name)
                try data.write(to: destURL)

                let track = Track(
                    googleFileId: "local_\(UUID().uuidString)",
                    name: file.name,
                    album: album,
                    mimeType: file.mimeType,
                    fileSize: Int64(data.count),
                    trackNumber: index + 1,
                    localFilePath: "LocalAlbums/\(albumId)/\(file.name)"
                )
                modelContext.insert(track)
            } catch {
                #if DEBUG
                print("Failed to download Drive file \(file.name): \(error)")
                #endif
            }
        }

        try? modelContext.save()
        await MainActor.run { isImportingLocal = false; importProgress = (0, 0, "") }
    }

    private func copyDriveAlbumToLocal(folder: DriveItem, audioFiles: [DriveItem]) async {
        await MainActor.run { isImportingLocal = true }

        let fm = FileManager.default
        let albumId = UUID().uuidString
        let albumDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalAlbums", isDirectory: true)
            .appendingPathComponent(albumId, isDirectory: true)
        try? fm.createDirectory(at: albumDir, withIntermediateDirectories: true)

        // Fetch all audio files from the folder (handle pagination)
        var allAudioFiles: [DriveItem] = []
        var pageToken: String? = nil
        repeat {
            do {
                let response = try await driveService.listAudioFiles(inFolder: folder.id, pageToken: pageToken)
                allAudioFiles.append(contentsOf: response.files)
                pageToken = response.nextPageToken
            } catch {
                #if DEBUG
                print("[CopyFromDrive] Failed to list audio files: \(error)")
                #endif
                break
            }
        } while pageToken != nil

        #if DEBUG
        print("[CopyFromDrive] Found \(allAudioFiles.count) audio files in \(folder.name)")
        #endif

        // Download all audio files to disk first, before inserting anything into SwiftData
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
                    importProgress = (current: index + 1, total: allAudioFiles.count, trackName: file.name)
                }
                let data = try await driveService.downloadFileData(fileId: file.id)
                guard !data.isEmpty else {
                    #if DEBUG
                    print("[CopyFromDrive] Empty data for \(file.name), skipping")
                    #endif
                    continue
                }
                let destURL = albumDir.appendingPathComponent(file.name)
                try data.write(to: destURL)
                downloadedTracks.append(DownloadedTrack(
                    name: file.name,
                    mimeType: file.mimeType,
                    fileSize: Int64(data.count),
                    relativePath: "LocalAlbums/\(albumId)/\(file.name)"
                ))
            } catch {
                #if DEBUG
                print("[CopyFromDrive] Failed to download \(file.name): \(error)")
                #endif
            }
        }
        #if DEBUG
        print("[CopyFromDrive] Downloaded \(downloadedTracks.count)/\(allAudioFiles.count) tracks")
        #endif

        // Fetch metadata from .addit-data
        var albumArtist: String?
        var tracklist: [String]?
        do {
            if let additDataItem = try await driveService.findFile(named: ".addit-data", inFolder: folder.id) {
                let data = try await driveService.downloadFileData(fileId: additDataItem.id)
                let metadata = try JSONDecoder().decode(AdditMetadata.self, from: data)
                albumArtist = metadata.artist
                tracklist = metadata.tracklist
            }
        } catch {
            #if DEBUG
            print("[CopyFromDrive] Failed to fetch .addit-data: \(error)")
            #endif
        }

        // Fetch cover image
        var coverRelativePath: String?
        do {
            if let coverItem = try await driveService.findCoverImage(inFolder: folder.id) {
                let coverData = try await driveService.downloadFileData(fileId: coverItem.id)
                let coverURL = albumDir.appendingPathComponent("cover.jpg")
                try coverData.write(to: coverURL)
                coverRelativePath = "LocalAlbums/\(albumId)/cover.jpg"
            }
        } catch {
            #if DEBUG
            print("[CopyFromDrive] Failed to fetch cover: \(error)")
            #endif
        }

        // Now insert everything into SwiftData in one batch
        let album = Album(
            googleFolderId: "local_\(albumId)",
            name: folder.name,
            artistName: albumArtist,
            trackCount: downloadedTracks.count,
            dateAdded: .now,
            canEdit: true,
            isFolderOwner: true,
            displayOrder: (albums.map(\.displayOrder).max() ?? 0) + 1,
            storageSource: .localStorage
        )
        album.localCoverPath = coverRelativePath
        if let tracklist, !tracklist.isEmpty {
            album.cachedTracklist = tracklist
        }
        modelContext.insert(album)

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
                album: album,
                mimeType: dl.mimeType,
                fileSize: dl.fileSize,
                trackNumber: trackNumber,
                localFilePath: dl.relativePath
            )
            modelContext.insert(track)
        }

        try? modelContext.save()
        #if DEBUG
        print("[CopyFromDrive] Saved album with \(downloadedTracks.count) tracks")
        #endif
        await MainActor.run { isImportingLocal = false; importProgress = (0, 0, "") }
    }

    private func mimeTypeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "aac": return "audio/aac"
        case "aiff", "aif": return "audio/aiff"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        case "caf": return "audio/x-caf"
        default: return "audio/mpeg"
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

    private func signOutAndClearData(for email: String? = nil) {
        let targetEmail = email ?? authService.userEmail
        guard let targetEmail else { return }
        let isCurrentAccount = targetEmail == authService.userEmail
        let accountId = AccountManager.storageIdentifier(for: targetEmail)

        if isCurrentAccount {
            // Stop playback if signing out the active account
            playerService.pause()
            playerService.queue.removeAll()
            playerService.userQueue.removeAll()
            playerService.currentIndex = 0
        }

        // Clear this account's caches
        try? cacheService.clearCache(for: accountId)
        albumArtService.clearCache(for: accountId)

        // Remove Drive albums belonging to this account from the shared store
        AccountContainerView.removeStore(for: targetEmail)

        // Remove account and sign out
        let removedProvider = authService.accountManager.accounts
            .first(where: { $0.email == targetEmail })?.provider
        let remainingAccounts = authService.accountManager.accounts.filter { $0.email != targetEmail }
        authService.removeAccount(email: targetEmail)

        // If we signed out the current account, move to another one —
        // preferring the same provider so the viewed library survives —
        // and align the library selection with wherever we land.
        if isCurrentAccount {
            let next = remainingAccounts.first(where: { $0.provider == removedProvider })
                ?? remainingAccounts.first
            if let next {
                storageSource = next.provider.storageSource.rawValue
                Task { await authService.switchAccount(to: next.email) }
            } else {
                storageSource = StorageSource.localStorage.rawValue
            }
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
        VStack(alignment: .leading, spacing: 4) {
            AlbumArtworkThumbnail(album: album)

            VStack(alignment: .leading, spacing: 0) {
                Text(album.name)
                    .font(.uiSubheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fadingTruncation()

                Text(subtitle)
                    .font(.uiCaption)
                    .foregroundStyle(.secondary)
                    .fadingTruncation()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 36, alignment: .top)
            // Indent the text block to visually align with the cover's
            // rounded corners (its straight edge reads inset from x=0).
            // Symmetric padding also pulls the trailing fade in by the same
            // amount, keeping the right edge balanced with the left.
            .padding(.horizontal, 4)
        }
        .frame(width: 148)
    }
}

struct AlbumMetadataEditorSheet: View {
    let album: Album
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(CloudServiceRouter.self) private var cloudRouter
    @Environment(AlbumArtService.self) private var albumArtService

    /// Drive client for whichever provider hosts this album; local albums
    /// pull new cloud tracks from the active account's provider instead.
    private var driveService: any CloudDriveService {
        album.isLocal ? cloudRouter.activeService : cloudRouter.service(for: album)
    }

    /// Provider name for UI labels ("Google Drive" / "OneDrive").
    private var cloudLabel: String {
        album.isOneDrive ? "OneDrive"
            : album.isLocal ? cloudRouter.activeProvider.displayName
            : "Google Drive"
    }
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
    @State private var renameTarget: RenameTarget?
    @State private var renameText = ""

    /// What the rename popup is editing — album title, artist, or one track.
    private enum RenameTarget: Identifiable {
        case title, artist, track(Track)

        var id: String {
            switch self {
            case .title: return "title"
            case .artist: return "artist"
            case .track(let track): return "track-\(track.googleFileId)"
            }
        }
    }

    private let coverSize: CGFloat = 180

    /// Pre-computed disc numbers keyed by TracklistItem.id, so each disc-marker row
    /// can render its label without slicing `reorderedItems` inside the ForEach body
    /// (which interacts badly with `.onMove` diffing on UICollectionView).
    private var discNumbersByItemId: [String: Int] {
        var result: [String: Int] = [:]
        var counter = 0
        for item in reorderedItems {
            if case .discMarker = item {
                counter += 1
                result[item.id] = counter
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                // Cover art section
                Section {
                    HStack {
                        Spacer()
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
                                                .font(.ui(48))
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
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    // Title and artist
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            beginRename(.title)
                        } label: {
                            HStack(spacing: 6) {
                                Text(editedTitle)
                                    .font(.uiTitle2.bold())
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)

                                Image(systemName: "pencil")
                                    .font(.uiCaption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)

                        Button {
                            beginRename(.artist)
                        } label: {
                            HStack(spacing: 6) {
                                Text(editedArtist.isEmpty ? "Artist" : editedArtist)
                                    .font(.uiSubheadline)
                                    .foregroundStyle(editedArtist.isEmpty ? .tertiary : .secondary)
                                    .multilineTextAlignment(.leading)

                                Image(systemName: "pencil")
                                    .font(.uiCaption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.uiCaption)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                }

                // Tracklist section
                Section {
                    if !reorderedItems.isEmpty {
                        ForEach(reorderedItems) { item in
                            switch item {
                            case .track(let track):
                                HStack(spacing: 6) {
                                    if album.canEdit {
                                        Button {
                                            trackToDelete = track
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.uiCaption)
                                                .foregroundStyle(.red)
                                        }
                                        .buttonStyle(.plain)
                                    }

                                    Button {
                                        beginRename(.track(track))
                                    } label: {
                                        HStack(spacing: 6) {
                                            Text(editedTrackNames[track.googleFileId] ?? track.displayName)
                                                .font(.uiBody.weight(.medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)

                                            Image(systemName: "pencil")
                                                .font(.uiCaption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .buttonStyle(.plain)

                                    Spacer(minLength: 0)
                                }
                            case .discMarker:
                                let discNumber = discNumbersByItemId[item.id] ?? 1
                                HStack {
                                    Text("Disc \(discNumber)")
                                        .font(.uiSubheadline.bold())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button {
                                        let targetId = item.id
                                        withAnimation {
                                            reorderedItems.removeAll { $0.id == targetId }
                                        }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.tertiary)
                                            .font(.uiBody)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .onMove { source, destination in
                            withAnimation {
                                reorderedItems.move(fromOffsets: source, toOffset: destination)
                            }
                        }
                    }
                } header: {
                    HStack {
                        if !reorderedItems.isEmpty {
                            Button {
                                addDiscMarker()
                            } label: {
                                Label("Add disc marker", systemImage: "plus")
                                    .font(.uiSubheadline)
                            }
                            .disabled(reorderedItems.filter(\.isDiscMarker).count >= 100)
                        }

                        Spacer()

                        if album.canEdit {
                            Menu {
                                Button {
                                    showAddTrackSheet = true
                                } label: {
                                    Label("From \(cloudLabel)", systemImage: "cloud")
                                }
                                Button {
                                    showDocumentPicker = true
                                } label: {
                                    Label("From iPhone", systemImage: "iphone")
                                }
                            } label: {
                                Label("Add tracks", systemImage: "plus.circle")
                                    .font(.uiSubheadline)
                            }
                            .disabled(isUploadingTracks)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.editMode, .constant(.active))
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
                            Task { await saveMetadata() }
                        }
                        .disabled(editedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .selectAllInTextFields(while: renameTarget != nil)
            .alert(renameAlertTitle, isPresented: renameAlertBinding) {
                TextField(renamePlaceholder, text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") { applyRename() }
            }
            .task {
                editedTitle = album.name
                editedArtist = album.artistName ?? ""
                if album.isLocal {
                    if let path = album.resolvedLocalCoverPath {
                        coverImage = UIImage(contentsOfFile: path)
                    }
                } else {
                    let resolution = await albumArtService.resolveAlbumArt(for: album)
                    coverImage = resolution.image
                    await resolveFolderOwnership()
                    await resolveAdditDataFileId()
                }
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
                Text("This will delete \"\(trackToDelete?.name ?? "")\" from \"\(album.name)\" in \(cloudLabel).")
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

    // MARK: Rename popup

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    private var renameAlertTitle: String {
        switch renameTarget {
        case .artist: return "Edit Artist"
        case .track: return "Rename Track"
        default: return "Rename Album"
        }
    }

    private var renamePlaceholder: String {
        switch renameTarget {
        case .artist: return "Artist"
        case .track: return "Track name"
        default: return "Album title"
        }
    }

    private func beginRename(_ target: RenameTarget) {
        switch target {
        case .title: renameText = editedTitle
        case .artist: renameText = editedArtist
        case .track(let track): renameText = editedTrackNames[track.googleFileId] ?? track.displayName
        }
        renameTarget = target
    }

    /// Applies the popup's text. Empty input keeps the old title/track name
    /// (both are required); an empty artist clears the field.
    private func applyRename() {
        guard let target = renameTarget else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch target {
        case .title:
            if !trimmed.isEmpty { editedTitle = trimmed }
        case .artist:
            editedArtist = trimmed
        case .track(let track):
            if !trimmed.isEmpty { editedTrackNames[track.googleFileId] = trimmed }
        }
    }

    private func saveMetadata() async {
        let trimmedTitle = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        isSaving = true
        defer { isSaving = false }

        let trimmedArtist = editedArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        let newArtist: String? = trimmedArtist.isEmpty ? nil : trimmedArtist

        if album.isLocal {
            // Local album — just update SwiftData, rename files on disk
            album.name = trimmedTitle
            album.artistName = newArtist

            // Update track names, numbers, and persist tracklist with disc markers
            var tracklist: [String] = []
            var trackIndex = 0
            var discNumber = 0
            for item in reorderedItems {
                switch item {
                case .track(let track):
                    if let newName = editedTrackNames[track.googleFileId], newName != track.displayName {
                        // Rename file on disk
                        if let oldURL = track.localFileURL {
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
            dismiss()
            return
        }

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
            _ = try await driveService.renameFile(fileId: album.googleFolderId, newName: trimmedTitle)

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

        if album.isLocal {
            // Save cover locally
            guard let jpegData = croppedImage.jpegData(compressionQuality: 0.9) else { return }
            let albumId = album.googleFolderId.replacingOccurrences(of: "local_", with: "")
            let localBase = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LocalAlbums", isDirectory: true)
                .appendingPathComponent(albumId, isDirectory: true)
            try? FileManager.default.createDirectory(at: localBase, withIntermediateDirectories: true)
            let coverURL = localBase.appendingPathComponent("cover.jpg")
            try? jpegData.write(to: coverURL)
            album.localCoverPath = "LocalAlbums/\(albumId)/cover.jpg"
            coverImage = croppedImage
            try? modelContext.save()
            return
        }

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
                album.additDataFileId = item.id
                additDataOwnedByMe = true
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
        if track.isLocal {
            // Delete local file from disk
            if let url = track.localFileURL {
                try? FileManager.default.removeItem(at: url)
            }
            reorderedItems.removeAll { $0.id == track.googleFileId }
            editedTrackNames.removeValue(forKey: track.googleFileId)
            modelContext.delete(track)
            album.trackCount = max(0, album.trackCount - 1)
            try? modelContext.save()
        } else {
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
                        trackNumber: reorderedItems.compactMap(\.asTrack).count + 1,
                        localFilePath: "LocalAlbums/\(albumId)/\(fileName)"
                    )
                    modelContext.insert(track)
                    reorderedItems.append(.track(track))
                    album.trackCount += 1
                } else {
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
                        trackNumber: reorderedItems.compactMap(\.asTrack).count + 1,
                        modifiedTime: driveItem.modifiedTime
                    )
                    modelContext.insert(track)
                    reorderedItems.append(.track(track))
                    album.trackCount += 1
                }
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
                if album.isLocal {
                    // Download from Drive and save locally
                    let data = try await driveService.downloadFileData(fileId: file.id)
                    let albumId = album.googleFolderId.replacingOccurrences(of: "local_", with: "")
                    let fm = FileManager.default
                    let albumDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("LocalAlbums", isDirectory: true)
                        .appendingPathComponent(albumId, isDirectory: true)
                    try? fm.createDirectory(at: albumDir, withIntermediateDirectories: true)

                    let destURL = albumDir.appendingPathComponent(file.name)
                    try data.write(to: destURL)

                    let fileSize = Int64(data.count)
                    let mimeType = file.mimeType

                    let track = Track(
                        googleFileId: "local_\(UUID().uuidString)",
                        name: file.name,
                        album: album,
                        mimeType: mimeType,
                        fileSize: fileSize,
                        trackNumber: reorderedItems.compactMap(\.asTrack).count + 1,
                        localFilePath: "LocalAlbums/\(albumId)/\(file.name)"
                    )
                    modelContext.insert(track)
                    reorderedItems.append(.track(track))
                    album.trackCount += 1
                } else {
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
                        trackNumber: reorderedItems.compactMap(\.asTrack).count + 1,
                        modifiedTime: copiedItem.modifiedTime
                    )
                    modelContext.insert(track)
                    reorderedItems.append(.track(track))
                    album.trackCount += 1
                }
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

        // Local albums: rebuild from cachedTracklist (which holds disc markers inline)
        if album.isLocal {
            if !album.cachedTracklist.isEmpty {
                reorderedItems = buildItems(from: album.cachedTracklist, tracks: sortedTracks)
            } else {
                reorderedItems = sortedTracks.map { .track($0) }
            }
            return
        }

        // Drive albums: try to load existing .addit-data for disc markers
        if let fileId = additDataFileId {
            do {
                let data = try await driveService.downloadFileData(fileId: fileId)
                if let metadata = try? JSONDecoder().decode(AdditMetadata.self, from: data),
                   let tracklist = metadata.tracklist {
                    reorderedItems = buildItems(from: tracklist, tracks: sortedTracks)
                    return
                }
            } catch {
                // Fall through to default
            }
        }

        // Default: just tracks, no disc markers
        reorderedItems = sortedTracks.map { .track($0) }
    }

    /// Builds an ordered TracklistItem array from a saved tracklist (with disc markers)
    /// and the album's known tracks. Tracks not present in the tracklist are appended.
    private func buildItems(from tracklist: [String], tracks: [Track]) -> [TracklistItem] {
        var items: [TracklistItem] = []
        var matchedIds = Set<String>()

        for entry in tracklist {
            if entry.hasPrefix(AdditMetadata.discMarkerPrefix) {
                let label = String(entry.dropFirst(AdditMetadata.discMarkerPrefix.count))
                items.append(.discMarker(id: UUID(), label: label))
            } else if let track = tracks.first(where: { $0.name == entry && !matchedIds.contains($0.googleFileId) }) {
                items.append(.track(track))
                matchedIds.insert(track.googleFileId)
            }
        }

        // Append any tracks not in the tracklist
        for track in tracks where !matchedIds.contains(track.googleFileId) {
            items.append(.track(track))
        }

        return items
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

            _ = try await driveService.renameFile(fileId: track.googleFileId, newName: newFileName)
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
        return "\(album.coverArtTaskID)-\(refreshMarker)-\(album.localCoverPath ?? "")"
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
                            .font(.ui(size * 0.27))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            // Glass edge: hairline + gyro specular so covers with dark
            // borders separate from the dark background (Phosphor kit).
            .overlay(GlassRim(cornerRadius: 12))
            .onAppear {
                if album.isLocal {
                    if image == nil, let coverPath = album.resolvedLocalCoverPath {
                        image = UIImage(contentsOfFile: coverPath)
                    }
                } else {
                    // Show cached image instantly — no async, no file I/O
                    if image == nil, let coverFileId = album.coverFileId {
                        image = albumArtService.cachedImage(for: coverFileId)
                    }
                }
            }
            .task(id: artworkTaskID) {
                if album.isLocal {
                    if let coverPath = album.resolvedLocalCoverPath {
                        image = UIImage(contentsOfFile: coverPath)
                    }
                    return
                }
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
