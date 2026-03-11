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

    let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(for: Album.self, Track.self)
        } catch {
            // Schema migration failed — delete the old store and recreate
            print("ModelContainer creation failed: \(error). Resetting store.")
            let storeURL = URL.applicationSupportDirectory.appending(path: "default.store")
            try? FileManager.default.removeItem(at: storeURL)
            // Also remove WAL/SHM files
            try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("shm"))
            do {
                modelContainer = try ModelContainer(for: Album.self, Track.self)
            } catch {
                fatalError("Could not create ModelContainer after reset: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(authService)
                .environment(driveService)
                .environment(playerService)
                .environment(cacheService)
                .environment(albumArtService)
                .environment(themeService)
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
                .task {
                    driveService.authService = authService
                    cacheService.driveService = driveService
                    albumArtService.driveService = driveService
                    playerService.cacheService = cacheService
                    await authService.restorePreviousSignIn()
                }
        }
        .modelContainer(modelContainer)
    }
}
