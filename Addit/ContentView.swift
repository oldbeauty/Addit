import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(CloudAuthCoordinator.self) private var authService
    @Environment(AudioPlayerService.self) private var playerService
    @Environment(ThemeService.self) private var themeService
    @Environment(CloudServiceRouter.self) private var cloudRouter
    @Environment(ShareLinkService.self) private var shareLinks
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @State private var libraryPath: [Album] = []
    /// Non-empty while the "which account?" picker is up for an incoming link.
    @State private var shareAccountChoices: [Account] = []
    /// "Use without an account" — the library opens on iPhone Storage with no
    /// cloud session. Sticky, so a relaunch doesn't dump the user back on the
    /// sign-in screen; the account menu is still how you sign in later.
    @AppStorage(AppStorageKey.usesLocalOnly) private var usesLocalOnly = false
    /// The first-run intro has been read through to its last card.
    @AppStorage(AppStorageKey.hasSeenWelcomeIntro) private var hasSeenWelcomeIntro = false
    @State private var showWelcomeIntro = false

    /// Whether the library — as opposed to the splash or the sign-in screen —
    /// is the branch on screen. Named rather than inlined because the intro's
    /// trigger has to agree with `body` about this exactly: a copy of the
    /// condition would eventually drift, and the failure it drifts into is the
    /// intro appearing over the loading splash.
    private var isShowingLibrary: Bool {
        !authService.isRestoringSession
            && !authService.isSwitchingAccount
            && (authService.isSignedIn || usesLocalOnly)
    }

    var body: some View {
        Group {
            if authService.isRestoringSession || authService.isSwitchingAccount {
                LoadingSplashView()
            } else if isShowingLibrary {
                ZStack(alignment: .bottom) {
                    NavigationStack(path: $libraryPath) {
                        LibraryView(libraryPath: $libraryPath)
                            .flatSlideNavigation()
                    }

                    if playerService.currentTrack != nil && !playerService.hideNowPlayingBar {
                        // Mini and full player are one view: the pill owns
                        // both states and expands in place, so there's no
                        // presentation for this level to drive.
                        NowPlayingPill(onOpenAlbum: { album in
                            // Push the album onto the library stack *before*
                            // the pill collapses, so the album view is already
                            // behind the shrinking card. If the album already
                            // sits on top of the stack (user was viewing it
                            // before opening the player), skip the push so
                            // "tap cover" just returns there instead of
                            // stacking a duplicate.
                            if libraryPath.last != album {
                                libraryPath.append(album)
                            }
                        })
                        // The pill is pinned to the bottom of the window and has
                        // no text input of its own, so it has no business moving
                        // for a keyboard — and letting it move is what allowed it
                        // to get *stuck* mid-screen.
                        //
                        // Collapsing the library's search bar removes its
                        // `TextField` from the hierarchy in the same transaction
                        // that clears focus, so the responder disappears instead
                        // of resigning and the keyboard's frame change can fail to
                        // unwind the safe-area inset. Rather than trying to make
                        // that reset reliable — it depends on ordering inside
                        // SwiftUI — the pill simply never reads the inset, so
                        // there is no raised position for it to be stranded in.
                        // The library itself keeps normal keyboard avoidance, so
                        // the search field is still lifted clear.
                        .ignoresSafeArea(.keyboard, edges: .bottom)
                    }
                }
            } else {
                SignInView()
            }
        }
        // Both link overlays are attached *above* `.tint` and the font
        // default, not below them. A modifier only reaches what it wraps, and
        // an overlay added after `.tint` is outside it — which is how the
        // spinner in these two ended up drawing in the system's blue instead
        // of the theme accent it takes from the environment.
        .overlay {
            if shareLinks.isImporting {
                sharedAlbumProgress
            }
        }
        // Outgoing links, from every button that isn't inside a sheet — see
        // `ShareLinkService.isPreparingLink` for why it isn't the caller's job.
        .overlay {
            if shareLinks.isPreparingLink {
                PreparingLinkOverlay()
            }
        }
        // First run. Attached here with the other overlays and above `.tint`
        // so the card's accent button reads the themed tint, not the system's.
        .welcomeIntro(isPresented: $showWelcomeIntro) { hasSeenWelcomeIntro = true }
        // Watches the whole condition, not just arrival at the library, so
        // clearing the flag from Settings brings the intro back without a
        // relaunch. `initial: true` covers the launch that restores a session,
        // where the library can be the first branch drawn with no change to
        // observe.
        .onChange(of: isShowingLibrary && !hasSeenWelcomeIntro, initial: true) { _, due in
            if due { showWelcomeIntro = true }
        }
        .tint(themeService.accentColor)
        // Default UI font for any text without an explicit .font() — routes
        // through the same appFamily knob as the ui* tokens (Phosphor.swift).
        .environment(\.font, .uiBody)
        .preferredColorScheme(themeService.effectiveColorScheme)
        // Bridge SwiftUI's effective colorScheme into ThemeService so
        // its `accentColor` computed property knows which per-scheme
        // hex to return. Run on first appearance (so the very first
        // frame uses the right color) and on every change after that
        // (so flipping system dark/light or changing the in-app
        // Appearance picker swaps the accent immediately).
        .onAppear { themeService.currentScheme = colorScheme }
        .onChange(of: colorScheme) { _, newValue in
            themeService.currentScheme = newValue
        }
        // Keyed on the account as well as the request: a link tapped while
        // signed out is held rather than failed, and signing in is what makes
        // it runnable. `ContentView` is rebuilt on an account change, so this
        // re-runs then with the request still waiting in the service.
        .task(id: SharedLinkKey(
            request: shareLinks.request?.id,
            account: authService.userEmail,
            chosen: shareLinks.chosenAccount
        )) {
            await openSharedAlbum()
        }
        .confirmationDialog(
            "Add to which account?",
            isPresented: Binding(
                get: { !shareAccountChoices.isEmpty },
                set: { if !$0 { shareAccountChoices = [] } }
            ),
            titleVisibility: .visible
        ) {
            ForEach(shareAccountChoices) { account in
                Button(account.email) {
                    shareLinks.chooseAccount(account.email)
                    shareAccountChoices = []
                }
            }
            Button("Cancel", role: .cancel) {
                shareAccountChoices = []
                shareLinks.clear()
            }
        } message: {
            Text(shareLinks.request?.link.name.map {
                "\($0) will be added to the account you pick, which also has to be the one the album was shared with."
            } ?? "The album will be added to the account you pick, which also has to be the one it was shared with.")
        }
        .alert("Can't Open Album", isPresented: .init(
            get: { shareLinks.failure != nil },
            set: { if !$0 { shareLinks.failure = nil } }
        )) {
            Button("OK", role: .cancel) { shareLinks.failure = nil }
        } message: {
            Text(shareLinks.failure ?? "")
        }
        .alert("Unable to play this audio format", isPresented: .init(
            get: { playerService.failedTrack != nil },
            set: { if !$0 { playerService.failedTrack = nil } }
        )) {
            Button("OK", role: .cancel) {
                playerService.failedTrack = nil
            }
        } message: {
            Text("This file uses an audio format that Addit doesn't support.")
        }
    }

    // MARK: - Shared album links

    /// Identity for the import task: the link, and the account it would land
    /// in. Either changing is a reason to try again.
    private struct SharedLinkKey: Equatable {
        let request: UUID?
        let account: String?
        let chosen: String?
    }

    private var sharedAlbumProgress: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                LoadingIndicator()
                Text(shareLinks.request?.link.name.map { "Opening \($0)…" } ?? "Opening album…")
                    .font(.uiSubheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
        .transition(.opacity)
    }

    /// Turns a tapped album link into an album in the library, then opens it.
    ///
    /// Deliberately quiet about the cases it can't act on yet: a link that
    /// arrives at the sign-in screen is left in the service untouched, so
    /// signing in resumes it instead of the user having to find the message
    /// again.
    private func openSharedAlbum() async {
        guard let request = shareLinks.request else { return }
        let link = request.link

        guard let provider = link.source.provider else {
            shareLinks.failure = "That link doesn't point at a cloud album."
            shareLinks.clear()
            return
        }

        guard authService.isSignedIn else {
            // Local-only is a decision, not a waiting room — there is no
            // pending sign-in to resume, so say what's needed.
            if usesLocalOnly {
                shareLinks.failure = "Sign in to \(provider.displayName) to open a shared album."
                shareLinks.clear()
            }
            return
        }

        // Which account should receive the album? The link names a cloud, but
        // not *whose* — and with two Google accounts signed in the answer is
        // not guessable: the album was shared with one specific address, and
        // picking the other one produces a permission error rather than an
        // album.
        let candidates = authService.accountManager.accounts.filter { $0.provider == provider }
        guard !candidates.isEmpty else {
            shareLinks.failure = "This album is in \(provider.displayName). Add a \(provider.displayName) account to open it."
            shareLinks.clear()
            return
        }

        let targetEmail: String
        if let chosen = shareLinks.chosenAccount {
            targetEmail = chosen
        } else if candidates.count == 1 {
            // Nothing to ask about.
            targetEmail = candidates[0].email
        } else {
            shareAccountChoices = candidates
            return
        }

        // Make the chosen account the active one. Switching rebuilds this view,
        // which re-runs the task — by then the choice is remembered in the
        // service, so it lands in the branch above rather than asking again.
        if authService.userEmail?.lowercased() != targetEmail.lowercased() {
            guard !shareLinks.didAttemptAccountSwitch else {
                shareLinks.failure = "Couldn't switch to \(targetEmail)."
                shareLinks.clear()
                return
            }
            shareLinks.markAccountSwitchAttempted()
            Task { await authService.switchAccount(to: targetEmail) }
            return
        }

        let accountId = AccountManager.storageIdentifier(for: targetEmail)
        let importer = AlbumImporter(
            driveService: cloudRouter.service(for: link.source),
            modelContext: modelContext
        )

        // Already in the library — this is the ordinary case for a link that
        // gets passed around a group chat. Just go to it.
        if let existing = importer.existingAlbum(folderId: link.folderId, accountId: accountId) {
            shareLinks.clear()
            if libraryPath.last != existing {
                libraryPath.append(existing)
            }
            playSharedTrack(link, in: existing)
            return
        }

        shareLinks.isImporting = true
        do {
            let (folder, audioFiles) = try await importer.resolve(folderId: link.folderId)
            let album = try importer.insert(
                folder: folder,
                audioFiles: audioFiles,
                accountId: accountId,
                storageSource: link.source
            )
            shareLinks.clear()
            libraryPath.append(album)
            playSharedTrack(link, in: album)
            // The album is on screen by now; this is the metadata catching up.
            await importer.finishImport(of: album, audioFiles: audioFiles)
        } catch {
            shareLinks.failure = Self.shareFailureMessage(for: error, provider: provider)
            shareLinks.clear()
        }
    }

    /// A song link opens its album and then starts on the song. Silent when the
    /// track can't be found: the folder is the source of truth and it may have
    /// been renamed or removed since the link was sent, and landing on the album
    /// is a better answer than an error about a song the sender still sees.
    private func playSharedTrack(_ link: AlbumShareLink, in album: Album) {
        guard let trackFileId = link.trackFileId else { return }
        let queue = album.tracks
            .filter { !$0.isHidden }
            .sorted { $0.trackNumber < $1.trackNumber }
        guard let track = queue.first(where: { $0.googleFileId == trackFileId }) else { return }
        playerService.playTrack(track, inQueue: queue)
    }

    /// A raw status code reads as a bug, and the obvious mapping is wrong here.
    ///
    /// Google Drive answers "you may not see this" with **404**, not 403 — it
    /// will not confirm that a file it won't show you even exists. So a 404 is
    /// far more often a permission problem than a deleted album, and reporting
    /// it as "no longer exists" sends people hunting for a folder that is
    /// sitting right where they left it. The message carries both, because the
    /// API genuinely does not distinguish them.
    private static func shareFailureMessage(for error: Error, provider: AccountProvider) -> String {
        if let driveError = error as? DriveError {
            switch driveError {
            case .forbidden, .unauthorized, .notFound:
                return "This account doesn't have access to that album, or it has been moved or deleted — "
                    + "\(provider.displayName) reports both the same way.\n\n"
                    + "If the album is yours, open it on the account that owns it and either set it to "
                    + "\"Anyone with the link\" under Access, or add this account there by email."
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
