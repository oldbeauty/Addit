import SwiftUI
import SwiftData

// Folder tracking's screens: the library toolbar's button, the Tracking
// screen it pushes, and the modifier that decides when checks run. The model
// is `FolderWatch.swift`, the work `FolderWatchService`; see
// `skill://folder-tracking`.

// MARK: - Toolbar button

/// The library toolbar's way into tracking: an eyeball that turns with the
/// scroll (`EyeOrnament`), with a dot while there's news from someone else.
/// Its own view so the count it reads invalidates it, not `LibraryView`.
struct FolderWatchButton: View {
    @Environment(FolderWatchService.self) private var folderWatch
    /// The library's scroll, which turns the eye.
    var offset: ScrollOffsetBox
    let action: () -> Void

    var body: some View {
        let unread = folderWatch.unreadCount
        Button(action: action) {
            EyeOrnament(offset: offset)
                .overlay(alignment: .topTrailing) {
                    if unread > 0 {
                        Circle()
                            .fill(.tint)
                            .frame(width: 7, height: 7)
                            .offset(x: 2, y: -1)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: unread > 0)
        }
        .accessibilityLabel("Tracking")
        .accessibilityValue(unread > 0 ? "\(unread) new" : "")
    }
}

// MARK: - When checks run

extension View {
    /// Runs tracking's checks for the library on screen: as it appears, when
    /// the viewed account changes, and each time the app comes back to the
    /// foreground — each only if one is due (`FolderWatchService.checkIfDue`).
    /// `library` is read only when a check starts, not on every body.
    func folderWatchChecks(for account: WatchAccount?, library: @escaping () -> [WatchTarget]) -> some View {
        modifier(FolderWatchChecks(account: account, library: library))
    }
}

/// A modifier of its own so the scene phase it reads invalidates it alone,
/// not the library it's attached to.
private struct FolderWatchChecks: ViewModifier {
    let account: WatchAccount?
    let library: () -> [WatchTarget]
    @Environment(FolderWatchService.self) private var folderWatch
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: account, initial: true) { _, account in
                folderWatch.activate(account)
                folderWatch.checkIfDue(library: library())
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { folderWatch.checkIfDue(library: library()) }
            }
    }
}

// MARK: - The screen

/// Tracking: what's arrived in the tracked folders, newest first, and which
/// folders those are — every album in the library, plus any folder picked
/// here. A new folder can be added to the library from its event.
///
/// Pushed onto the library's stack like an album (`LibraryRoute.tracking`),
/// with the same flat slide and back button; its title is the large one at
/// the top of the list. It exists only while it's on screen, so appearing is
/// "opened" — including coming back to it from an album opened here.
struct FolderWatchPanel: View {
    /// The library's album folders, read when a check starts.
    let library: () -> [WatchTarget]
    /// Shows an album, pushed over this screen; back returns here.
    let onOpenAlbum: (Album) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(FolderWatchService.self) private var folderWatch
    @Environment(CloudServiceRouter.self) private var cloudRouter
    @Environment(AudioPlayerService.self) private var playerService
    @Query private var albums: [Album]

    /// Opens on what's new, every time.
    @State private var pane: TrackingPane = .activity
    /// Counts switches made by tapping the bar — what the haptic fires on, so
    /// a swipe between panes doesn't buzz.
    @State private var tapSwitches = 0

    /// Between the bar and whatever's under it: the screen's bottom, or the
    /// mini player.
    private static let barGap: CGFloat = 8

    /// When tracking was last open before this visit. Anything newer keeps
    /// its dot until it closes, though opening it cleared the button's
    /// straight away.
    @State private var seenBefore: Date?
    @State private var isPicking = false
    /// New folders being added to the library from here.
    @State private var adding: Set<String> = []
    @State private var addFailure: AddFailure?
    /// New folders found to be deleted or unshared since their event: they
    /// say so instead of offering Add again.
    @State private var removed: Set<String> = []
    /// A new folder with no audio of its own, offered for tracking instead.
    @State private var folderOfFolders: DriveItem?

