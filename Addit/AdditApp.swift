import SwiftUI
import SwiftData
import GoogleSignIn

@main
struct AdditApp: App {
    @State private var authService = GoogleAuthService()
    @State private var driveService = GoogleDriveService()
    @State private var playerService = AudioPlayerService()
    @State private var cacheService = AudioCacheService()
    @State private var albumArtService = AlbumArtService()
    @State private var themeService = ThemeService()
    @State private var analyzerService = AudioAnalyzerService()

    var body: some Scene {
        WindowGroup {
            AccountContainerView()
                .environment(authService)
                .environment(driveService)
                .environment(playerService)
                .environment(cacheService)
                .environment(albumArtService)
                .environment(themeService)
                .environment(analyzerService)
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
                .task {
                    driveService.authService = authService
                    cacheService.driveService = driveService
                    albumArtService.driveService = driveService
                    playerService.cacheService = cacheService
                    playerService.albumArtService = albumArtService
                    analyzerService.configure(playerService: playerService)
                    await authService.restorePreviousSignIn()
                }
        }
    }
}

/// Wrapper view that creates the shared ModelContainer and manages account context
struct AccountContainerView: View {
    @Environment(GoogleAuthService.self) private var authService
    @Environment(AudioCacheService.self) private var cacheService
    @Environment(AlbumArtService.self) private var albumArtService

    var body: some View {
        Group {
            if authService.isRestoringSession {
                // Wait for auth to resolve before creating any ModelContainer
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("addit")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let email = authService.userEmail {
                ContentView()
                    .modelContainer(Self.sharedContainer)
                    .id(email)
                    .onAppear {
                        let accountId = AccountManager.storageIdentifier(for: email)
                        cacheService.activeAccountId = accountId
                        albumArtService.activeAccountId = accountId
                    }
                    .onChange(of: authService.userEmail) { _, newEmail in
                        if let newEmail {
                            let accountId = AccountManager.storageIdentifier(for: newEmail)
                            cacheService.activeAccountId = accountId
                            albumArtService.activeAccountId = accountId
                        }
                    }
            } else {
                // Not signed in — use a lightweight in-memory container
                ContentView()
                    .modelContainer(Self.signedOutContainer)
            }
        }
    }

    // MARK: - Shared Container (single store for all accounts)

    static let sharedContainer: ModelContainer = {
        let storeURL = URL.applicationSupportDirectory.appending(path: "addit_shared.store")
        let config = ModelConfiguration(url: storeURL)

        do {
            let container = try ModelContainer(for: Album.self, Track.self, configurations: config)
            // Run one-time migration from legacy per-account stores
            migratePerAccountStores(into: container)
            return container
        } catch {
            print("Shared ModelContainer creation failed: \(error). Resetting store.")
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("shm"))
            do {
                let container = try ModelContainer(for: Album.self, Track.self, configurations: config)
                return container
            } catch {
                fatalError("Could not create shared ModelContainer after reset: \(error)")
            }
        }
    }()

    private static let signedOutContainer: ModelContainer = {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try! ModelContainer(for: Album.self, Track.self, configurations: config)
    }()

    // MARK: - Migration from per-account stores

    private static func migratePerAccountStores(into container: ModelContainer) {
        let migrationKey = "addit_migrated_to_shared_store"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        let fm = FileManager.default
        let appSupport = URL.applicationSupportDirectory

        // Find all legacy per-account .store files
        guard let contents = try? fm.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: nil) else {
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }

        let legacyStores = contents.filter {
            $0.pathExtension == "store" &&
            $0.lastPathComponent != "addit_shared.store" &&
            $0.lastPathComponent != "default.store"
        }

        guard !legacyStores.isEmpty else {
            // Also clean up default.store if it exists
            let defaultStore = appSupport.appending(path: "default.store")
            if fm.fileExists(atPath: defaultStore.path) {
                try? fm.removeItem(at: defaultStore)
                try? fm.removeItem(at: defaultStore.appendingPathExtension("wal"))
                try? fm.removeItem(at: defaultStore.appendingPathExtension("shm"))
            }
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }

        let sharedContext = ModelContext(container)

