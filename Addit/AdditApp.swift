import SwiftUI
import SwiftData
import GoogleSignIn

@main
struct AdditApp: App {
    @State private var authService: GoogleAuthService
    @State private var msAuthService: MicrosoftAuthService
    @State private var authCoordinator: CloudAuthCoordinator
    @State private var driveService: GoogleDriveService
    @State private var oneDriveService: OneDriveService
    @State private var cloudRouter: CloudServiceRouter
    @State private var playerService = AudioPlayerService()
    @State private var cacheService = AudioCacheService()
    @State private var albumArtService = AlbumArtService()
    @State private var themeService = ThemeService()
    @State private var analyzerService = AudioAnalyzerService()
    @State private var shareLinks = ShareLinkService()
    @State private var transfers = TransferService()

    init() {
        // Let a button inside a scroll view show its press state on touch-down.
        //
        // UIKit holds that state back ~0.15s by default so a scroll doesn't
        // light up every cell it passes through. A tap is usually shorter than
        // that, so `ButtonStyle`'s `isPressed` never engages for one — a *hold*
        // shows the press fine, a tap shows nothing, which is exactly the
        // asymmetry that made the library cards' imprint look broken.
        //
        // Turning the delay off doesn't cost the scroll anything: UIKit still
        // cancels the touch the moment a drag is recognised, so a scroll that
        // begins on a card releases it rather than pressing it.
        UIScrollView.appearance().delaysContentTouches = false

        // Constructed here (not as property initializers) because the
        // coordinator and router hold references to their sibling services.
        let google = GoogleAuthService()
        let microsoft = MicrosoftAuthService()
        let gDrive = GoogleDriveService()
        let oneDrive = OneDriveService()
        _authService = State(initialValue: google)
        _msAuthService = State(initialValue: microsoft)
        _authCoordinator = State(initialValue: CloudAuthCoordinator(google: google, microsoft: microsoft))
        _driveService = State(initialValue: gDrive)
        _oneDriveService = State(initialValue: oneDrive)
        let router = CloudServiceRouter(google: gDrive, oneDrive: oneDrive)
        router.accountManager = google.accountManager
        _cloudRouter = State(initialValue: router)
    }

    /// Export staging (zips, hardlinked track copies) lives in tmp and is
    /// discarded when its share sheet closes. Anything still there at launch
    /// outlived the process that owned it, so nothing can be mid-flight and
    /// nothing will ever claim it again — without this it accrues forever, and
    /// the Cache Inspector that would otherwise expose it is DEBUG-only.
    private static func sweepTemporaryDirectory() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: fm.temporaryDirectory, includingPropertiesForKeys: [.fileSizeKey], options: []
        ) else { return }
        #if DEBUG
        var reclaimed: Int64 = 0
        for url in entries {
            reclaimed += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        if !entries.isEmpty {
            print("[Cache] tmp sweep: \(entries.count) leftover item(s), ~\(reclaimed) bytes at top level")
        }
        #endif
        for url in entries {
            try? fm.removeItem(at: url)
        }
    }

    var body: some Scene {
        WindowGroup {
            AccountContainerView()
                .environment(authCoordinator)
                .environment(driveService)
                .environment(cloudRouter)
                .environment(playerService)
                .environment(cacheService)
                .environment(albumArtService)
                .environment(themeService)
                .environment(analyzerService)
                .environment(shareLinks)
                .environment(transfers)
                .onOpenURL { url in
                    // Album links and the Google OAuth callback arrive through
                    // the same door, so this has to be a branch rather than an
                    // unconditional hand-off — passing a share link to
                    // GIDSignIn silently swallows it.
                    //
                    // Universal links reach a SwiftUI scene here too, not only
                    // through `onContinueUserActivity`, so one handler covers
                    // https://hollowpoint.tv/a/… and the addit:// test scheme
                    // alike.
                    if shareLinks.handle(url) { return }
                    GIDSignIn.sharedInstance.handle(url)
                }
                .task {
                    driveService.authService = authService
                    oneDriveService.authService = msAuthService
                    cacheService.driveService = driveService
                    cacheService.cloudRouter = cloudRouter
                    albumArtService.driveService = driveService
                    albumArtService.cloudRouter = cloudRouter
                    playerService.cacheService = cacheService
                    playerService.albumArtService = albumArtService
                    analyzerService.configure(playerService: playerService)
                    Self.sweepTemporaryDirectory()
                    await authCoordinator.restorePreviousSignIn()
                }
        }
    }
}

/// Wrapper view that creates the shared ModelContainer and manages account context
struct AccountContainerView: View {
    @Environment(CloudAuthCoordinator.self) private var authService
    @Environment(ThemeService.self) private var themeService
    @Environment(AudioCacheService.self) private var cacheService
    @Environment(AlbumArtService.self) private var albumArtService
    /// Set once the user chooses "Use without an account" on the sign-in
    /// screen. Read here and in `ContentView`; `UserDefaults` is the shared
    /// channel, so the key is the contract between them.
    @AppStorage(AppStorageKey.usesLocalOnly) private var usesLocalOnly = false

    var body: some View {
        Group {
            if authService.isRestoringSession {
                // Wait for auth to resolve before creating any ModelContainer.
                //
                // This is the splash you actually see on launch — it renders
                // before `ContentView` exists at all, so ContentView's copy
                // only ever covers account switching. Both call the same view;
                // they used to be two hand-maintained VStacks, and the one down
                // there was the one that never showed.
                LoadingSplashView()
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
            } else if usesLocalOnly {
                // Local-only: no cloud account, but the user can still import
                // music from the device — so this needs the REAL store. The
                // in-memory container below would drop every local album on
                // relaunch. Deliberately no `.id()`: there's no account
                // identity to key the view on.
                ContentView()
                    .modelContainer(Self.sharedContainer)
            } else {
                // Signed out and at the sign-in screen, where nothing can be
                // created — a lightweight in-memory container is enough.
                ContentView()
                    .modelContainer(Self.signedOutContainer)
            }
        }
        // Also here, not just on `ContentView`: the restoring-session splash
        // above is drawn by *this* view, so without it the first frame of a
        // cold launch renders in the system's scheme and then flips.
        .preferredColorScheme(themeService.effectiveColorScheme)
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
            #if DEBUG
            print("Shared ModelContainer creation failed: \(error). Resetting store.")
            #endif
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
                #if DEBUG
                print("[Migration] Migrated \(legacyAlbums.count) albums from \(storeURL.lastPathComponent)")
                #endif
            } catch {
                #if DEBUG
                print("[Migration] Failed to migrate \(storeURL.lastPathComponent): \(error)")
                #endif
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
        #if DEBUG
        print("[Migration] Per-account migration complete")
        #endif
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
            #if DEBUG
            print("[Store] Removed \(albums.count) albums for account \(accountId)")
            #endif
        }
    }
}
