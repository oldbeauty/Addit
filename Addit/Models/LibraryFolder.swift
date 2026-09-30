import Foundation
import SwiftData

/// A folder on the library grid — the Home Screen kind, not the cloud kind.
///
/// Purely an arrangement: it lives only in this app's store and never reaches
/// a provider. `Album.googleFolderId` names a *cloud* folder, which this has
/// nothing to do with; an album's membership in one of these is
/// `Album.libraryFolderID`.
///
/// Scoped to one library exactly the way albums are — `storageSource` plus
/// `accountId` — so a folder made in the Google library never turns up in
/// OneDrive's, and signing an account out takes its folders with it.
@Model
final class LibraryFolder {
    /// Stable identity, minted here rather than borrowed from
    /// `persistentModelID`: a freshly inserted model's ID is temporary and
    /// changes on its first save, which would rebuild the tile mid-animation.
    var folderID: String = UUID().uuidString
    var name: String
    /// Position among the library's top-level items — one sequence shared with
    /// the loose albums' `displayOrder`.
    var displayOrder: Int = 0
    var storageSourceRaw: String? = StorageSource.googleDrive.rawValue
    var accountId: String?
    var dateCreated: Date = Date.now

    var storageSource: StorageSource {
        get { StorageSource(rawValue: storageSourceRaw ?? "") ?? .googleDrive }
        set { storageSourceRaw = newValue.rawValue }
    }

    init(name: String, displayOrder: Int, storageSource: StorageSource, accountId: String?) {
        self.folderID = UUID().uuidString
        self.name = name
        self.displayOrder = displayOrder
        self.storageSourceRaw = storageSource.rawValue
        self.accountId = accountId
        self.dateCreated = .now
    }
}