        for storeURL in legacyStores {
            // Derive accountId from filename: "user_at_gmail_com.store" → "user_at_gmail_com"
            let accountId = (storeURL.lastPathComponent as NSString).deletingPathExtension

            do {
                let legacyConfig = ModelConfiguration(url: storeURL)
                let legacyContainer = try ModelContainer(for: Album.self, Track.self, configurations: legacyConfig)
                let legacyContext = ModelContext(legacyContainer)

                let albumDescriptor = FetchDescriptor<Album>()
                let legacyAlbums = try legacyContext.fetch(albumDescriptor)

                for album in legacyAlbums {
                    // Create a new album in the shared store
                    let newAlbum = Album(
                        googleFolderId: album.googleFolderId,
                        name: album.name,
                        artistName: album.artistName,
                        coverFileId: album.coverFileId,
                        coverMimeType: album.coverMimeType,
                        coverUpdatedAt: album.coverUpdatedAt,
                        trackCount: album.trackCount,
                        dateAdded: album.dateAdded,
                        canEdit: album.canEdit,
                        isFolderOwner: album.isFolderOwner,
                        displayOrder: album.displayOrder,
                        storageSource: album.storageSource
                    )
                    newAlbum.cachedTracklist = album.cachedTracklist
                    newAlbum.additDataFileId = album.additDataFileId
                    newAlbum.localCoverPath = album.localCoverPath
                    newAlbum.showHiddenTracks = album.showHiddenTracks
                    newAlbum.coverModifiedTime = album.coverModifiedTime

                    // Tag Drive albums with their account; local albums get nil
                    if album.isLocal {
                        newAlbum.accountId = nil
                    } else {
                        newAlbum.accountId = accountId
                    }

                    sharedContext.insert(newAlbum)

                    // Migrate tracks
                    let folderId = album.googleFolderId
                    let trackDescriptor = FetchDescriptor<Track>(
                        predicate: #Predicate { $0.album?.googleFolderId == folderId }
                    )
                    let tracks = (try? legacyContext.fetch(trackDescriptor)) ?? []
                    for track in tracks {
                        let newTrack = Track(
                            googleFileId: track.googleFileId,
                            name: track.name,
                            album: newAlbum,
                            durationSeconds: track.durationSeconds,
                            mimeType: track.mimeType,
                            fileSize: track.fileSize,
                            trackNumber: track.trackNumber,
                            modifiedTime: track.modifiedTime,
                            localFilePath: track.localFilePath
                        )
                        newTrack.isHidden = track.isHidden
                        sharedContext.insert(newTrack)
                    }
                }

                try sharedContext.save()
                print("[Migration] Migrated \(legacyAlbums.count) albums from \(storeURL.lastPathComponent)")
            } catch {
                print("[Migration] Failed to migrate \(storeURL.lastPathComponent): \(error)")
            }

            // Clean up legacy store files
            try? fm.removeItem(at: storeURL)
            try? fm.removeItem(at: storeURL.appendingPathExtension("wal"))
            try? fm.removeItem(at: storeURL.appendingPathExtension("shm"))
        }

        // Also clean up default.store
        let defaultStore = appSupport.appending(path: "default.store")
        if fm.fileExists(atPath: defaultStore.path) {
            try? fm.removeItem(at: defaultStore)
            try? fm.removeItem(at: defaultStore.appendingPathExtension("wal"))
            try? fm.removeItem(at: defaultStore.appendingPathExtension("shm"))
        }

        UserDefaults.standard.set(true, forKey: migrationKey)
        print("[Migration] Per-account migration complete")
    }

    /// Remove stored data for a specific account (Drive albums only)
    static func removeStore(for email: String) {
        let accountId = AccountManager.storageIdentifier(for: email)
        let context = ModelContext(sharedContainer)

        // Delete all Drive albums belonging to this account
        let descriptor = FetchDescriptor<Album>(
            predicate: #Predicate { $0.accountId == accountId }
        )
        if let albums = try? context.fetch(descriptor) {
            for album in albums {
                // Cascade delete rule on Album.tracks handles track cleanup
                context.delete(album)
            }
            try? context.save()
            print("[Store] Removed \(albums.count) albums for account \(accountId)")
        }
    }
}
