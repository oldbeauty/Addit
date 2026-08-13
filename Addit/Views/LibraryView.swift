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
    @State private var showFeedback = false
    @State private var showCreateAlbum = false
    @State private var showSettings = false
    /// Set just before pushing an album so the navigation destination
    /// opens it with inline edit mode armed; cleared when the library
    /// reappears. Replaces the old AlbumMetadataEditorSheet presentation.
    @State private var pendingEditAlbumId: String?

    /// Storage usage per account email, for the account switcher.
    ///
    /// Only ever holds the **in-use** account of each provider, and that's a
    /// limit of the providers rather than a shortcut: a drive service reports
    /// the quota of whoever it is signed in as, and `GoogleAuthService`
    /// deliberately refuses to vend a token when its current user isn't the
    /// in-use Google account. Reading a second Google account's quota would
    /// mean switching to it. Rows with no entry here simply show no bar.
    @State private var storageQuotas: [String: StorageQuota] = [:]

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
    /// Live content offset of whichever list or grid is on screen, feeding the
    /// toolbar orb's spin. Not clamped or reset between the two layouts: the
    /// orb has no home position, so a jump just spins it.
    @State private var scrollOffset: CGFloat = 0
    @AppStorage("storageSource") private var storageSource: String = StorageSource.googleDrive.rawValue
    @State private var showLocalImporter = false
    @State private var isImportingLocal = false
    @State private var importProgress: (current: Int, total: Int, trackName: String) = (0, 0, "")
    /// Which cloud "Add from…" is browsing for loose audio files. Non-nil
    /// presents the picker.
    @State private var addFromProvider: AccountProvider?
    /// Which cloud "Copy from…" is browsing. Non-nil presents the sheet — the
    /// presentation's identity *is* the chosen provider, so the sheet can't
    /// open without knowing which cloud it's reading.
    @State private var copyFromProvider: AccountProvider?

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

    /// Providers the user actually holds an account for, in a stable order.
    /// The Local library's "Add from…" and "Copy from…" offer these rather
    /// than naming whichever account happened to be active.
    private var connectedProviders: [AccountProvider] {
        let owned = Set(authService.accountManager.accounts.map(\.provider))
        return AccountProvider.allCases.filter(owned.contains)
    }

    private var libraryIsLocal: Bool { currentSource == .localStorage }

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

    /// One provider's accounts under a header carrying the domain they have in
    /// common — "**Google Drive**  @gmail.com" — so each row below only has to
    /// show the half that actually distinguishes it.
    @ViewBuilder
    private func accountSection(_ accounts: [Account], provider: AccountProvider) -> some View {
        let domain = sharedEmailDomain(of: accounts)
        Section {
            ForEach(accounts) { account in
                accountMenu(
                    for: account,
                    // Strips only what the header is already showing, and adds
                    // the storage line where we're able to read one.
                    subtitle: accountSubtitle(for: account, hidingDomain: domain)
                )
            }
        } header: {
            Text(sectionHeader(provider: provider, domain: domain))
        }
    }

    /// "**Google Drive**  @gmail.com" — the provider heavier than a plain bold,
    /// the domain trailing it a size down and in secondary, so it reads as an
    /// annotation rather than as part of the name.
    ///
    /// Built as an `AttributedString` because per-run *size* and *color* need
    /// real attributes; Markdown's `**` only carries weight. Be aware this is
    /// best-effort: SwiftUI hands a menu section header to UIKit, whose
    /// `UIMenu.title` is a plain `String`, so the styling may be dropped even
    /// though the text itself always survives.
    private func sectionHeader(provider: AccountProvider, domain: String?) -> AttributedString {
        var title = AttributedString(provider.displayName)
        title.font = .footnote.weight(.heavy)
        guard let domain else { return title }

        var suffix = AttributedString("  @\(domain)")
        suffix.font = .caption2
        suffix.foregroundColor = .secondary
        return title + suffix
    }

    /// The domain every one of `accounts` shares, or `nil` if they don't all
    /// share one. Two accounts differing only after the `@` — a personal and a
    /// work Google account, say — would otherwise both collapse to the same
    /// row under a header claiming a domain that fits only one of them, so in
    /// that case the rows keep their full addresses.
    private func sharedEmailDomain(of accounts: [Account]) -> String? {
        let domains = accounts.map { emailDomain($0.email) }
        guard let first = domains.first, let domain = first,
              domains.allSatisfy({ $0 == domain }) else { return nil }
        return domain
    }

    private func emailDomain(_ email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        let domain = email[email.index(after: at)...]
        return domain.isEmpty ? nil : String(domain)
    }

    private func emailLocalPart(_ email: String) -> String {
        guard let at = email.lastIndex(of: "@") else { return email }
        return String(email[..<at])
    }

    // MARK: - Account storage

    /// Identity of the currently in-use accounts, used as the fetch's task id
    /// so switching accounts re-reads quotas and nothing else does.
    private var inUseAccountKey: String {
        let manager = authService.accountManager
        return [manager.activeEmail(for: .google), manager.activeEmail(for: .microsoft)]
            .map { $0 ?? "-" }
            .joined(separator: "|")
    }

    private func refreshStorageQuotas() async {
        let manager = authService.accountManager
        var fetched: [String: StorageQuota] = [:]
        // Errors are swallowed on purpose: a quota is decoration on a menu, and
        // an expired token or an offline launch must not surface as an error in
        // the library. The row just renders without a bar.
        if let email = manager.activeEmail(for: .google) {
            fetched[email] = try? await cloudRouter.google.storageQuota()
        }
        if let email = manager.activeEmail(for: .microsoft) {
            fetched[email] = try? await cloudRouter.oneDrive.storageQuota()
        }
        storageQuotas = fetched
    }

    /// The account row's second line: who the account is, and — for the in-use
    /// account of each provider — how full it is.
    ///
    /// The newline is a best-effort second line. iOS renders a menu row's
    /// subtitle as a wrapping label, so it should break; if it doesn't, the
    /// string still reads correctly run together.
    private func accountSubtitle(for account: Account, hidingDomain domain: String?) -> String {
        let identity = domain == nil ? account.email : emailLocalPart(account.email)
        guard let quota = storageQuotas[account.email] else { return identity }
        return "\(identity)\n\(storageSummary(quota))"
    }

    /// How full the account is, in words.
    ///
    /// There used to be a ten-cell bar in block characters ahead of this — a
    /// menu row can't host a real progress view, so it was drawn in text. The
    /// numbers say the same thing more precisely, and the blocks read as an
    /// artefact at subtitle size.
    private func storageSummary(_ quota: StorageQuota) -> String {
        guard let limit = quota.limitBytes else {
            // Unlimited or unreported: there is no total to be a fraction of.
            return "\(usedGigabytes(quota.usedBytes)) GB used"
        }
        // "3.2 of 15 GB" — the unit belongs to the pair, so it's said once.
        return "\(usedGigabytes(quota.usedBytes)) of \(limitGigabytes(limit)) GB"
    }

    /// Bytes per gigabyte, in the **binary** sense both providers use.
    ///
    /// Google reports a "15 GB" account as 16,106,127,360 bytes — that is
    /// 15 × 2³⁰, gibibytes labelled GB — and OneDrive does the same with its
    /// 5 GB (5,368,709,120). Dividing by 10⁹, which is what
    /// `.byteCount(style: .file)` does, is arithmetically correct and reads as
    /// 16.11 and 5.37: right numbers, matching neither provider's own UI nor
    /// the figure the user is trying to reconcile it against. Dividing by 2³⁰
    /// reproduces exactly what Drive and OneDrive show.
    private static let bytesPerGigabyte = 1024.0 * 1024.0 * 1024.0

    /// Usage to a tenth of a GB. Anything that would round away to "0.0" reads
    /// "<.1" instead — a few dozen megabytes is *some* storage, and showing it
    /// as zero is the one case where rounding states something false.
    private func usedGigabytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0" }
        let gb = Double(bytes) / Self.bytesPerGigabyte
        guard gb >= 0.05 else { return "<.1" }
        return gb.formatted(.number.precision(.fractionLength(1)))
    }

    /// The limit, whole. Plan sizes are round numbers — "15", not "15.0".
    private func limitGigabytes(_ bytes: Int64) -> String {
        (Double(bytes) / Self.bytesPerGigabyte)
            .rounded()
            .formatted(.number.precision(.fractionLength(0)))
    }

    /// One row of the account switcher: name with `subtitle` as a smaller line
    /// beneath it (the second Text renders as a menu subtitle) — the local part
    /// of the address where the section header already carries the domain, the
    /// whole address where it doesn't. A checkmark marks each account that is
    /// currently *in use* (the live account for its provider) — with a Google
    /// and a Microsoft account both signed in, both show a checkmark even
    /// though only one library is viewed at a time.
    private func accountMenu(for account: Account, subtitle: String) -> some View {
        Menu {
            // "Switch to" only makes sense for accounts that are NOT in
            // use. In-use accounts (the checkmarked ones) are switched
            // between via the library menu, not here.
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
            // Bare Text/Text/Image in the label builder is the pattern the
            // menu bridge recognizes as title/subtitle/icon — wrapping the
            // texts in a Label swallows the subtitle.
            Text(account.name)
            Text(subtitle)
            if authService.accountManager.isInUse(account) {
                Image(systemName: "checkmark")
            }
        }
    }

    /// One gutter width everywhere: the screen-edge margins and the gaps
    /// between covers all measure `gridGutter`, and cover size is whatever
    /// fills the remainder. 30 ≈ the old effective edge margin (16pt grid
    /// padding + the slack the fixed 148pt cards left in their adaptive
    /// columns) — that edge distance is the look being kept.
    private static let gridGutter: CGFloat = 30
    /// Covers never target smaller than this; wider screens add columns.
    private static let minCoverSize: CGFloat = 150

    private func gridLayout(for width: CGFloat) -> (columns: [GridItem], coverSize: CGFloat) {
        let gutter = Self.gridGutter
        let count = max(2, Int((width - gutter) / (Self.minCoverSize + gutter)))
        let coverSize = max(1, (width - CGFloat(count + 1) * gutter) / CGFloat(count))
        let column = GridItem(.fixed(coverSize), spacing: gutter)
        return (Array(repeating: column, count: count), coverSize)
    }

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
        VStack(spacing: 0) {
            // One search field, above the branching — never inside it.
            //
            // It used to be repeated in three of the branches below, so typing
            // a character that matched nothing flipped the body to the
            // no-results branch, destroyed that `TextField` and built a
            // different one: focus died with it and the keyboard dropped
            // mid-word. Deleting the text flipped back and destroyed it again.
            // A single instance outside the `if` chain survives every state
            // the content goes through.
            if isSearchExpanded { searchBar }

            if !searchText.isEmpty && filteredAlbums.isEmpty {
                ContentUnavailableView.search(text: searchText)
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
                    // Scoped to the library you're standing in, like the grid.
                    // This used the raw query, so arranging showed every album
                    // across all three storages and both accounts at once —
                    // it predates the libraries being separate at all.
                    //
                    // `sourceAlbums`, not `filteredAlbums`: a search filter must
                    // not narrow this. `onMove` renumbers by position, so
                    // reordering a filtered subset would assign those indices
                    // over albums that were hidden from view.
                    ForEach(sourceAlbums) { album in
                        HStack(spacing: 12) {
                            AlbumArtworkThumbnail(album: album, size: 48)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.name)
                                    .font(.uiBody.weight(.medium))
                                    .fadingTruncation()
                                Text(album.artistName ?? "Unknown Artist")
                                    .font(.uiCaption)
                                    .foregroundStyle(.secondary)
                                    .fadingTruncation()
                            }
                        }
                    }
                    .onMove { source, destination in
                        // Renumbering within this library only. `displayOrder`
                        // is compared solely among albums shown together, so
                        // two libraries both running 0…n is fine — what matters
                        // is that a move here can't renumber albums the user
                        // isn't looking at.
                        var ordered = sourceAlbums
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
                                        .font(.uiBody.weight(.medium))
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
                .tracksScrollOffset(into: $scrollOffset)
            } else {
                GeometryReader { geo in
                    let layout = gridLayout(for: geo.size.width)
                    ScrollView {
                        VStack(spacing: 0) {
                            LazyVGrid(columns: layout.columns, spacing: 16) {
                                ForEach(filteredAlbums) { album in
                                    // A `Button`, not a `NavigationLink`: the
                                    // link swallows the press state, so a
                                    // custom `ButtonStyle` renders nothing on
                                    // it. Pushing the path by hand is what the
                                    // context menu's Edit already does.
                                    Button {
                                        libraryPath.append(album)
                                    } label: {
                                        AlbumCard(album: album, coverSize: layout.coverSize)
                                    }
                                    .buttonStyle(ImprintButtonStyle())
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
                                            // Was a bare `modelContext.delete`,
                                            // which stranded every file the
                                            // album owned — an orphan the size
                                            // of the album, every time.
                                            removeAlbum(album)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, Self.gridGutter)
                            .padding(.vertical, 16)
                        }
                    }
                    .tracksScrollOffset(into: $scrollOffset)
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
                            StorageSourceLogo(source: currentSource, scrollOffset: scrollOffset)
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
                                    // Every source in one submenu, for the same
                                    // reason as "Copy from…": the cloud entry
                                    // used to be whichever account was active,
                                    // leaving the other one unreachable.
                                    Menu {
                                        ForEach(connectedProviders) { provider in
                                            Button {
                                                addFromProvider = provider
                                            } label: {
                                                Text(provider.displayName)
                                            }
                                        }
                                        Button {
                                            showLocalImporter = true
                                        } label: {
                                            Text("iPhone")
                                        }
                                    } label: {
                                        Label("Add Songs from…", systemImage: "square.and.arrow.down")
                                    }
                                } label: {
                                    Label("Create New", systemImage: "plus.rectangle.on.folder")
                                }
                                // A submenu, not a button: this used to copy
                                // from whichever cloud you happened to be in
                                // last, with no way to reach the other one.
                                // Hidden entirely with no accounts — someone
                                // using the app without signing in has no
                                // cloud to copy from, and an empty submenu
                                // reads as broken.
                                if !connectedProviders.isEmpty {
                                    Menu {
                                        ForEach(connectedProviders) { provider in
                                            Button {
                                                copyFromProvider = provider
                                            } label: {
                                                Text(provider.displayName)
                                            }
                                        }
                                    } label: {
                                        Label("Copy Albums from…", systemImage: "folder.badge.plus")
                                    }
                                }
                            } label: {
                                Image(systemName: "plus")
                            }
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        // Accounts grouped per provider under a bold service
                        // header ("Google Drive" / "OneDrive"), so same-name
                        // accounts stay distinguishable without a suffix.
                        let accounts = authService.accountManager.accounts
                        let googleAccounts = accounts.filter { $0.provider == .google }
                        let microsoftAccounts = accounts.filter { $0.provider == .microsoft }
                        if !googleAccounts.isEmpty {
                            accountSection(googleAccounts, provider: .google)
                        }
                        if !microsoftAccounts.isEmpty {
                            accountSection(microsoftAccounts, provider: .microsoft)
                        }

                        Section {
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
                            Button {
                                showSettings = true
                            } label: {
                                Label("Settings", systemImage: "gearshape")
                            }
                            Button {
                                showFeedback = true
                            } label: {
                                Label("Pls report bugs", systemImage: "ladybug")
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
                        // The orb *is* the account button — same menu, same
                        // placement, glass instead of the SF glyph.
                        PlasmaOrb(scrollOffset: scrollOffset)
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
        .sheet(item: $addFromProvider) { provider in
            DriveAudioPickerView(
                targetFolderId: "",
                onFilesAdded: { files in
                    Task { await createLocalAlbumFromDriveFiles(files, from: provider) }
                },
                provider: provider
            )
        }
        .sheet(item: $copyFromProvider) { provider in
            CopyAlbumFromDriveView(
                onCopy: { folder, audioFiles in
                    Task {
                        await copyDriveAlbumToLocal(
                            folder: folder, audioFiles: audioFiles, from: provider
                        )
                    }
                },
                provider: provider
            )
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showFeedback) {
            FeedbackSheet()
        }
        // Adding an account from this menu could fail silently — the alert on
        // SignInView only covers the signed-out screen, so a failed "Add
        // Account" just left the switcher unchanged with nothing said, which
        // reads as the app ignoring you.
        .alert("Couldn't Add Account", isPresented: Binding(
            get: { authService.signInError != nil },
            set: { if !$0 { authService.signInError = nil } }
        )) {
            Button("OK", role: .cancel) { authService.signInError = nil }
        } message: {
            Text(authService.signInError ?? "")
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
                            LoadingIndicator()

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
        // Keyed on the in-use accounts, so switching accounts re-reads and
        // nothing else does. Quotas move slowly; once per appearance and per
        // switch is plenty, and it keeps the network off the path of simply
        // opening the menu.
        .task(id: inUseAccountKey) {
            await refreshStorageQuotas()
        }
        .safeAreaInset(edge: .bottom) {
            if playerService.currentTrack != nil {
                // Exactly the bar's height: the grid's 16pt bottom padding then
                // puts the last row's artist line the same distance above the
                // bar as it would sit above a cover in the row below.
                Color.clear.frame(height: NowPlayingPill.overlayHeight)
            }
        }
    }

    private func clearLocalStorage() {
        // Delete all local albums from SwiftData
        let localAlbums = albums.filter { $0.isLocal }

        // Evict every local track, not just the playing one: a local track
        // sitting in the user queue behind a Drive track was left dangling by
        // the old "pause if the current track is local" check.
        playerService.forget(trackIds: Set(localAlbums.flatMap { $0.tracks }.map(\.googleFileId)))

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
        // Both of these read the records, so both run *before* the delete.
        // The player holds Track model objects; left in its queue they'd be
        // detached models it would trap on at the next gapless preload.
        playerService.forget(trackIds: Set(album.tracks.map(\.googleFileId)))
        // Files second, while the record can still say which ones. The cascade
        // rule on `Album.tracks` deletes rows, not bytes.
        LibraryCleanup.purge(album, cache: cacheService, art: albumArtService)
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

    private func createLocalAlbumFromDriveFiles(
        _ files: [DriveItem], from provider: AccountProvider
    ) async {
        guard !files.isEmpty else { return }
        await MainActor.run { isImportingLocal = true }

        // The picked files belong to the cloud chosen in "Add from…", which
        // needn't be the active account — downloading through `driveService`
        // would hit the wrong drive.
        let driveService = cloudRouter.service(for: provider.storageSource)

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

    private func copyDriveAlbumToLocal(
        folder: DriveItem, audioFiles: [DriveItem], from provider: AccountProvider
    ) async {
        await MainActor.run { isImportingLocal = true }

        // The source cloud is whichever one the user picked in "Copy from…",
        // which needn't be the active account — reading through `driveService`
        // here would list and download from the wrong drive entirely.
        let driveService = cloudRouter.service(for: provider.storageSource)

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

        // Evict this account's tracks from the player before its store goes.
        // Gated on `isCurrentAccount` before, which left the same dangling
        // models behind when the signed-out account merely had something in
        // the queue — the libraries are parallel, so a Google track can be
        // playing while you sign a Microsoft account out.
        playerService.forget(
            trackIds: Set(
                albums.filter { $0.accountId == accountId }
                    .flatMap { $0.tracks }
                    .map(\.googleFileId)
            )
        )

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
    var coverSize: CGFloat = 148

    private var subtitle: String {
        let trimmedArtist = album.artistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedArtist.isEmpty ? "Unknown Artist" : trimmedArtist
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AlbumArtworkThumbnail(album: album, size: coverSize)

            VStack(alignment: .leading, spacing: 0) {
                Text(album.name)
                    // Medium, matching the list and arrange rows. Geist ships a
                    // drawn Medium cut, so this is a real weight rather than a
                    // synthesised one.
                    .font(.uiSubheadline.weight(.medium))
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
        .frame(width: coverSize)
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
