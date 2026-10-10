import Foundation

// Folder tracking, the model: what tracking remembers about a folder, how a
// fresh listing of it is turned into news, and what the news looks like.
//
// "Tracking" in the UI, "watch" in code: a `Track` here is a song, and names
// like `TrackedFolder.tracks` would read as a folder's songs. The rules this
// file exists to keep are in `skill://folder-tracking`.
//
// Foundation only, and every type `nonisolated`, so `tools/foldertrack` can
// compile this file as it ships and check it on a Mac.

/// One thing directly inside a tracked folder that tracking counts: a
/// subfolder, or audio Addit can play. Everything else in a folder (covers,
/// `.addit-data`, documents) is invisible to it.
nonisolated struct FolderChild: Equatable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable {
        case folder
        case track
    }

    let id: String
    let name: String
    let kind: Kind
    /// Who put it there, as near as the drive will say: the file's owner on
    /// Google Drive (in a shared drive, which has no owners, the last person
    /// to change it), its creator on OneDrive. For something moved in from
    /// elsewhere that is whoever made it, not whoever moved it — neither
    /// provider says who moved a file. `nil` when the drive won't say.
    let addedBy: String?
    /// That person is the signed-in account. `false` when unknown, so an
    /// addition nobody can attribute still counts as news.
    let addedByMe: Bool
    /// Their profile picture's URL, where the drive gives one (Drive does,
    /// on a file's owner; Graph doesn't).
    var addedByPhoto: String? = nil
}

/// A folder tracking compares from one check to the next.
nonisolated struct WatchTarget: Hashable, Sendable {
    let folderId: String
    let name: String
}

/// Why `CloudDriveService.listWatchedChildren` couldn't list a batch: the
/// folders in it, not the connection or the account. A folder that's gone or
/// no longer shared, or — on Drive — more folders than one query will take.
/// `ListingQueue.reject` is the answer to it.
nonisolated enum FolderListingError: Error, Equatable {
    case unlistable
}

/// What tracking knows a folder holds.
nonisolated struct FolderSnapshot: Codable, Sendable, Equatable {
    /// Every child ID ever seen in the folder. It only grows; see
    /// `FolderWatchBook.record`.
    var seen: Set<String>
    /// When the folder was last listed in full.
    var listedAt: Date
    /// What that listing held, for the counts the window shows.
    var folders: Int
    var tracks: Int
}

/// News from a tracked folder, as the window lists it: everything of one kind,
/// from one person, that one check found new in one folder. "Alex added 2
/// folders" and "you added a track" are separate events.
nonisolated struct FolderWatchEvent: Codable, Sendable, Identifiable, Hashable {
    nonisolated struct Item: Codable, Sendable, Hashable {
        let id: String
        let name: String
    }

    let id: UUID
    /// The tracked folder it arrived in, and that folder's name at the time.
    let folderId: String
    let folderName: String
    let kind: FolderChild.Kind
    /// What arrived, sorted by name; at most `FolderWatchBook.itemsPerEvent`.
    let items: [Item]
    /// How many arrived, counting any past the cap on `items`.
    let count: Int
    /// The person they're from, or `nil` when the drive won't say.
    let addedBy: String?
    let byMe: Bool
    /// When a check found them. Not when they were added: a file moved into a
    /// folder keeps the date it was created somewhere else, so that can't be
    /// known.
    let date: Date
    /// The profile picture of whoever it's from, where the drive gave one.
    /// Optional with a default so events saved before it existed still open.
    var photo: String? = nil

    /// "Alex added 2 folders to Good Music", "You added a track to Rumours",
    /// "3 new tracks in Rumours".
    var headline: String {
        let noun = switch kind {
        case .folder: count == 1 ? "folder" : "folders"
        case .track: count == 1 ? "track" : "tracks"
        }
        let amount = count == 1 ? "a \(noun)" : "\(count) \(noun)"
        if byMe {
            return "You added \(amount) to \(folderName)"
        }
        if let addedBy, !addedBy.isEmpty {
            return "\(addedBy) added \(amount) to \(folderName)"
        }
        return count == 1 ? "New \(noun) in \(folderName)" : "\(count) new \(noun) in \(folderName)"
    }
}

/// A folder the user chose to track, beyond the library's albums. What it's
/// for is a folder of albums ("Good Music"), whose subfolders are what's new.
nonisolated struct PinnedFolder: Codable, Sendable, Identifiable, Hashable {
    let id: String
    var name: String
    let pinnedAt: Date
    /// The drive says it's gone, or no longer shared with this account. Kept
    /// rather than dropped, so a folder that comes back is tracked again from
    /// where it left off; the user can stop tracking it.
    var isMissing: Bool
}

