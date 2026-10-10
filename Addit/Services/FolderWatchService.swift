import Foundation

/// The account whose folders are tracked: the viewed cloud library's. Its
/// tracking is kept in one file, named by `key`.
struct WatchAccount: Equatable {
    /// `AccountManager.storageIdentifier(for:)`, as `Album.accountId` holds it.
    let key: String
    let email: String
    let source: StorageSource
}

/// Folder tracking: which folders to compare, when to compare them, and
/// where what's found is kept. The model, and the rules it keeps, are in
/// `FolderWatch.swift`; why it works this way is in `skill://folder-tracking`.
///
/// A folder is tracked by listing it and comparing the listing with what it
/// held before (`FolderWatchBook.record`). Nothing cheaper says that
/// something arrived: Drive doesn't touch a folder's modified time when a
/// file lands in it, and `.addit-data` only changes when somebody opens the
/// album in Addit, never when they add to it in Drive itself. So a check lists
/// every tracked folder, as many to a request as each drive allows
/// (`watchBatchSize`): on its own at launch and on coming back to the
/// foreground, at most every `checkInterval`, and whenever the window asks.
///
/// One account at a time, the one on screen. A check belongs to the account it
/// started for, and one that's switched away from mid-check is abandoned
/// without writing anything. That loses nothing: a snapshot that wasn't
/// advanced reports the same news next time.
@Observable
final class FolderWatchService {
    private(set) var account: WatchAccount?
    /// `account`'s tracking, as loaded from its file and changed since.
    private(set) var book = FolderWatchBook()
    /// A check is under way.
    private(set) var isChecking = false
    /// Why the last check stopped short, as a sentence; `nil` once one gets
    /// all the way through.
    private(set) var failure: String?
    /// Folders just pinned whose first listing is still under way.
    private(set) var baselining: Set<String> = []

    var unreadCount: Int { book.unreadCount }

    /// A check runs by itself at launch and on coming back to the foreground,
    /// but no more often than this.
    static let checkInterval: TimeInterval = 15 * 60
    /// How soon after a failed check another may start by itself.
    static let retryInterval: TimeInterval = 2 * 60
    /// Opening the window checks if the last check is older than this.
    static let windowInterval: TimeInterval = 60

    @ObservationIgnored private let router: CloudServiceRouter
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    /// Bumped by every check and every change of account. A check that ends
    /// under an older value has been replaced, and must leave the state of
    /// whatever replaced it alone.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var baselineTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastAttempt: Date?
    /// The library's album folders as of the last check. Unpinning one of
    /// these keeps its snapshot, since it's still tracked as an album.
    @ObservationIgnored private var libraryFolderIds: Set<String> = []
    /// The account files are read and written here, one at a time and in
    /// order, so a write can't land after a newer one and a read waits for
    /// the writes before it.
    @ObservationIgnored private let disk = DispatchQueue(label: "tv.hollowpoint.addit.folder-watch", qos: .utility)

    init(router: CloudServiceRouter) {
        self.router = router
    }

    // MARK: - Account

    /// Shows `account`'s tracking, read from its file. Whatever was running
    /// for the previous account is abandoned.
    func activate(_ account: WatchAccount?) {
        guard account != self.account else { return }
        generation &+= 1
        checkTask?.cancel()
        checkTask = nil
        isChecking = false
        for task in baselineTasks.values { task.cancel() }
        baselineTasks = [:]
        baselining = []
        failure = nil
        lastAttempt = nil
        libraryFolderIds = []
        self.account = account
        book = account.map { load(key: $0.key) } ?? FolderWatchBook()
    }

