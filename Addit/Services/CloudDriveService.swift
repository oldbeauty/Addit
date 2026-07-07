import Foundation

/// Provider-neutral surface for a remote drive backend. `GoogleDriveService`
/// and `OneDriveService` both conform; views route through
/// `CloudServiceRouter` so an album's `storageSource` decides which
/// implementation handles it.
///
/// The DTOs (`DriveItem`, `DrivePermission`, …) are the original Google
/// Drive shapes, reused as the neutral interchange types — `OneDriveService`
/// maps Microsoft Graph responses into them (including synthesizing the
/// Google folder mimeType for folders, so `DriveItem.isFolder` keeps
/// working everywhere).
///
/// File/folder IDs are provider-scoped opaque strings: plain Drive fileIds
/// for Google; composite "driveId|itemId" pairs for OneDrive (Graph item
/// IDs are only unique within a drive, and shared folders live in other
/// people's drives). Callers never parse them — they only round-trip them
/// back into the same service.
protocol CloudDriveService {
    // Capability flags — UI reads these instead of hard-coding provider
    // checks, so adding a provider later doesn't mean sweeping the views.
    var supportsComments: Bool { get }
    var supportsStarred: Bool { get }
    var supportsCommenterRole: Bool { get }

    // Browsing
    func listFolders(pageToken: String?) async throws -> DriveFileListResponse
    func listStarredFolders(pageToken: String?) async throws -> DriveFileListResponse
    func listSharedFolders(pageToken: String?) async throws -> DriveFileListResponse
    func listSubfolders(inFolder folderId: String) async throws -> DriveFileListResponse
    func searchFolders(query searchText: String) async throws -> DriveFileListResponse
    func listAudioFiles(inFolder folderId: String, pageToken: String?) async throws -> DriveFileListResponse
    func listAllFilesInFolder(_ folderId: String) async throws -> DriveFileListResponse

    // Files
    func findCoverImage(inFolder folderId: String) async throws -> DriveItem?
    func upsertCoverImage(inFolder folderId: String, data: Data, fileName: String) async throws -> DriveItem
    func findFile(named fileName: String, inFolder folderId: String) async throws -> DriveItem?
    func getFileMetadata(fileId: String) async throws -> DriveItem
    func renameFile(fileId: String, newName: String) async throws -> DriveItem
    func removeFileFromFolder(fileId: String, folderId: String) async throws
    func deleteFile(fileId: String) async throws
    func copyFile(fileId: String, toFolder folderId: String) async throws -> DriveItem
    func createFolder(name: String, inParent parentId: String) async throws -> DriveItem
    func findOrCreateFolder(named name: String, inParent parentId: String) async throws -> DriveItem
    func createFile(name: String, mimeType: String, inFolder parentId: String, data: Data) async throws -> DriveItem
    func setStarred(fileId: String, starred: Bool) async throws
    func updateFileData(fileId: String, data: Data, mimeType: String) async throws
    func downloadFileData(fileId: String) async throws -> Data
    func downloadFile(fileId: String, to destination: URL) async throws

    // Permissions
    func listPermissions(fileId: String) async throws -> [DrivePermission]
    func updatePermissionRole(fileId: String, permissionId: String, role: String) async throws
    func createPermission(fileId: String, email: String, role: String, sendNotification: Bool) async throws
    func deletePermission(fileId: String, permissionId: String) async throws
    func createAnyonePermission(fileId: String, role: String) async throws

    // NOTE: comments are deliberately NOT part of this protocol. OneDrive
    // has no comments API, and per-album chat is a Google-only feature —
    // ChatView talks to the concrete GoogleDriveService directly, and the
    // chat UI is hidden for OneDrive albums via `supportsComments`.
}

enum CloudDriveError: LocalizedError {
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let what):
            return "\(what) isn't supported by this storage provider"
        }
    }
}

// Default-argument ergonomics — protocols can't declare default parameter
// values, so these overloads restore the call shapes the views already use.
extension CloudDriveService {
    func listFolders() async throws -> DriveFileListResponse {
        try await listFolders(pageToken: nil)
    }
    func listStarredFolders() async throws -> DriveFileListResponse {
        try await listStarredFolders(pageToken: nil)
    }
    func listSharedFolders() async throws -> DriveFileListResponse {
        try await listSharedFolders(pageToken: nil)
    }
    func listAudioFiles(inFolder folderId: String) async throws -> DriveFileListResponse {
        try await listAudioFiles(inFolder: folderId, pageToken: nil)
    }
    func upsertCoverImage(inFolder folderId: String, data: Data) async throws -> DriveItem {
        try await upsertCoverImage(inFolder: folderId, data: data, fileName: "cover.jpg")
    }
    func createPermission(fileId: String, email: String, role: String) async throws {
        try await createPermission(fileId: fileId, email: email, role: role, sendNotification: true)
    }
}

// MARK: - Router

/// Holds one instance of each provider client and picks the right one for
/// a given album / storage source / the active account. Injected once via
/// `.environment(...)` in `AdditApp`.
@Observable
final class CloudServiceRouter {
    @ObservationIgnored let google: GoogleDriveService
    @ObservationIgnored let oneDrive: OneDriveService
    /// Shared registry, used to resolve the active account's provider.
    @ObservationIgnored weak var accountManager: AccountManager?

    init(google: GoogleDriveService, oneDrive: OneDriveService) {
        self.google = google
        self.oneDrive = oneDrive
    }

    func service(for source: StorageSource) -> any CloudDriveService {
        switch source {
        case .googleDrive: return google
        case .oneDrive: return oneDrive
        // Local albums never make cloud calls; return Google as a harmless
        // fallback rather than crashing if a guard is missed upstream.
        case .localStorage: return google
        }
    }

    func service(for album: Album) -> any CloudDriveService {
        service(for: album.storageSource)
    }

    /// Route by file-ID shape for call paths that only have a bare id (no
    /// album context, e.g. cover-art fetch by coverFileId). OneDrive ids
    /// are composite "driveId|itemId" — the pipe can never appear in a
    /// Google Drive fileId (URL-safe base64 alphabet), so its presence is
    /// a reliable provider discriminator.
    func service(forFileId fileId: String) -> any CloudDriveService {
        fileId.contains("|") ? oneDrive : google
    }

    /// The service for the active account's provider — used by flows that
    /// aren't scoped to an existing album (browsing folders to add, creating
    /// albums, importing).
    var activeService: any CloudDriveService {
        service(for: activeProvider.storageSource)
    }

    /// Provider of the currently active account (defaults to Google when
    /// nothing is resolved yet, matching pre-OneDrive behavior).
    var activeProvider: AccountProvider {
        accountManager?.activeAccount?.provider ?? .google
    }
}