/// Everything tracking keeps for one account, stored as one JSON file.
/// `FolderWatchService` owns the reading and writing; everything that changes
/// it is here, so it can be checked away from the app.
nonisolated struct FolderWatchBook: Codable, Sendable, Equatable {
    static let version = 1
    /// Only the newest this many events are kept.
    static let eventLimit = 200
    /// Items named per event; the rest are only counted.
    static let itemsPerEvent = 50
    /// How long a snapshot outlives its folder's tracking. An album removed
    /// from the library and added back within this carries on from where it
    /// was, rather than starting from a fresh baseline.
    static let snapshotRetention: TimeInterval = 60 * 24 * 60 * 60

    var pinned: [PinnedFolder] = []
    var snapshots: [String: FolderSnapshot] = [:]
    /// Newest first.
    var events: [FolderWatchEvent] = []
    /// The last check that listed every tracked folder.
    var lastChecked: Date?
    /// The last time the window was open. Events after it are unread.
    var lastSeen: Date?

    init() {}

    // MARK: Listings

    /// Folds one folder's complete listing in, and returns what was new.
    ///
    /// The first listing of a folder is its baseline: what's already there
    /// isn't news, so nothing is returned. After that, a child is new the
    /// first time its ID appears, and `seen` never forgets one. So a child
    /// that drops out of a listing and comes back is not news twice, whether
    /// it was moved out and back, or the whole folder was briefly unreadable
    /// (a share revoked and restored lists as empty in between). Without that,
    /// a sharing hiccup would replay a folder's entire contents as new.
    ///
    /// `listing` must be complete, every page of it: a partial listing taken
    /// as a baseline would report the part it missed as new next time.
    mutating func record(_ listing: [FolderChild], in target: WatchTarget, at date: Date) -> [FolderWatchEvent] {
        var folderIds = Set<String>()
        var trackIds = Set<String>()
        for child in listing {
            switch child.kind {
            case .folder: folderIds.insert(child.id)
            case .track: trackIds.insert(child.id)
            }
        }

        guard var snapshot = snapshots[target.folderId] else {
            snapshots[target.folderId] = FolderSnapshot(
                seen: folderIds.union(trackIds), listedAt: date,
                folders: folderIds.count, tracks: trackIds.count
            )
            return []
        }

        // `insert` reports whether the ID was there already, which is the
        // whole test — and it drops an ID a listing repeats.
        var fresh: [FolderChild] = []
        for child in listing where snapshot.seen.insert(child.id).inserted {
            fresh.append(child)
        }
        snapshot.listedAt = date
        snapshot.folders = folderIds.count
        snapshot.tracks = trackIds.count
        snapshots[target.folderId] = snapshot
        return Self.events(for: fresh, in: target, at: date)
    }

    /// One event per kind and per person, folders first, then in the order
    /// the listing gave them.
    static func events(for fresh: [FolderChild], in target: WatchTarget, at date: Date) -> [FolderWatchEvent] {
        var groups: [Source: [FolderChild]] = [:]
        var order: [Source] = []
        for child in fresh {
            let source = Source(
                kind: child.kind, byMe: child.addedByMe,
                person: child.addedByMe ? nil : child.addedBy
            )
            if groups[source] == nil { order.append(source) }
            groups[source, default: []].append(child)
        }
        let foldersFirst = order.filter { $0.kind == .folder } + order.filter { $0.kind == .track }
        return foldersFirst.map { source in
            let children = (groups[source] ?? []).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return FolderWatchEvent(
                id: UUID(),
                folderId: target.folderId,
                folderName: target.name,
                kind: source.kind,
                items: children.prefix(itemsPerEvent).map { .init(id: $0.id, name: $0.name) },
                count: children.count,
                addedBy: source.byMe ? children.first?.addedBy : source.person,
                byMe: source.byMe,
                date: date,
                photo: children.lazy.compactMap(\.addedByPhoto).first
            )
        }
    }

    /// Who an event is from: one per kind and person.
    private nonisolated struct Source: Hashable {
        let kind: FolderChild.Kind
        let byMe: Bool
        let person: String?
    }

    /// Files a check's events at the top, keeping the list newest first even
    /// if they're older than something already there (a folder's first
    /// listing landing after a check that started later), and drops the
    /// oldest past `eventLimit`.
    mutating func add(_ newEvents: [FolderWatchEvent]) {
        guard let date = newEvents.first?.date else { return }
        let index = events.firstIndex { $0.date <= date } ?? events.endIndex
        events.insert(contentsOf: newEvents, at: index)
        if events.count > Self.eventLimit {
            events.removeLast(events.count - Self.eventLimit)
        }
    }

    // MARK: Reading

    /// Events from other people since the window was last open. Your own
    /// additions are listed but never counted: you know about them already,
    /// and an album you filled from edit mode shouldn't light the button.
    var unreadCount: Int {
        let since = lastSeen ?? .distantPast
        return events.prefix { $0.date > since }.filter { !$0.byMe }.count
    }

    // MARK: Pinned folders

    /// Starts tracking a folder. `false` if it was already pinned.
    mutating func pin(_ folderId: String, name: String, at date: Date) -> Bool {
        guard !pinned.contains(where: { $0.id == folderId }) else { return false }
        pinned.append(PinnedFolder(id: folderId, name: name, pinnedAt: date, isMissing: false))
        return true
    }

    /// Stops tracking a pinned folder, forgetting what it held unless it's
    /// still tracked another way (as a library album) — tracking it again
    /// later starts from a fresh baseline, as a new pin should.
    mutating func unpin(_ folderId: String, keepingSnapshot: Bool) {
        pinned.removeAll { $0.id == folderId }
        if !keepingSnapshot { snapshots[folderId] = nil }
    }

    /// Drops the snapshots of folders no longer tracked, once they've gone
    /// unlisted for `snapshotRetention`.
    mutating func pruneSnapshots(tracking tracked: Set<String>, now: Date) {
        snapshots = snapshots.filter { id, snapshot in
            tracked.contains(id) || now.timeIntervalSince(snapshot.listedAt) < Self.snapshotRetention
        }
    }

    // MARK: Coding
    //
    // Written by hand so a key that's missing decodes to its default: a file
    // written before a field existed must still open, or the pinned folders
    // in it are lost.

    private enum CodingKeys: String, CodingKey {
        case version, pinned, snapshots, events, lastChecked, lastSeen
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pinned = try container.decodeIfPresent([PinnedFolder].self, forKey: .pinned) ?? []
        snapshots = try container.decodeIfPresent([String: FolderSnapshot].self, forKey: .snapshots) ?? [:]
        events = try container.decodeIfPresent([FolderWatchEvent].self, forKey: .events) ?? []
        lastChecked = try container.decodeIfPresent(Date.self, forKey: .lastChecked)
        lastSeen = try container.decodeIfPresent(Date.self, forKey: .lastSeen)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.version, forKey: .version)
        try container.encode(pinned, forKey: .pinned)
        try container.encode(snapshots, forKey: .snapshots)
        try container.encode(events, forKey: .events)
        try container.encodeIfPresent(lastChecked, forKey: .lastChecked)
        try container.encodeIfPresent(lastSeen, forKey: .lastSeen)
    }
}

