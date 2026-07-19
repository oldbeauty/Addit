import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

struct LibraryView: View {
    /// The enclosing NavigationStack's path (owned by ContentView) — lets
    /// library flows push an album programmatically, e.g. straight into
    /// edit mode after creating it.
    @Binding var libraryPath: [Album]
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
    /// Set just before pushing an album so the navigation destination
    /// opens it with inline edit mode armed; cleared when the library
    /// reappears. Replaces the old AlbumMetadataEditorSheet presentation.
    @State private var pendingEditAlbumId: String?

    /// Push the album with inline edit mode armed — used by the context
    /// menus' Edit and by flows that create an album and immediately hand
    /// it to the user for filling in (create album, import).
    private func openForEditing(_ album: Album) {
        pendingEditAlbumId = album.googleFolderId
        libraryPath.append(album)
    }
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
                                openForEditing(album)
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
                                    openForEditing(album)
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
        .staticTopFade()
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
                        HStack(spacing: 6) {
                            StorageSourceLogo(source: currentSource)
                            Image(systemName: "chevron.down")
                                .font(.uiCaption.weight(.semibold))
                        }
                        .foregroundStyle(.primary)
                        .fixedSize()
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                }
            }
        }
        .navigationDestination(for: Album.self) { album in
            AlbumDetailView(
                album: album,
                startInEditMode: album.googleFolderId == pendingEditAlbumId
            )
        }
        // Popping back to the library disarms any pending edit push, so a
        // later plain tap on the same album opens it normally.
        .onAppear { pendingEditAlbumId = nil }
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
                openForEditing(newAlbum)
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
        openForEditing(album)
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
