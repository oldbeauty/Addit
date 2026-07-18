import SwiftUI
import SwiftData
import UIKit
import AVFoundation
import PhotosUI

struct AlbumDetailView: View {
    let album: Album
    /// Enter inline edit mode as soon as the tracklist is loaded — used by
    /// library flows that used to present the (now removed) edit sheet:
    /// context-menu Edit and freshly created/imported albums.
    var startInEditMode: Bool = false
    @Environment(AudioPlayerService.self) var playerService
    @Environment(CloudServiceRouter.self) var cloudRouter
    @Environment(CloudAuthCoordinator.self) var authService

    /// Drive client for whichever provider hosts this album — every
    /// existing `driveService.…` call body works unchanged through this.
    var driveService: any CloudDriveService {
        cloudRouter.service(for: album)
    }
    @Environment(AlbumArtService.self) var albumArtService
    @Environment(ThemeService.self) var themeService
    @Environment(AudioCacheService.self) var cacheService
    @Environment(\.modelContext) var modelContext
    @Environment(\.dismiss) var dismiss
    @AppStorage("storageSource") var storageSource: String = StorageSource.googleDrive.rawValue
    @State private var isSyncing = true
    @State var cachedTrackIds: Set<String> = []
    @State private var syncError: String?
    @State private var showSharingSheet = false
    @State private var navigateToChat = false
    @State var albumImage: UIImage?
    @State private var queuedTrackId: String?
    @State var displayItems: [TracklistItem] = []
    @State var showToolbarActions = false
    @State private var toolbarActionGeneration = 0
    @State var shareFileURL: URL?
    @State var isExportingAlbum = false
    /// Duration (seconds) per track, keyed by `track.googleFileId`. Populated
    /// by `calculateAlbumDuration()` from cached / on-disk audio files. Used
    /// for both the album total and per-disc totals.
    @State private var trackDurations: [String: Double] = [:]
    @State var isSavingToLocal = false
    @State var saveProgress: (current: Int, total: Int, trackName: String) = (0, 0, "")
    @State private var showDriveFolderPicker = false
    @State var isSavingToDrive = false
    @State var uploadProgress: (current: Int, total: Int, trackName: String) = (0, 0, "")
    @State var saveToDriveError: String?
    @State private var trackToSplit: Track?

    // MARK: Inline edit mode state (behavior inherited from the old AlbumMetadataEditorSheet)

    @State var isEditing = false
    /// Working copy of `displayItems` while editing — unfiltered, so hidden
    /// tracks stay reorderable/deletable. Committed back on Save.
    @State var editItems: [TracklistItem] = []
    @State var editedTitle = ""
    @State var editedArtist = ""
    @State var editedTrackNames: [String: String] = [:]
    @State var editRenameTarget: EditRenameTarget?
    @State var editRenameText = ""
    @State var editTrackToDelete: Track?
    @State var isSavingEdits = false
    @State var editErrorMessage: String?
    @State var editAdditDataFileId: String?
    @State var editAdditDataOwnedByMe = true
    @State private var selectedCoverPhoto: PhotosPickerItem?
    @State var isUploadingCover = false
    @State var coverUploadErrorMessage: String?
    @State private var imageToCrop: CoverCropItem?
    @State var showEditDocumentPicker = false
    @State var showEditDriveAudioPicker = false
    @State var isUploadingTracks = false

    /// What the rename popup is editing — album title, artist, or one track.
    enum EditRenameTarget: Identifiable {
        case title, artist, track(Track)

        var id: String {
            switch self {
            case .title: return "title"
            case .artist: return "artist"
            case .track(let track): return "track-\(track.googleFileId)"
            }
        }
    }

    private let coverSize: CGFloat = 256

    var sortedTracks: [Track] {
        album.tracks.sorted { $0.trackNumber < $1.trackNumber }
    }