/// The order a check lists folders in: `batchSize` at a time, and any batch
/// the drive turns down (`FolderListingError.unlistable`) split in two and
/// tried again first, until each folder it can't list is on its own. One
/// folder that's gone then costs only itself, and a query Drive finds too big
/// is cut down to one it takes.
nonisolated struct ListingQueue {
    private var pending: [[String]]
    /// Folders the drive wouldn't list even alone.
    private(set) var unlistable: Set<String> = []

    init(_ ids: [String], batchSize: Int) {
        let size = max(1, batchSize)
        pending = stride(from: 0, to: ids.count, by: size).map {
            Array(ids[$0 ..< min($0 + size, ids.count)])
        }
    }

    mutating func next() -> [String]? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    /// `batch` came back `.unlistable`: its halves go next, and a folder that
    /// was already alone is given up on for this check.
    mutating func reject(_ batch: [String]) {
        guard batch.count > 1 else {
            unlistable.formUnion(batch)
            return
        }
        let middle = batch.count / 2
        pending.insert(contentsOf: [Array(batch[..<middle]), Array(batch[middle...])], at: 0)
    }
}

/// The display layer's wording for tracking: ages and counts, set in the
/// readout face.
nonisolated enum WatchReadout {
    /// "NOW", "5M AGO", "3H AGO", "2D AGO", then a date: "SEP 12".
    static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "NOW"
        case ..<3_600: return "\(Int(seconds / 60))M AGO"
        case ..<86_400: return "\(Int(seconds / 3_600))H AGO"
        case ..<(7 * 86_400): return "\(Int(seconds / 86_400))D AGO"
        default:
            return date.formatted(.dateTime.month(.abbreviated).day()).uppercased()
        }
    }

    /// "12 folders · 3 tracks", leaving out a kind there's none of.
    static func contents(folders: Int, tracks: Int) -> String {
        var parts: [String] = []
        if folders > 0 { parts.append("\(folders) \(folders == 1 ? "folder" : "folders")") }
        if tracks > 0 { parts.append("\(tracks) \(tracks == 1 ? "track" : "tracks")") }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }
}