    /// Deletes an account's tracking: it's being signed out, and its library
    /// and downloads go with it.
    func forget(accountKey key: String) {
        if account?.key == key { activate(nil) }
        let url = Self.fileURL(key: key)
        disk.async { @Sendable in
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Checks

    /// Starts a check if one is due: none has got through in `maxAge`, and
    /// none has failed in the last `retryInterval`. `library` is the
    /// library's albums, read by the caller just now; a check tracks the
    /// library as it was when it started.
    func checkIfDue(library: [WatchTarget], maxAge: TimeInterval = FolderWatchService.checkInterval) {
        guard account != nil, checkTask == nil else { return }
        let now = Date()
        if let lastChecked = book.lastChecked, now.timeIntervalSince(lastChecked) < maxAge { return }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.retryInterval { return }
        startCheck(library: library)
    }

    /// Checks now, for pull to refresh. Joins a check that's under way
    /// rather than starting a second.
    func checkNow(library: [WatchTarget]) async {
        let task = checkTask ?? startCheck(library: library)
        await task?.value
    }

    @discardableResult
    private func startCheck(library: [WatchTarget]) -> Task<Void, Never>? {
        guard let account else { return nil }
        generation &+= 1
        let generation = self.generation
        isChecking = true
        lastAttempt = .now
        let task = Task {
            await check(library: library, for: account, generation: generation)
            guard self.generation == generation else { return }
            isChecking = false
            checkTask = nil
        }
        checkTask = task
        return task
    }

    private func check(library: [WatchTarget], for account: WatchAccount, generation: Int) async {
        let drive = router.service(for: account.source)
        let started = Date()

        // Everything tracked, once each. A pinned folder goes by its own
        // name, which is what the user picked it by.
        var targets: [String: WatchTarget] = [:]
        for album in library { targets[album.folderId] = album }
        for pin in book.pinned { targets[pin.id] = WatchTarget(folderId: pin.id, name: pin.name) }
        libraryFolderIds = Set(library.map(\.folderId))

        func stillWanted() -> Bool {
            self.generation == generation && isCurrent(account)
        }

        #if DEBUG
        print("[Watch] check \(account.email): \(targets.count) folders, \(book.pinned.count) pinned")
        #endif

        do {
            // Are the pinned folders still there, and still called what they
            // were? One that's gone keeps its snapshot and isn't listed, so
            // it can't be taken as having emptied.
            var gone: Set<String> = []
            for pin in book.pinned {
                do {
                    let folder = try await drive.getFileMetadata(fileId: pin.id)
                    guard stillWanted() else { return }
                    // Deleted in Drive is trashed, which still answers here.
                    if folder.trashed == true {
                        updatePin(pin.id) { $0.isMissing = true }
                        gone.insert(pin.id)
                        continue
                    }
                    updatePin(pin.id) {
                        $0.name = folder.name
                        $0.isMissing = false
                    }
                    targets[pin.id] = WatchTarget(folderId: pin.id, name: folder.name)
                } catch where Self.saysFolderIsGone(error) {
                    guard stillWanted() else { return }
                    updatePin(pin.id) { $0.isMissing = true }
                    gone.insert(pin.id)
                }
            }

            // Every tracked folder's contents, a batch at a time, each batch
            // recorded as it lands: a check the network cuts short keeps what
            // it got. Sorted, so a library's batches are the same check to
            // check.
            var queue = ListingQueue(
                targets.keys.filter { !gone.contains($0) }.sorted(),
                batchSize: drive.watchBatchSize
            )
            while let batch = queue.next() {
                let listing: [String: [FolderChild]]
                do {
                    listing = try await drive.listWatchedChildren(ofFolders: batch)
                } catch FolderListingError.unlistable {
                    queue.reject(batch)
                    continue
                }
                guard stillWanted() else { return }
                record(listing, targets: targets)
            }

            guard stillWanted() else { return }
            let now = Date()
            book.lastChecked = now
            book.pruneSnapshots(tracking: Set(targets.keys), now: now)
            failure = nil
            save()
            #if DEBUG
            let unlistable = queue.unlistable.isEmpty ? "" : ", \(queue.unlistable.count) unlistable"
            print("[Watch] checked in \(String(format: "%.1f", now.timeIntervalSince(started)))s\(unlistable)")
            #endif
        } catch {
            // Cancelled, or another account on screen now: say nothing.
            guard stillWanted() else { return }
            failure = Self.describe(error, on: account.source)
            save()
            #if DEBUG
            print("[Watch] check stopped: \(error)")
            #endif
        }
    }

    /// Files one batch's listings and the news in them. Folders that stopped
    /// being tracked while the check ran are left out, so an unpinned folder
    /// doesn't get its snapshot back.
    private func record(_ listing: [String: [FolderChild]], targets: [String: WatchTarget]) {
        let now = Date()
        var news: [FolderWatchEvent] = []
        let byName = listing.sorted { (targets[$0.key]?.name ?? "") < (targets[$1.key]?.name ?? "") }
        for (folderId, children) in byName {
            guard let target = targets[folderId], isTracked(folderId) else { continue }
            news += book.record(children, in: target, at: now)
        }
        // A new album matters more than a new song: folders first.
        book.add(news.filter { $0.kind == .folder } + news.filter { $0.kind == .track })
        #if DEBUG
        for event in news { print("[Watch] \(event.headline)") }
        #endif
    }

    private func isTracked(_ folderId: String) -> Bool {
        libraryFolderIds.contains(folderId) || book.pinned.contains { $0.id == folderId }
    }

    /// `account` is still the one on screen, and still the one its drive
    /// client is signed in as. A second Google account switched to mid-check
    /// would otherwise list the first one's folders with its own token, and
    /// see none of them.
    private func isCurrent(_ account: WatchAccount) -> Bool {
        guard !Task.isCancelled, self.account == account,
              let provider = account.source.provider else { return false }
        return router.accountManager?.activeEmail(for: provider) == account.email
    }

    /// The drive says a folder isn't there for this account any more:
    /// deleted, or no longer shared. Read the way the playback alert reads a
    /// failed download, so the two can't disagree about what an error means.
    private static func saysFolderIsGone(_ error: Error) -> Bool {
        switch PlaybackFailure.Reason(downloadError: error, suspended: false) {
        case .removedFromDrive, .noAccess: true
        default: false
        }
    }

    /// What stopped a check, in a sentence for the top of the window.
    private static func describe(_ error: Error, on source: StorageSource) -> String {
        let drive = source == .oneDrive ? "OneDrive" : "Google Drive"
        return switch PlaybackFailure.Reason(downloadError: error, suspended: false) {
        case .offline, .interruptedInBackground:
            "Couldn't reach \(drive). Check your connection, then pull down to try again."
        case .signedOut:
            "Addit's sign-in to \(drive) has lapsed. Sign in again from the account menu."
        case .driveTrouble, .noAccess, .removedFromDrive:
            "\(drive) didn't answer just now. Pull down to try again."
        default:
            error.localizedDescription
        }
    }

    // MARK: - Pinned folders

    /// Starts tracking `folder`, and lists it straight away for its baseline,
    /// so that anything arriving from now on is news.
    func track(_ folder: DriveItem) {
        guard let account, book.pin(folder.id, name: folder.name, at: .now) else { return }
        save()
        listForBaseline(WatchTarget(folderId: folder.id, name: folder.name), for: account)
    }

    func untrack(_ folderId: String) {
        baselineTasks[folderId]?.cancel()
        baselineTasks[folderId] = nil
        baselining.remove(folderId)
        book.unpin(folderId, keepingSnapshot: libraryFolderIds.contains(folderId))
        save()
    }

    /// A newly pinned folder's first listing. If it fails (offline, say), the
    /// folder waits unlisted, and the next check takes its baseline.
    private func listForBaseline(_ target: WatchTarget, for account: WatchAccount) {
        let drive = router.service(for: account.source)
        baselineTasks[target.folderId]?.cancel()
        baselining.insert(target.folderId)
        baselineTasks[target.folderId] = Task {
            let listing = try? await drive.listWatchedChildren(ofFolders: [target.folderId])
            guard isCurrent(account) else { return }
            baselining.remove(target.folderId)
            baselineTasks[target.folderId] = nil
            guard let children = listing?[target.folderId],
                  book.pinned.contains(where: { $0.id == target.folderId }) else { return }
            book.add(book.record(children, in: target, at: .now))
            save()
        }
    }

    private func updatePin(_ folderId: String, _ change: (inout PinnedFolder) -> Void) {
        guard let index = book.pinned.firstIndex(where: { $0.id == folderId }) else { return }
        change(&book.pinned[index])
    }

    // MARK: - Reading

    /// The window is open: everything up to now has been seen.
    func markSeen() {
        guard account != nil else { return }
        book.lastSeen = .now
        save()
    }

    // MARK: - The file

    /// `Application Support/FolderWatch/<account>.json`.
    nonisolated private static func fileURL(key: String) -> URL {
        URL.applicationSupportDirectory
            .appending(path: "FolderWatch", directoryHint: .isDirectory)
            .appending(path: "\(key).json", directoryHint: .notDirectory)
    }

    /// Encoded and written on `disk`, behind any earlier writes.
    private func save() {
        guard let key = account?.key else { return }
        let book = self.book
        let url = Self.fileURL(key: key)
        disk.async { @Sendable in
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try JSONEncoder().encode(book).write(to: url, options: .atomic)
            } catch {
                #if DEBUG
                print("[Watch] couldn't save \(url.lastPathComponent): \(error)")
                #endif
            }
        }
    }

    /// Read on `disk` too, so it waits for any write still queued for the
    /// account: switching away and straight back mustn't read what the file
    /// held before the last check was saved.
    private func load(key: String) -> FolderWatchBook {
        let url = Self.fileURL(key: key)
        return disk.sync { @Sendable in
            guard let data = try? Data(contentsOf: url) else { return FolderWatchBook() }
            do {
                return try JSONDecoder().decode(FolderWatchBook.self, from: data)
            } catch {
                // Set aside rather than overwritten by the empty book that
                // replaces it: the pinned folders in it are worth keeping.
                let aside = url.deletingPathExtension().appendingPathExtension("unreadable.json")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: url, to: aside)
                #if DEBUG
                print("[Watch] \(url.lastPathComponent) unreadable, set aside: \(error)")
                #endif
                return FolderWatchBook()
            }
        }
    }
}