    var body: some View {
        let albumsByFolder = libraryAlbums()
        // Two pages a swipe apart, switched by the bar below as well: a
        // paging view rather than the system tab bar, which can't page, won't
        // drop its glass selection blob, and has no rounded triangle to draw.
        TabView(selection: $pane) {
            paneList {
                paneTitle("Activity") { CheckedReadout() }
                failureNotice
                activity(albumsByFolder: albumsByFolder)
            }
            .tag(TrackingPane.activity)
            paneList {
                paneTitle("Tracked") { EmptyView() }
                failureNotice
                tracked(libraryCount: albumsByFolder.count)
            }
            .tag(TrackingPane.tracked)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // An inset rather than an overlay, so each list's last rows rest
        // above the bar while still scrolling under its glass. With a track
        // playing it stands on top of the mini player, as the library's +
        // button does.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TrackingPaneBar(selection: pane) { switchByTap(to: $0) }
                .padding(.bottom, isMiniPlayerShowing
                         ? NowPlayingPill.overlayHeight + Self.barGap : Self.barGap)
        }
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.8), trigger: tapSwitches)
        .sheet(isPresented: $isPicking) {
            if let provider = folderWatch.account?.source.provider {
                TrackFolderPicker(
                    provider: provider,
                    trackedIds: Set(folderWatch.book.pinned.map(\.id))
                ) { folder in
                    folderWatch.track(folder)
                }
                .scrollIndicators(.hidden)
            }
        }
        .alert(
            addFailure?.title ?? "",
            isPresented: Binding(
                get: { addFailure != nil },
                set: { if !$0 { addFailure = nil } }
            ),
            presenting: addFailure
        ) { _ in
            Button("OK", role: .cancel) { addFailure = nil }
        } message: { failure in
            Text(failure.message)
        }
        .alert(
            "No Tracks in This Folder",
            isPresented: Binding(
                get: { folderOfFolders != nil },
                set: { if !$0 { folderOfFolders = nil } }
            ),
            presenting: folderOfFolders
        ) { folder in
            Button("Track Folder") {
                folderWatch.track(folder)
                folderOfFolders = nil
            }
            Button("Cancel", role: .cancel) { folderOfFolders = nil }
        } message: { folder in
            Text("\u{201C}\(folder.name)\u{201D} has no tracks of its own, so it can't be an album. If it's a folder of albums, track it to hear about each one added to it.")
        }
        .onAppear {
            seenBefore = folderWatch.book.lastSeen
            folderWatch.markSeen()
            folderWatch.checkIfDue(library: library(), maxAge: FolderWatchService.windowInterval)
        }
        .onDisappear { folderWatch.markSeen() }
    }

    // MARK: Panes

    /// The bar's tap: a pop, then the page slides over. A swipe changes
    /// `pane` too, but only a tap counts here, so only a tap buzzes.
    private func switchByTap(to target: TrackingPane) {
        guard target != pane else { return }
        tapSwitches &+= 1
        withAnimation(.snappy(duration: 0.3)) { pane = target }
    }

    /// `ContentView`'s own test for the pill being up.
    private var isMiniPlayerShowing: Bool {
        playerService.currentTrack != nil && !playerService.hideNowPlayingBar
    }

    /// A pane: a list on the page itself, no scroll bar, pull to check now.
    private func paneList<Rows: View>(@ViewBuilder _ rows: () -> Rows) -> some View {
        List { rows() }
            .scrollIndicators(.hidden)
            .appBackground()
            .refreshable { await folderWatch.checkNow(library: library()) }
    }

    /// A pane's large title, on the list's own row insets so it starts where
    /// the rows do, with anything that belongs beside it.
    private func paneTitle<Trailing: View>(
        _ title: String, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.uiLargeTitle.weight(.bold))
            Spacer(minLength: 8)
            trailing()
        }
        .listRowBackground(Color.clear)
    }

    /// Why the last check stopped short, at the top of either pane.
    @ViewBuilder
    private var failureNotice: some View {
        if let failure = folderWatch.failure {
            Section {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.uiFootnote)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func activity(albumsByFolder: [String: Album]) -> some View {
        Section {
            if folderWatch.book.events.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nothing new yet")
                        .font(.uiSubheadline.weight(.medium))
                    Text("New folders and tracks in anything tracked show up here. Addit looks whenever it opens; pull down to look now.")
                        .font(.uiFootnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(folderWatch.book.events) { event in
                    FolderWatchEventRow(
                        event: event,
                        isUnread: !event.byMe && event.date > (seenBefore ?? .distantPast),
                        albumsByFolder: albumsByFolder,
                        adding: adding,
                        removed: removed,
                        add: { item in Task { await addToLibrary(item) } },
                        open: onOpenAlbum
                    )
                }
            }
        }
        // Text straight on the page, no rounded cells behind it (2026-10-09).
        .listRowBackground(Color.clear)
    }

    private func tracked(libraryCount: Int) -> some View {
        Section {
            Button {
                isPicking = true
            } label: {
                Label("Track a Folder…", systemImage: "plus")
            }
            ForEach(folderWatch.book.pinned) { pin in
                PinnedFolderRow(
                    pin: pin,
                    snapshot: folderWatch.book.snapshots[pin.id],
                    isListing: folderWatch.baselining.contains(pin.id)
                )
                .swipeActions {
                    Button("Stop Tracking", role: .destructive) { folderWatch.untrack(pin.id) }
                }
                .contextMenu {
                    Button("Stop Tracking", systemImage: "xmark", role: .destructive) {
                        folderWatch.untrack(pin.id)
                    }
                }
            }
            HStack(spacing: 12) {
                Image(systemName: "square.stack.fill")
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Albums in Your Library")
                    Text("Tracked automatically")
                        .font(.uiCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text("\(libraryCount)")
                    .font(.readout(13))
                    .foregroundStyle(Phosphor.lit)
                    .phosphorGlow()
            }
        } footer: {
            Text("Track a folder of albums to hear about each album added to it. The folder doesn't need any tracks of its own.")
        }
        .listRowBackground(Color.clear)
    }

    // MARK: Actions

    /// The library's albums by folder ID, for "Open" and the count.
    private func libraryAlbums() -> [String: Album] {
        guard let account = folderWatch.account else { return [:] }
        var byFolder: [String: Album] = [:]
        for album in albums where album.accountId == account.key && album.storageSource == account.source {
            byFolder[album.googleFolderId] = album
        }
        return byFolder
    }

    /// A new folder from an event, added the way the add-album picker adds
    /// one (`AlbumImporter`). Once it's in the library it's tracked as an
    /// album, from the next check.
    ///
    /// Between the event and the tap the folder may have changed, and "no
    /// tracks" has three causes that need telling apart. Deleted in Drive, a
    /// folder sits in the trash still answering for itself, and only its
    /// listing comes back empty — taking that for a folder of albums asked
    /// whether to track an album that no longer existed (2026-10-07). So:
    /// gone (deleted, trashed, or unshared) first, then a folder whose tracks
    /// were all removed, and only a folder with subfolders and no tracks is
    /// offered for tracking instead.
    private func addToLibrary(_ item: FolderWatchEvent.Item) async {
        guard let account = folderWatch.account, !adding.contains(item.id) else { return }
        adding.insert(item.id)
        defer { adding.remove(item.id) }
        let drive = cloudRouter.service(for: account.source)
        let importer = AlbumImporter(driveService: drive, modelContext: modelContext)
        let driveName = account.source == .oneDrive ? "OneDrive" : "Google Drive"
        guard importer.existingAlbum(folderId: item.id, accountId: account.key) == nil else { return }
        do {
            let (folder, audioFiles) = try await importer.resolve(folderId: item.id)
            guard folderWatch.account == account else { return }
            if folder.trashed == true {
                removed.insert(item.id)
                addFailure = AddFailure(
                    title: "Album Deleted",
                    message: "\u{201C}\(folder.name)\u{201D} was deleted in \(driveName) after it was added, so there's nothing left to add."
                )
                return
            }
            guard !audioFiles.isEmpty else {
                let subfolders = try await drive.listSubfolders(inFolder: folder.id).files
                guard folderWatch.account == account else { return }
                if subfolders.isEmpty {
                    addFailure = AddFailure(
                        title: "No Tracks",
                        message: "\u{201C}\(folder.name)\u{201D} has no tracks in it now. They may have been deleted, or not uploaded yet."
                    )
                } else {
                    folderOfFolders = folder
                }
                return
            }
            let album = try importer.insert(
                folder: folder, audioFiles: audioFiles,
                accountId: account.key, storageSource: account.source
            )
            Task { await importer.finishImport(of: album, audioFiles: audioFiles) }
        } catch {
            guard folderWatch.account == account else { return }
            // Read the way the playback alert reads a failed download.
            switch PlaybackFailure.Reason(downloadError: error, suspended: false) {
            case .removedFromDrive, .noAccess:
                removed.insert(item.id)
                addFailure = AddFailure(
                    title: "Album Not Found",
                    message: "\u{201C}\(item.name)\u{201D} isn't in \(driveName) any more. It was deleted, or it's no longer shared with you."
                )
            case .offline, .interruptedInBackground:
                addFailure = AddFailure(
                    title: "Couldn't Add Album",
                    message: "Couldn't reach \(driveName). Check your connection and try again."
                )
            default:
                addFailure = AddFailure(title: "Couldn't Add Album", message: error.localizedDescription)
            }
        }
    }
}

/// Why an Add from an event didn't work, as an alert.
private struct AddFailure {
    let title: String
    let message: String
}

// MARK: - Rows

/// One event: what arrived, where, from whom, and when. A new folder can be
/// added to the library (or opened, once it's there); a track event opens the
/// album it's in.
private struct FolderWatchEventRow: View {
    let event: FolderWatchEvent
    let isUnread: Bool
    let albumsByFolder: [String: Album]
    let adding: Set<String>
    let removed: Set<String>
    let add: (FolderWatchEvent.Item) -> Void
    let open: (Album) -> Void

    var body: some View {
        if event.kind == .track, let album = albumsByFolder[event.folderId] {
            Button { open(album) } label: { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    /// Where the headline's text starts: past the 30pt picture and its 10pt
    /// gap. The lines under the headline start there too.
    private static let textInset: CGFloat = 40

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Who it's from, where a kind icon would be: the headline already
            // says whether it's folders or tracks.
            HStack(alignment: .center, spacing: 10) {
                EventAvatar(photo: event.photo, name: event.addedBy)
                Text(event.headline)
                    .font(.uiSubheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isUnread {
                    Circle()
                        .fill(.tint)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("New")
                }
            }

            Group {
                switch event.kind {
                case .folder:
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(event.items, id: \.id) { item in
                            folderLine(item)
                        }
                        if let more = more {
                            Text(more)
                                .font(.uiFootnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                case .track:
                    Text(trackNames)
                        .font(.uiFootnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                Text(WatchReadout.age(of: event.date))
                    .font(.readout(10))
                    .foregroundStyle(Phosphor.dim)
            }
            .padding(.leading, Self.textInset)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func folderLine(_ item: FolderWatchEvent.Item) -> some View {
        HStack(spacing: 10) {
            Text(item.name)
                .font(.uiFootnote)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let album = albumsByFolder[item.id] {
                Button("Open") { open(album) }
            } else if adding.contains(item.id) {
                ProgressView()
                    .controlSize(.small)
            } else if removed.contains(item.id) {
                Text("Deleted")
                    .font(.uiFootnote)
                    .foregroundStyle(.secondary)
            } else {
                Button("Add") { add(item) }
                    .accessibilityLabel("Add \(item.name) to Library")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// Track names without their extensions, as the album lists them.
    private var trackNames: String {
        let names = event.items.prefix(6).map { ($0.name as NSString).deletingPathExtension }
        let rest = event.count - names.count
        return names.joined(separator: ", ") + (rest > 0 ? ", and \(rest) more" : "")
    }

    private var more: String? {
        let rest = event.count - event.items.count
        return rest > 0 ? "and \(rest) more" : nil
    }
}

/// Who an event is from, as a face: their profile picture where the drive
/// gave one (Drive does for a file's owner), their initials where it didn't
/// (OneDrive, and events saved before pictures were kept).
private struct EventAvatar: View {
    let photo: String?
    let name: String?

    private static let size: CGFloat = 30

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: Self.size, height: Self.size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    /// Drive's photo links end in a size (`=s64`); asked for at the size
    /// drawn on a 3× screen instead, or the face is soft.
    private var url: URL? {
        guard var link = photo else { return nil }
        if let size = link.range(of: "=s[0-9]+$", options: .regularExpression) {
            link.replaceSubrange(size, with: "=s\(Int(Self.size * 3))")
        }
        return URL(string: link)
    }

    private var initials: some View {
        ZStack {
            Circle().fill(Color.secondary.opacity(0.22))
            if let letters {
                Text(letters).font(.ui(12, weight: .semibold))
            } else {
                Image(systemName: "person.fill").font(.ui(13))
            }
        }
        .foregroundStyle(.secondary)
    }

    private var letters: String? {
        let words = (name ?? "").split(separator: " ").prefix(2)
        let letters = String(words.compactMap(\.first)).uppercased()
        return letters.isEmpty ? nil : letters
    }
}

/// Tracking's two panes, left to right.
private enum TrackingPane: Hashable {
    case activity, tracked
}

/// The panes' switcher: two hollow, rounded marks on a floating glass
/// capsule — a triangle for Activity, a square for Tracked — white for the
/// pane on screen, grey for the other. No labels and no selection blob;
/// the colour is the whole signal.
private struct TrackingPaneBar: View {
    let selection: TrackingPane
    let select: (TrackingPane) -> Void

    private static let height: CGFloat = 52
    private static let itemWidth: CGFloat = 68

    var body: some View {
        HStack(spacing: 0) {
            // Sized by eye against each other: a triangle in the same box as
            // a square reads smaller.
            item(.activity, label: "Activity", shape: RoundedTriangle(), size: CGSize(width: 25, height: 22))
            item(.tracked, label: "Tracked",
                 shape: RoundedRectangle(cornerRadius: 5, style: .continuous),
                 size: CGSize(width: 19, height: 19))
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(.easeOut(duration: 0.15), value: selection)
    }

    private func item<S: Shape>(
        _ pane: TrackingPane, label: String, shape: S, size: CGSize
    ) -> some View {
        let isActive = selection == pane
        return Button { select(pane) } label: {
            shape
                .stroke(style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .frame(width: size.width, height: size.height)
                .foregroundStyle(isActive ? Color.white : Color(white: 0.5))
                .frame(width: Self.itemWidth, height: Self.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// A triangle, point up, with rounded corners — for stroking. The points sit
/// a stroke's width in from the frame so the line stays inside it.
private struct RoundedTriangle: Shape {
    var cornerRadius: CGFloat = 3.2

    func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: 1.1, dy: 1.1)
        let top = CGPoint(x: inset.midX, y: inset.minY)
        let right = CGPoint(x: inset.maxX, y: inset.maxY)
        let left = CGPoint(x: inset.minX, y: inset.maxY)
        var path = Path()
        // From the middle of the base, so every corner is an arc between
        // two tangents.
        path.move(to: CGPoint(x: inset.midX, y: inset.maxY))
        path.addArc(tangent1End: left, tangent2End: top, radius: cornerRadius)
        path.addArc(tangent1End: top, tangent2End: right, radius: cornerRadius)
        path.addArc(tangent1End: right, tangent2End: left, radius: cornerRadius)
        path.closeSubpath()
        return path
    }
}

/// A folder picked for tracking, and what it held at the last look.
private struct PinnedFolderRow: View {
    let pin: PinnedFolder
    let snapshot: FolderSnapshot?
    let isListing: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: pin.isMissing ? "folder.badge.questionmark" : "folder.fill")
                .foregroundStyle(pin.isMissing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(pin.name)
                    .lineLimit(1)
                Text(status)
                    .font(.uiCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isListing {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var status: String {
        if pin.isMissing { return "Not found: deleted, or no longer shared with you" }
        if let snapshot { return WatchReadout.contents(folders: snapshot.folders, tracks: snapshot.tracks) }
        return isListing ? "Looking inside…" : "Waiting for its first look"
    }
}

/// When tracking last looked, as a readout: "CHECKED 4M AGO".
private struct CheckedReadout: View {
    @Environment(FolderWatchService.self) private var folderWatch

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(text(now: context.date))
                .font(.readout(10))
                .foregroundStyle(Phosphor.lit)
                .phosphorGlow()
        }
    }

    private func text(now: Date) -> String {
        if folderWatch.isChecking { return "CHECKING…" }
        guard let lastChecked = folderWatch.book.lastChecked else { return "NOT CHECKED YET" }
        let age = WatchReadout.age(of: lastChecked, now: now)
        return age == "NOW" ? "CHECKED JUST NOW" : "CHECKED \(age)"
    }
}