    /// Shared "dimmed background + progress card" overlay used by both the
    /// save-to-local and upload-to-cloud flows. Extracted from the body for
    /// type-checker budget (see `trackRowCell`) and to deduplicate two
    /// structurally identical overlays.
    @ViewBuilder
    private func progressCardOverlay(
        progress: (current: Int, total: Int, trackName: String),
        countPrefix: String,
        fallback: String
    ) -> some View {
        Color.black.opacity(0.3)
            .ignoresSafeArea()
            .overlay {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)

                    if progress.total > 0 {
                        Text("\(countPrefix) \(progress.current) of \(progress.total)")
                            .font(.uiSubheadline.bold())

                        Text(progress.trackName)
                            .font(.uiCaption)
                            .foregroundStyle(.secondary)
                            .fadingTruncation()

                        GeometryReader { geo in
                            let fraction = CGFloat(progress.current) / CGFloat(max(progress.total, 1))
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.primary.opacity(0.1))
                                Capsule()
                                    .fill(Color.primary.opacity(0.5))
                                    .frame(width: geo.size.width * fraction)
                                    .animation(.easeInOut(duration: 0.3), value: progress.current)
                            }
                        }
                        .frame(height: 4)
                        .padding(.horizontal, 4)
                    } else {
                        Text(fallback)
                            .font(.uiSubheadline)
                    }
                }
                .frame(width: 220)
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
    }

    /// Album header: cover art, title, artist, play buttons. Extracted
    /// from the List body for type-checker budget (see `trackRowCell`).
    // MARK: - Album cover (Teenage-Engineering-style debossed crater)

    /// Corner radii + how far the recessed plate extends past the cover.
    private var coverCorner: CGFloat { 12 }
    private var plateCorner: CGFloat { 28 }
    private var craterInset: CGFloat { 22 }

    /// The tappable artwork itself (pixel-sort interaction preserved),
    /// clipped to its rounded rect. No shadows here — the mount adds those.
    @ViewBuilder
    private var coverArtwork: some View {
        RoundedRectangle(cornerRadius: coverCorner, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [themeService.accentColor.opacity(0.6), themeService.accentColor.opacity(0.3)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: coverSize, height: coverSize)
            .overlay {
                if let albumImage {
                    // Tap to kick off a luminance-based pixel-sort
                    // animation; tap again at the sorted state to replay
                    // the log in reverse back to the original.
                    PixelSortCoverView(
                        image: albumImage,
                        size: coverSize,
                        cornerRadius: coverCorner
                    )
                } else {
                    Image(systemName: "music.note")
                        .font(.ui(48))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: coverCorner, style: .continuous))
    }

    /// The cover extruded above a debossed "crater" plate. The plate is a
    /// rounded panel carved into the surface via inner shadows (dark at the
    /// top-inner lip, faint light at the bottom lip — reads as concave under
    /// top-down light); the cover floats above it with a soft ambient
    /// shadow, a tight contact shadow, and a top rim highlight so its edge
    /// catches light like a raised physical part. Hard, precise, tactile —
    /// the OP-1 faceplate feel.
    /// The recessed plate alone — shared by the normal cover mount and the
    /// edit-mode cover (which swaps the artwork for a PhotosPicker).
    private var craterPlate: some View {
        let plateSize = coverSize + craterInset * 2
        return RoundedRectangle(cornerRadius: plateCorner, style: .continuous)
            .fill(
                Color(uiColor: .secondarySystemBackground)
                    .shadow(.inner(color: .black.opacity(0.6), radius: 7, x: 0, y: 4))
                    .shadow(.inner(color: .white.opacity(0.05), radius: 2, x: 0, y: -2))
            )
            .frame(width: plateSize, height: plateSize)
            .overlay {
                // Carved-lip edge: bright at the top, dark at the bottom.
                RoundedRectangle(cornerRadius: plateCorner, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.10), .clear, .black.opacity(0.28)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
    }

    private var craterCover: some View {
        ZStack {
            craterPlate

            coverArtwork
                .shadow(color: .black.opacity(0.55), radius: 16, x: 0, y: 12)
                .shadow(color: .black.opacity(0.40), radius: 4, x: 0, y: 3)
                .overlay {
                    // Top rim highlight on the raised part's edge.
                    RoundedRectangle(cornerRadius: coverCorner, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.18), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                }
        }
    }

    private var headerSection: some View {
        Section {
            VStack(spacing: 16) {
                if isEditing {
                    editableCraterCover
                    editTitleBlock
                    editControlsRow
                } else {
                    craterCover
                    titleBlock
                    playButtons
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    private var titleBlock: some View {
        VStack(spacing: 4) {
            Text(album.name)
                .font(.uiTitle2.bold())
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text(album.artistName ?? "Unknown Artist")
                .font(.uiSubheadline)
                .foregroundStyle(.secondary)
        }
    }

    var playButtons: some View {
        HStack(spacing: 20) {
            Button {
                playerService.playAlbum(album)
            } label: {
                Image(systemName: "play.fill")
                    .foregroundStyle(.primary)
            }
            .buttonStyle(TactileButtonStyle())

            Button {
                if isThisAlbumPlaying {
                    playerService.toggleShuffle()
                } else {
                    playerService.playAlbum(album, shuffled: true)
                }
            } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(shuffleEngaged ? themeService.accentColor.legibleForeground : .primary)
            }
            .buttonStyle(TactileButtonStyle(engaged: shuffleEngaged ? themeService.accentColor : nil))
        }
        .padding(.top, 4)
        // The artist→buttons gap is 20pt (16 VStack spacing + 4 top pad).
        // Below the buttons, the header VStack's bottom pad (8) + the first
        // row's inset (3) + row padding (8) already total 19 with section
        // spacing zeroed, so 1pt here makes the tracklist sit exactly 20pt
        // away too — buttons dead-center between artist and first track.
        .padding(.bottom, 1)
    }

    /// Edit-mode title/artist: tap to open the rename popup, like the sheet.
    /// Flat text — no engraving, no pencil — with the same fonts and line
    /// limits as `titleBlock` so both header variants measure identically.
    private var editTitleBlock: some View {
        VStack(spacing: 4) {
            Button {
                beginEditRename(.title)
            } label: {
                Text(editedTitle)
                    .font(.uiTitle2.bold())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .buttonStyle(.plain)

            Button {
                beginEditRename(.artist)
            } label: {
                Text(editedArtist.isEmpty ? "Artist" : editedArtist)
                    .font(.uiSubheadline)
                    .foregroundStyle(editedArtist.isEmpty ? .tertiary : .secondary)
            }
            .buttonStyle(.plain)
        }
    }

    /// Edit-mode cover: same crater plate, but the artwork is a PhotosPicker
    /// with the sheet's dashed "tap to replace" ring. The pixel-sort tap
    /// interaction is swapped out so the tap goes to the picker.
    private var editableCraterCover: some View {
        ZStack {
            craterPlate

            PhotosPicker(selection: $selectedCoverPhoto, matching: .images) {
                editCoverArtwork
            }
            .buttonStyle(.plain)
            .disabled(isUploadingCover)
        }
        .onChange(of: selectedCoverPhoto) { _, newValue in
            guard let newValue else { return }
            Task {
                guard let data = try? await newValue.loadTransferable(type: Data.self),
                      let loaded = UIImage(data: data) else {
                    coverUploadErrorMessage = "The selected photo couldn't be loaded."
                    selectedCoverPhoto = nil
                    return
                }
                selectedCoverPhoto = nil
                imageToCrop = CoverCropItem(image: loaded)
            }
        }
        .alert(
            "Couldn't Change Album Cover",
            isPresented: Binding(
                get: { coverUploadErrorMessage != nil },
                set: { if !$0 { coverUploadErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(coverUploadErrorMessage ?? "")
        }
        .fullScreenCover(item: $imageToCrop) { item in
            ImageCropperView(
                image: item.image,
                onCropped: { croppedImage in
                    imageToCrop = nil
                    Task { await uploadEditCroppedCover(croppedImage) }
                },
                onCancelled: {
                    imageToCrop = nil
                }
            )
        }
    }

    private var editCoverArtwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: coverCorner, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [themeService.accentColor.opacity(0.6), themeService.accentColor.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: coverSize, height: coverSize)
                .overlay {
                    if let albumImage {
                        Image(uiImage: albumImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "music.note")
                            .font(.ui(48))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: coverCorner, style: .continuous))
                .padding(4)
                .overlay {
                    RoundedRectangle(cornerRadius: coverCorner + 2, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .foregroundStyle(.secondary.opacity(0.6))
                }

            if isUploadingCover {
                RoundedRectangle(cornerRadius: coverCorner, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(width: coverSize, height: coverSize)
                ProgressView()
            }
        }
    }

    /// Track list + album duration footer. Extracted from the List body
    /// for type-checker budget (see `trackRowCell`).
    var tracksSection: some View {
        Section {
            ForEach(Array(filteredDisplayItems.enumerated()), id: \.element.id) { index, item in
                switch item {
                case .track(let track):
                    trackRowCell(for: track)
                case .discMarker(_, let label):
                    let discSeconds = discDurationSeconds(forMarkerAt: index)
                    DiscMarkerRow(
                        label: label,
                        duration: discSeconds > 0 ? formatDuration(discSeconds) : nil
                    )
                    .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }

            if albumDurationSeconds > 0 {
                HStack {
                    Spacer()
                    // Display layer (Phosphor): the album total is a readout.
                    Text(formattedAlbumDuration)
                        .font(.readout(11))
                        .foregroundStyle(Phosphor.dim)
                        .phosphorGlow(intensity: 0.4)
                }
                // Trailing inset = TrackRow's 8pt row inset + the
                // ~7pt gap between the "…" glyph's right edge and
                // its 32pt frame's right edge (SF subheadline
                // `ellipsis` glyph is ≈18pt wide, centered in 32).
                // This aligns the duration text's right edge with
                // the visible right edge of each row's ellipsis.
                .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 8, trailing: 15))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
    }

    /// Ellipsis dropdown panel, extracted from the body's overlay for the
    /// same type-checker-budget reason as `trackRowCell` / `initialLoad`.
    private var toolbarActionsPanel: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if !album.isLocal {
                Button {
                    showSharingSheet = true
                    withAnimation { showToolbarActions = false }
                } label: {
                    Label("Sharing", systemImage: "person.2")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                // Chat rides on the Drive comments API, which OneDrive
                // has no equivalent for — hidden for OneDrive albums.
                if driveService.supportsComments {
                    Divider()

                    Button {
                        navigateToChat = true
                        withAnimation { showToolbarActions = false }
                    } label: {
                        Label("Chat", systemImage: "bubble.left")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                Divider()
            }

            Button {
                enterEditMode()
            } label: {
                Label("Edit", systemImage: "pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if !album.isLocal {
                Divider()

                Button {
                    toggleAllCache()
                    withAnimation { showToolbarActions = false }
                } label: {
                    Label(
                        allTracksCached ? "Remove Offline Access" : "Make Available Offline",
                        systemImage: allTracksCached ? "xmark.circle" : "arrow.down.circle"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            if hasHiddenTracks {
                Divider()

                Button {
                    withAnimation { album.showHiddenTracks.toggle() }
                    try? modelContext.save()
                    withAnimation { showToolbarActions = false }
                } label: {
                    Label(album.showHiddenTracks ? "Hide Hidden Tracks" : "Show Hidden Tracks",
                          systemImage: album.showHiddenTracks ? "eye.slash" : "eye")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            Divider()

            Button {
                exportAlbum()
                withAnimation { showToolbarActions = false }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if !album.isLocal {
                Divider()

                Button {
                    withAnimation { showToolbarActions = false }
                    Task { await saveToLocalLibrary() }
                } label: {
                    Label("Save to Local Library", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            if album.isLocal {
                Divider()

                Button {
                    withAnimation { showToolbarActions = false }
                    showDriveFolderPicker = true
                } label: {
                    Label("Save to \(authService.activeProvider.displayName) Library",
                          systemImage: "icloud.and.arrow.up")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 230)
        .glassPane(cornerRadius: 14)
        .padding(.trailing, 16)
        .padding(.top, 4)
        .transition(.opacity.combined(with: .scale(scale: 0.5, anchor: .topTrailing)))
    }

    /// Track row + its full modifier chain, extracted from the List body.
    /// Keeping this inline made the body expression exceed the
    /// type-checker's budget after the CloudDriveService refactor (the
    /// body was already near the cliff; see also `initialLoad`).
    @ViewBuilder
    private func trackRowCell(for track: Track) -> some View {
        TrackRow(
            track: track,
            number: trackNumbers[track.googleFileId] ?? 0,
            isCurrentTrack: playerService.currentTrack?.googleFileId == track.googleFileId,
            isPlaying: playerService.currentTrack?.googleFileId == track.googleFileId && playerService.isPlaying,
            isCached: track.isLocal || cachedTrackIds.contains(track.googleFileId),
            isLocal: album.isLocal,
            onToggleCache: {
                toggleCache(for: track)
            },
            onDownload: {
                exportTrack(track)
            },
            onToggleHidden: {
                track.isHidden.toggle()
                try? modelContext.save()
            },
            onSplit: splitAction(for: track)
        )
        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
        .listRowBackground(Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if track.isHidden {
                // Play the hidden track solo — don't add it to the album queue
                playerService.playTrack(track, inQueue: [track])
            } else {
                playerService.playTrack(track, inQueue: playableTracks)
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                playerService.addToQueue(track)
                queuedTrackId = track.googleFileId
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if queuedTrackId == track.googleFileId {
                        queuedTrackId = nil
                    }
                }
            } label: {
                Label("Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            .tint(themeService.accentColor)
        }
        .overlay(alignment: .trailing) {
            if queuedTrackId == track.googleFileId {
                Text("Queued")
                    .font(.uiCaption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(themeService.accentColor, in: Capsule())
                    .transition(.opacity.combined(with: .scale))
                    .padding(.trailing, 8)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: queuedTrackId)
    }

    /// Split is only offered where the result can be saved back: local
    /// albums always, cloud albums only with write access.
    private func splitAction(for track: Track) -> (() -> Void)? {
        guard album.isLocal || album.canEdit else { return nil }
        return { trackToSplit = track }
    }

    /// Rebuild the display list for a LOCAL album from its cached
    /// tracklist (or from scratch when none exists).
    private func rebuildLocalDisplayItems() {
        let allTracks = fetchAllTracks()
        if !album.cachedTracklist.isEmpty {
            buildDisplayItems(from: AdditMetadata(tracklist: album.cachedTracklist), tracks: allTracks)
        } else {
            buildDisplayItems(from: nil, tracks: allTracks)
        }
    }

    /// Body of the view's initial `.task` — extracted (like the other
    /// lifecycle closures below) because keeping the logic inline pushed
    /// the body expression past the type-checker's budget once
    /// `driveService` became an `any CloudDriveService` existential.
    private func initialLoad() async {
        if album.isLocal {
            isSyncing = false
            rebuildLocalDisplayItems()
        } else {
            await syncFromDrive()
        }
        refreshCachedState()
        // Library flows land here with edit mode pre-armed — enter it only
        // after the tracklist is loaded so `enterEditMode` seeds from
        // fresh display items.
        if startInEditMode && !isEditing {
            enterEditMode()
        }
    }

    /// Rebuilds the tracklist after out-of-band changes — a track split,
    /// or edits applied immediately (deletes/adds) before a Cancel.
    func refreshTracklist() {
        if album.isLocal {
            if !album.cachedTracklist.isEmpty {
                buildDisplayItems(from: AdditMetadata(tracklist: album.cachedTracklist))
            } else {
                buildDisplayItems(from: nil)
            }
        } else {
            Task { await syncFromDrive() }
        }
    }

    /// Fetches tracks directly from the model context, bypassing the potentially stale relationship
    private func fetchAllTracks() -> [Track] {
        let folderId = album.googleFolderId
        let acctId = album.accountId
        let descriptor = FetchDescriptor<Track>(
            predicate: #Predicate { $0.album?.googleFolderId == folderId && $0.album?.accountId == acctId },
            sortBy: [SortDescriptor(\.trackNumber)]
        )
        return (try? modelContext.fetch(descriptor)) ?? album.tracks.sorted { $0.trackNumber < $1.trackNumber }
    }

    private var filteredDisplayItems: [TracklistItem] {
        if album.showHiddenTracks { return displayItems }
        return displayItems.filter {
            if case .track(let track) = $0 { return !track.isHidden }
            return true
        }
    }

    private var playableTracks: [Track] {
        displayItems.compactMap(\.asTrack).filter { !$0.isHidden }
    }

    private var albumDurationSeconds: Double {
        trackDurations.values.reduce(0, +)
    }

    private var albumDurationMinutes: Int {
        Int((albumDurationSeconds / 60).rounded())
    }

    /// Format a duration in seconds as H:MM:SS (or M:SS if under an hour).
    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }

    /// Exact album length as H:MM:SS (or M:SS if under an hour).
    private var formattedAlbumDuration: String {
        formatDuration(albumDurationSeconds)
    }

    /// Sum of durations for the tracks visually grouped under the disc
    /// marker at `markerIndex` in `filteredDisplayItems` — i.e. every track
    /// between this marker and the next (or end of list). Tracks whose
    /// duration hasn't been measured yet (e.g. uncached Drive tracks) are
    /// skipped; the caller should treat a zero return as "unavailable."
    private func discDurationSeconds(forMarkerAt markerIndex: Int) -> Double {
        let items = filteredDisplayItems
        guard markerIndex < items.count else { return 0 }
        var total: Double = 0
        for i in (markerIndex + 1)..<items.count {
            switch items[i] {
            case .discMarker:
                return total
            case .track(let track):
                if let d = trackDurations[track.googleFileId] { total += d }
            }
        }
        return total
    }

    private var hasHiddenTracks: Bool {
        displayItems.contains { if case .track(let t) = $0 { return t.isHidden } else { return false } }
    }

    /// Pre-computed track numbers keyed by track's googleFileId, avoiding O(n²) per-row filtering.
    private var trackNumbers: [String: Int] {
        var numbers: [String: Int] = [:]
        var count = 0
        for item in displayItems {
            if case .track(let track) = item {
                count += 1
                numbers[track.googleFileId] = count
            }
        }
        return numbers
    }

    private var artworkTaskID: String? {
        let refreshMarker = albumArtService.lastUpdatedAlbumFolderId == album.googleFolderId
            ? albumArtService.artworkRefreshVersion
            : 0
        return "\(album.coverArtTaskID)-\(refreshMarker)-\(album.localCoverPath ?? "")"
    }

    private var isThisAlbumPlaying: Bool {
        playerService.currentTrack?.album?.googleFolderId == album.googleFolderId
    }

    /// Shuffle button reads as "engaged" only while this album is the one
    /// playing AND shuffle is on.
    private var shuffleEngaged: Bool {
        isThisAlbumPlaying && playerService.isShuffleOn
    }

    // `body` is assembled in stages (list → chrome → presentations → body)
    // so no single expression exceeds the type-checker's budget.
    private var listLayer: some View {
        List {
            if isSyncing && album.tracks.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Syncing from Drive...")
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                headerSection
                if isEditing {
                    editTracksSection
                } else {
                    tracksSection
                }

                if let syncError {
                    Section {
                        Label(syncError, systemImage: "exclamationmark.triangle")
                            .font(.uiCaption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .appBackground()
        .listSectionSpacing(0)
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isEditing)
    }

    private var chromeLayer: some View {
        listLayer
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancelEdits() }
                        .disabled(isSavingEdits)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSavingEdits {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task { await saveEdits() }
                        }
                        .disabled(editedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } else {
                // Album-download progress indicator. Visible only while a
                // "Make Available Offline" run is in flight — appears the
                // moment `saveProgress.total` becomes non-zero and disappears
                // again when the download finishes (the existing flow resets
                // `saveProgress` to `(0, 0, "")`). Placed before the ellipsis
                // so it renders to the left of it in the trailing toolbar
                // group.
                ToolbarItem(placement: .primaryAction) {
                    if let progress = cacheService.albumCacheProgress[album.googleFolderId],
                       progress.total > 0 {
                        Button {
                            // Intentionally a no-op for now — the button is
                            // here as a visual progress affordance. Hooking
                            // it up to "cancel download" / "show details"
                            // is a one-line change later.
                        } label: {
                            DownloadProgressRing(
                                progress: Double(progress.current) /
                                    Double(max(progress.total, 1))
                            )
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showToolbarActions.toggle()
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25),
                   value: cacheService.albumCacheProgress[album.googleFolderId] != nil)
        .simultaneousGesture(
            showToolbarActions
                ? TapGesture().onEnded {
                    withAnimation(.easeIn(duration: 0.2)) { showToolbarActions = false }
                }
                : nil
        )
        .simultaneousGesture(
            showToolbarActions
                ? DragGesture(minimumDistance: 5).onChanged { _ in
                    withAnimation(.easeIn(duration: 0.2)) { showToolbarActions = false }
                }
                : nil
        )
        .overlay(alignment: .topTrailing) {
            if showToolbarActions {
                toolbarActionsPanel
            }
        }
        .overlay {
            if isSavingToLocal {
                progressCardOverlay(
                    progress: saveProgress,
                    countPrefix: "Track",
                    fallback: "Saving..."
                )
            }
        }
        .overlay {
            if isSavingToDrive {
                progressCardOverlay(
                    progress: uploadProgress,
                    countPrefix: "Uploading",
                    fallback: "Uploading..."
                )
            }
        }
    }

    private var presentationLayer: some View {
        chromeLayer
        .sheet(isPresented: $showSharingSheet) {
            SharingSheet(album: album)
        }
        .sheet(isPresented: $showDriveFolderPicker) {
            ChooseDriveFolderSheet { parentId, markStarred in
                showDriveFolderPicker = false
                Task { await saveToGoogleDrive(parentId: parentId, markStarred: markStarred) }
            }
            .environment(cloudRouter)
            .environment(authService)
        }
        .alert("Upload Failed", isPresented: Binding(
            get: { saveToDriveError != nil },
            set: { if !$0 { saveToDriveError = nil } }
        )) {
            Button("OK") { saveToDriveError = nil }
        } message: {
            Text(saveToDriveError ?? "")
        }
        .navigationDestination(isPresented: $navigateToChat) {
            ChatView(album: album)
        }
        .sheet(isPresented: Binding(
            get: { shareFileURL != nil },
            set: { if !$0 {
                // Discard the transient temp file once sharing is done so a
                // "send only" leaves nothing behind. (If it was a hardlink to
                // the cache, this just drops the extra link, not the bytes.)
                if let url = shareFileURL {
                    try? FileManager.default.removeItem(at: url)
                }
                shareFileURL = nil
            } }
        )) {
            if let url = shareFileURL {
                ShareSheet(activityItems: [url])
            }
        }
        .fullScreenCover(item: $trackToSplit, onDismiss: refreshTracklist) { splitTrack in
            TrackSplitView(track: splitTrack, album: album)
                .environment(cloudRouter)
                .environment(cacheService)
                .environment(themeService)
                .environment(playerService)
        }
    }

    var body: some View {
        presentationLayer
        .refreshable {
            // A pull-to-refresh mid-edit would clobber the working copy
            // with a fresh sync — ignored until the user saves or cancels.
            if !isEditing {
                await syncFromDrive()
            }
        }
        .task {
            await initialLoad()
        }
        .task(id: "\(playableTracks.map(\.googleFileId))") {
            await calculateAlbumDuration()
        }
        .onChange(of: album.tracks.count) {
            if album.isLocal {
                rebuildLocalDisplayItems()
            }
        }
        .onChange(of: playerService.currentTrack?.googleFileId) {
            refreshCachedState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .audioCacheDidChange)) { _ in
            refreshCachedState()
            // The album/disc duration readout is computed by probing each
            // track's local/cached audio file. When cache state flips, that
            // set changes, so recompute so the header updates immediately
            // instead of waiting for the view to re-enter.
            Task { await calculateAlbumDuration() }
        }
        .task(id: artworkTaskID) {
            if album.isLocal {
                if let coverPath = album.resolvedLocalCoverPath {
                    albumImage = UIImage(contentsOfFile: coverPath)
                }
            } else {
                let resolution = await albumArtService.resolveAlbumArt(for: album)
                albumImage = resolution.image
                albumArtService.applyResolution(resolution, to: album, modelContext: modelContext)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if playerService.currentTrack != nil {
                Color.clear.frame(height: 64)
            }
        }
    }

    // MARK: - Cache

    private var allTracksCached: Bool {
        !album.tracks.isEmpty && cachedTrackIds.count == album.tracks.count
    }

    private func toggleAllCache() {
        if allTracksCached {
            for track in album.tracks {
                cacheService.removeTrack(track)
            }
            cachedTrackIds.removeAll()
        } else {
            // Skip if a cache run is already in flight for this album
            // — protects against a second tap spawning a duplicate Task
            // (which would also corrupt the progress ring's count).
            guard cacheService.albumCacheProgress[album.googleFolderId] == nil else {
                return
            }

            // Snapshot what we're about to download up front so the
            // progress ring's denominator is fixed for the whole run.
            let pending = album.tracks.filter {
                !cachedTrackIds.contains($0.googleFileId)
            }
            guard !pending.isEmpty else { return }

            // Progress lives on the service, not on the view. That way
            // it survives the view being torn down when the user
            // navigates away — they can pop back into the album mid-
            // download and the toolbar ring picks up exactly where it
            // left off.
            let folderId = album.googleFolderId
            cacheService.albumCacheProgress[folderId] = .init(
                current: 0, total: pending.count
            )
            Task {
                defer {
                    // Always clear the entry on completion (success or
                    // error). On the main actor so the toolbar
                    // animation hooks fire on the right thread.
                    Task { @MainActor in
                        cacheService.albumCacheProgress[folderId] = nil
                    }
                }
                for track in pending {
                    do {
                        _ = try await cacheService.cacheTrack(track)
                        cachedTrackIds.insert(track.googleFileId)
                    } catch {
                        // Skip failed tracks; still count toward
                        // progress so the ring doesn't stall.
                    }
                    if var p = cacheService.albumCacheProgress[folderId] {
                        p.current += 1
                        cacheService.albumCacheProgress[folderId] = p
                    }
                }
            }
        }
    }

    private func calculateAlbumDuration() async {
        var durations: [String: Double] = [:]
        for track in playableTracks {
            if let url = track.localFileURL ?? cacheService.cachedFileURL(for: track) {
                if let file = try? AVAudioFile(forReading: url) {
                    durations[track.googleFileId] = Double(file.length) / file.processingFormat.sampleRate
                }
            }
        }
        trackDurations = durations
    }

    private func refreshCachedState() {
        cachedTrackIds = Set(
            album.tracks
                .filter { cacheService.cachedFileURL(for: $0) != nil }
                .map(\.googleFileId)
        )
    }

    private func toggleCache(for track: Track) {
        if cachedTrackIds.contains(track.googleFileId) {
            cacheService.removeTrack(track)
            cachedTrackIds.remove(track.googleFileId)
        } else {
            Task {
                do {
                    _ = try await cacheService.cacheTrack(track)
                    cachedTrackIds.insert(track.googleFileId)
                } catch {
                    // Download failed silently
                }
            }
        }
    }

    // MARK: - Sync

    private func syncFromDrive() async {
        // Safety: never sync local albums against Drive
        guard !album.isLocal, !album.googleFolderId.hasPrefix("local_") else {
            isSyncing = false
            if !album.cachedTracklist.isEmpty {
                buildDisplayItems(from: AdditMetadata(tracklist: album.cachedTracklist))
            } else {
                buildDisplayItems(from: nil)
            }
            return
        }

        isSyncing = true
        syncError = nil
        defer { isSyncing = false }

        // Show existing tracks (with cached disc markers) immediately while syncing
        if displayItems.isEmpty && !album.tracks.isEmpty {
            if !album.cachedTracklist.isEmpty {
                buildDisplayItems(from: AdditMetadata(tracklist: album.cachedTracklist))
            } else {
                displayItems = sortedTracks.map { .track($0) }
            }
        }

        do {
            // Refresh folder name and permissions from Drive
            if let folderInfo = try? await driveService.getFileMetadata(fileId: album.googleFolderId) {
                album.name = folderInfo.name
                album.canEdit = folderInfo.canEdit
                album.isFolderOwner = folderInfo.ownedByMe ?? false
            }

            let response = try await driveService.listAudioFiles(inFolder: album.googleFolderId)
            let driveFiles = response.files
            let driveIds = Set(driveFiles.map(\.id))
            let localIds = Set(album.tracks.map(\.googleFileId))

            // Remove tracks that no longer exist on Drive
            for track in album.tracks where !driveIds.contains(track.googleFileId) {
                modelContext.delete(track)
            }

            // Add new tracks from Drive
            for (index, file) in driveFiles.enumerated() where !localIds.contains(file.id) {
                let track = Track(
                    googleFileId: file.id,
                    name: file.name,
                    album: album,
                    mimeType: file.mimeType,
                    fileSize: file.fileSizeBytes,
                    trackNumber: index + 1,
                    modifiedTime: file.modifiedTime
                )
                modelContext.insert(track)
            }

            // Update names and file sizes for existing tracks
            for file in driveFiles {
                if let existing = album.tracks.first(where: { $0.googleFileId == file.id }) {
                    existing.name = file.name
                    existing.modifiedTime = file.modifiedTime
                    if let size = file.fileSizeBytes {
                        existing.fileSize = size
                    }
                }
            }

            // Sync addit metadata (tracklist ordering + artist name)
            await syncAdditMetadata(driveFiles: driveFiles)

            // Sync JPEG cover art metadata
            await syncCoverArtMetadata()

            album.trackCount = driveFiles.count
            try? modelContext.save()
        } catch {
            syncError = "Couldn't sync: \(error.localizedDescription)"
        }
    }

    private func syncAdditMetadata(driveFiles: [DriveItem]) async {
        var metadata: AdditMetadata?

        // Try .addit-data (JSON) first
        do {
            if let item = try await driveService.findFile(named: ".addit-data", inFolder: album.googleFolderId) {
                album.additDataFileId = item.id
                let data = try await driveService.downloadFileData(fileId: item.id)
                metadata = try? JSONDecoder().decode(AdditMetadata.self, from: data)
            }
        } catch {
            // Fall through to legacy
        }

        // Legacy fallback: read .addit-tracklist and .addit-artist separately
        if metadata == nil {
            var legacy = AdditMetadata()

            if let item = try? await driveService.findFile(named: ".addit-tracklist", inFolder: album.googleFolderId),
               let data = try? await driveService.downloadFileData(fileId: item.id),
               let content = String(data: data, encoding: .utf8) {
                legacy.tracklist = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
            }

            if let item = try? await driveService.findFile(named: ".addit-artist", inFolder: album.googleFolderId),
               let data = try? await driveService.downloadFileData(fileId: item.id),
               let content = String(data: data, encoding: .utf8) {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                legacy.artist = trimmed.isEmpty ? nil : trimmed
            }

            if legacy.tracklist != nil || legacy.artist != nil {
                metadata = legacy
            }
        }

        // Apply artist name
        if let metadata {
            if let artist = metadata.artist {
                album.artistName = artist.isEmpty ? nil : artist
            }
        }

        // Apply track ordering (skip disc markers)
        if let orderedNames = metadata?.tracklist, !orderedNames.isEmpty {
            var trackNumber = 1

            for name in orderedNames {
                if name.hasPrefix(AdditMetadata.discMarkerPrefix) { continue }
                if let track = album.tracks.first(where: { $0.name == name }) {
                    track.trackNumber = trackNumber
                    trackNumber += 1
                }
            }

            let listedNames = Set(orderedNames.filter { !$0.hasPrefix(AdditMetadata.discMarkerPrefix) })
            let unlistedTracks = album.tracks
                .filter { !listedNames.contains($0.name) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            for track in unlistedTracks {
                track.trackNumber = trackNumber
                trackNumber += 1
            }
        } else {
            // Default: order from Drive API response
            for (index, file) in driveFiles.enumerated() {
                if let track = album.tracks.first(where: { $0.googleFileId == file.id }) {
                    track.trackNumber = index + 1
                }
            }
        }

        // Build display items with disc markers interleaved
        buildDisplayItems(from: metadata)

        // Cache tracklist for instant display on next visit
        album.cachedTracklist = metadata?.tracklist ?? []
    }

    private func buildDisplayItems(from metadata: AdditMetadata?, tracks: [Track]? = nil) {
        let allTracks = tracks ?? album.tracks.sorted { $0.trackNumber < $1.trackNumber }
        guard let orderedNames = metadata?.tracklist, !orderedNames.isEmpty else {
            displayItems = allTracks.map { .track($0) }
            return
        }

        var items: [TracklistItem] = []
        var matchedIds = Set<String>()

        for name in orderedNames {
            if name.hasPrefix(AdditMetadata.discMarkerPrefix) {
                let label = String(name.dropFirst(AdditMetadata.discMarkerPrefix.count))
                items.append(.discMarker(id: UUID(), label: label))
            } else if let track = allTracks.first(where: { $0.name == name && !matchedIds.contains($0.googleFileId) }) {
                items.append(.track(track))
                matchedIds.insert(track.googleFileId)
            }
        }

        // Append any tracks not in the tracklist
        let unmatched = allTracks
            .filter { !matchedIds.contains($0.googleFileId) }
        for track in unmatched {
            items.append(.track(track))
        }

        displayItems = items
    }

    private func syncCoverArtMetadata() async {
        do {
            let coverItem = try await driveService.findCoverImage(inFolder: album.googleFolderId)

            if let coverItem {
                let fileIdChanged = album.coverFileId != coverItem.id
                let contentChanged = coverItem.modifiedTime != nil && coverItem.modifiedTime != album.coverModifiedTime

                if fileIdChanged || contentChanged {
                    // Invalidate cached image so it gets re-downloaded with fresh content
                    if let oldId = album.coverFileId {
                        albumArtService.invalidateImage(for: oldId)
                    }
                    if fileIdChanged {
                        albumArtService.invalidateImage(for: coverItem.id)
                    }
                }

                album.coverFileId = coverItem.id
                album.coverMimeType = coverItem.mimeType
                album.coverModifiedTime = coverItem.modifiedTime
                album.coverUpdatedAt = .now
            } else {
                if let oldId = album.coverFileId {
                    albumArtService.invalidateImage(for: oldId)
                }
                album.coverFileId = nil
                album.coverMimeType = nil
                album.coverModifiedTime = nil
                album.coverUpdatedAt = nil
            }
        } catch {
            // Keep existing cover metadata on error
        }
    }
}

