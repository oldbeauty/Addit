import SwiftUI
import SwiftData
import UIKit
import AVFoundation

struct AlbumDetailView: View {
    let album: Album
    @Environment(AudioPlayerService.self) private var playerService
    @Environment(GoogleDriveService.self) private var driveService
    @Environment(GoogleAuthService.self) private var authService
    @Environment(AlbumArtService.self) private var albumArtService
    @Environment(ThemeService.self) private var themeService
    @Environment(AudioCacheService.self) private var cacheService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage("storageSource") private var storageSource: String = StorageSource.googleDrive.rawValue
    @State private var isSyncing = true
    @State private var cachedTrackIds: Set<String> = []
    @State private var syncError: String?
    @State private var showEditSheet = false
    @State private var showSharingSheet = false
    @State private var navigateToChat = false
    @State private var albumImage: UIImage?
    @State private var queuedTrackId: String?
    @State private var displayItems: [TracklistItem] = []
    @State private var showToolbarActions = false
    @State private var toolbarActionGeneration = 0
    @State private var shareFileURL: URL?
    @State private var isDownloadingAlbum = false
    /// Duration (seconds) per track, keyed by `track.googleFileId`. Populated
    /// by `calculateAlbumDuration()` from cached / on-disk audio files. Used
    /// for both the album total and per-disc totals.
    @State private var trackDurations: [String: Double] = [:]
    @State private var isSavingToLocal = false
    @State private var saveProgress: (current: Int, total: Int, trackName: String) = (0, 0, "")
    @State private var showDriveFolderPicker = false
    @State private var isSavingToDrive = false
    @State private var uploadProgress: (current: Int, total: Int, trackName: String) = (0, 0, "")
    @State private var saveToDriveError: String?

    private let coverSize: CGFloat = 280

    private var sortedTracks: [Track] {
        album.tracks.sorted { $0.trackNumber < $1.trackNumber }
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

    var body: some View {
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
                // Album header: cover art, title, artist, play buttons
                Section {
                    VStack(spacing: 16) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
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
                                    // Tap to kick off a luminance-based
                                    // pixel-sort animation; tap again at
                                    // the sorted state to replay the log
                                    // in reverse back to the original.
                                    PixelSortCoverView(
                                        image: albumImage,
                                        size: coverSize,
                                        cornerRadius: 12
                                    )
                                } else {
                                    Image(systemName: "music.note")
                                        .font(.system(size: 48))
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        VStack(spacing: 4) {
                            Text(album.name)
                                .font(.title2.bold())
                                .multilineTextAlignment(.center)
                                .lineLimit(2)

                            Text(album.artistName ?? "Unknown Artist")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 12) {
                            Button {
                                playerService.playAlbum(album)
                            } label: {
                                Image(systemName: "play.fill")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                if isThisAlbumPlaying {
                                    playerService.toggleShuffle()
                                } else {
                                    playerService.playAlbum(album, shuffled: true)
                                }
                            } label: {
                                Image(systemName: "shuffle")
                            }
                            .buttonStyle(.bordered)
                            .tint(isThisAlbumPlaying && playerService.isShuffleOn ? themeService.accentColor : nil)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    ForEach(Array(filteredDisplayItems.enumerated()), id: \.element.id) { index, item in
                        switch item {
                        case .track(let track):
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
                                    downloadAndShare(track: track)
                                },
                                onToggleHidden: {
                                    track.isHidden.toggle()
                                    try? modelContext.save()
                                }
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
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(themeService.accentColor, in: Capsule())
                                        .transition(.opacity.combined(with: .scale))
                                        .padding(.trailing, 8)
                                }
                            }
                            .animation(.easeInOut(duration: 0.2), value: queuedTrackId)
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
                            Text(formattedAlbumDuration)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
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

                if let syncError {
                    Section {
                        Label(syncError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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

                        Divider()
                    }

                    Button {
                        showEditSheet = true
                        withAnimation { showToolbarActions = false }
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
                        downloadAlbumAsZip()
                        withAnimation { showToolbarActions = false }
                    } label: {
                        Label("Download", systemImage: "square.and.arrow.up")
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
                            Label("Save to Google Drive Library", systemImage: "icloud.and.arrow.up")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
                .frame(width: 230)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.trailing, 16)
                .padding(.top, 4)
                .transition(.opacity.combined(with: .scale(scale: 0.5, anchor: .topTrailing)))
            }
        }
        .overlay {
            if isSavingToLocal {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .overlay {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)

                            if saveProgress.total > 0 {
                                Text("Track \(saveProgress.current) of \(saveProgress.total)")
                                    .font(.subheadline.bold())

                                Text(saveProgress.trackName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fadingTruncation()

                                GeometryReader { geo in
                                    let fraction = CGFloat(saveProgress.current) / CGFloat(max(saveProgress.total, 1))
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(Color.primary.opacity(0.1))
                                        Capsule()
                                            .fill(Color.primary.opacity(0.5))
                                            .frame(width: geo.size.width * fraction)
                                            .animation(.easeInOut(duration: 0.3), value: saveProgress.current)
                                    }
                                }
                                .frame(height: 4)
                                .padding(.horizontal, 4)
                            } else {
                                Text("Saving...")
                                    .font(.subheadline)
                            }
                        }
                        .frame(width: 220)
                        .padding(24)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
            }
        }
        .overlay {
            if isSavingToDrive {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .overlay {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)

                            if uploadProgress.total > 0 {
                                Text("Uploading \(uploadProgress.current) of \(uploadProgress.total)")
                                    .font(.subheadline.bold())

                                Text(uploadProgress.trackName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fadingTruncation()

                                GeometryReader { geo in
                                    let fraction = CGFloat(uploadProgress.current) / CGFloat(max(uploadProgress.total, 1))
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(Color.primary.opacity(0.1))
                                        Capsule()
                                            .fill(Color.primary.opacity(0.5))
                                            .frame(width: geo.size.width * fraction)
                                            .animation(.easeInOut(duration: 0.3), value: uploadProgress.current)
                                    }
                                }
                                .frame(height: 4)
                                .padding(.horizontal, 4)
                            } else {
                                Text("Uploading...")
                                    .font(.subheadline)
                            }
                        }
                        .frame(width: 220)
                        .padding(24)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
            }
        }
        .sheet(isPresented: $showSharingSheet) {
            SharingSheet(album: album)
        }
        .sheet(isPresented: $showDriveFolderPicker) {
            ChooseDriveFolderSheet { parentId, markStarred in
                showDriveFolderPicker = false
                Task { await saveToGoogleDrive(parentId: parentId, markStarred: markStarred) }
            }
            .environment(driveService)
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
            set: { if !$0 { shareFileURL = nil } }
        )) {
            if let url = shareFileURL {
                ShareSheet(activityItems: [url])
            }
        }
        .sheet(isPresented: $showEditSheet, onDismiss: {
            if album.isLocal {
                if !album.cachedTracklist.isEmpty {
                    buildDisplayItems(from: AdditMetadata(tracklist: album.cachedTracklist))
                } else {
                    buildDisplayItems(from: nil)
                }
            } else {
                Task { await syncFromDrive() }
            }
        }) {
            AlbumMetadataEditorSheet(album: album)
        }
        .refreshable {
            await syncFromDrive()
        }
        .task {
            if album.isLocal {
                isSyncing = false
                let allTracks = fetchAllTracks()
                if !album.cachedTracklist.isEmpty {
                    buildDisplayItems(from: AdditMetadata(tracklist: album.cachedTracklist), tracks: allTracks)
                } else {
                    buildDisplayItems(from: nil, tracks: allTracks)
                }
            } else {
                await syncFromDrive()
            }
            refreshCachedState()
        }
        .task(id: "\(playableTracks.map(\.googleFileId))") {
            await calculateAlbumDuration()
        }
        .onChange(of: album.tracks.count) {
            if album.isLocal {
                let allTracks = fetchAllTracks()
                if !album.cachedTracklist.isEmpty {
                    buildDisplayItems(from: AdditMetadata(tracklist: album.cachedTracklist), tracks: allTracks)
                } else {
                    buildDisplayItems(from: nil, tracks: allTracks)
                }
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

    private func downloadAlbumAsZip() {
        guard !isDownloadingAlbum else { return }
        isDownloadingAlbum = true
        Task {
            defer { isDownloadingAlbum = false }
            do {
                let fm = FileManager.default
                let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let albumDir = tempDir.appendingPathComponent(album.name)
                try fm.createDirectory(at: albumDir, withIntermediateDirectories: true)

                if album.isLocal {
                    // Copy all local tracks
                    for track in sortedTracks {
                        guard let sourceURL = track.localFileURL,
                              fm.fileExists(atPath: sourceURL.path) else { continue }
                        let destination = albumDir.appendingPathComponent(track.name)
                        try fm.copyItem(at: sourceURL, to: destination)
                    }

                    // Copy cover if present
                    if let coverPath = album.resolvedLocalCoverPath,
                       fm.fileExists(atPath: coverPath) {
                        let coverURL = albumDir.appendingPathComponent("cover.jpg")
                        try fm.copyItem(atPath: coverPath, toPath: coverURL.path)
                    }

                    // Generate .addit-data from cachedTracklist + artist
                    let metadata = AdditMetadata(
                        tracklist: album.cachedTracklist.isEmpty ? sortedTracks.map(\.name) : album.cachedTracklist,
                        artist: album.artistName
                    )
                    let additData = try JSONEncoder().encode(metadata)
                    let additURL = albumDir.appendingPathComponent(".addit-data")
                    try additData.write(to: additURL)
                } else {
                    // Download all tracks from Drive
                    for track in sortedTracks {
                        let fileURL = try await cacheService.cacheTrack(track)
                        cachedTrackIds.insert(track.googleFileId)
                        let destination = albumDir.appendingPathComponent(track.name)
                        try fm.copyItem(at: fileURL, to: destination)
                    }

                    // Download cover if present
                    if let coverFileId = album.coverFileId {
                        let coverData = try await driveService.downloadFileData(fileId: coverFileId)
                        let ext: String
                        switch album.coverMimeType {
                        case "image/png": ext = "png"
                        case "image/gif": ext = "gif"
                        case "image/webp": ext = "webp"
                        default: ext = "jpg"
                        }
                        let coverURL = albumDir.appendingPathComponent("cover.\(ext)")
                        try coverData.write(to: coverURL)
                    }

                    // Download addit-data if present
                    if let additDataId = album.additDataFileId {
                        let additData = try await driveService.downloadFileData(fileId: additDataId)
                        let additURL = albumDir.appendingPathComponent(".addit-data")
                        try additData.write(to: additURL)
                    }
                }

                // Create zip using NSFileCoordinator
                let zipURL = tempDir.appendingPathComponent("\(album.name).zip")
                let coordinator = NSFileCoordinator()
                var coordinatorError: NSError?
                var resultURL: URL?

                coordinator.coordinate(readingItemAt: albumDir, options: .forUploading, error: &coordinatorError) { tempZipURL in
                    do {
                        try fm.copyItem(at: tempZipURL, to: zipURL)
                        resultURL = zipURL
                    } catch {
                        print("Failed to copy zip: \(error)")
                    }
                }

                if let error = coordinatorError {
                    throw error
                }

                if let zipURL = resultURL {
                    shareFileURL = zipURL
                }

                // Clean up the unzipped folder
                try? fm.removeItem(at: albumDir)
            } catch {
                print("Failed to create album zip: \(error)")
            }
        }
    }

    private func saveToLocalLibrary() async {
        guard !isSavingToLocal, !album.isLocal else { return }
        await MainActor.run { isSavingToLocal = true }

        let fm = FileManager.default
        let localAlbumId = UUID().uuidString
        let albumDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalAlbums", isDirectory: true)
            .appendingPathComponent(localAlbumId, isDirectory: true)
        try? fm.createDirectory(at: albumDir, withIntermediateDirectories: true)

        // Fetch all audio files from the Drive folder (handle pagination)
        var allAudioFiles: [DriveItem] = []
        var pageToken: String? = nil
        repeat {
            do {
                let response = try await driveService.listAudioFiles(inFolder: album.googleFolderId, pageToken: pageToken)
                allAudioFiles.append(contentsOf: response.files)
                pageToken = response.nextPageToken
            } catch {
                print("[SaveToLocal] Failed to list audio files: \(error)")
                break
            }
        } while pageToken != nil

        print("[SaveToLocal] Found \(allAudioFiles.count) audio files in \(album.name)")

        // Download all audio files to disk first
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
                    saveProgress = (current: index + 1, total: allAudioFiles.count, trackName: file.name)
                }
                let data = try await driveService.downloadFileData(fileId: file.id)
                guard !data.isEmpty else {
                    print("[SaveToLocal] Empty data for \(file.name), skipping")
                    continue
                }
                let destURL = albumDir.appendingPathComponent(file.name)
                try data.write(to: destURL)
                downloadedTracks.append(DownloadedTrack(
                    name: file.name,
                    mimeType: file.mimeType,
                    fileSize: Int64(data.count),
                    relativePath: "LocalAlbums/\(localAlbumId)/\(file.name)"
                ))
            } catch {
                print("[SaveToLocal] Failed to download \(file.name): \(error)")
            }
        }
        print("[SaveToLocal] Downloaded \(downloadedTracks.count)/\(allAudioFiles.count) tracks")

        // Fetch metadata from .addit-data
        var albumArtist: String? = album.artistName
        var tracklist: [String]? = album.cachedTracklist.isEmpty ? nil : album.cachedTracklist
        do {
            if let additDataItem = try await driveService.findFile(named: ".addit-data", inFolder: album.googleFolderId) {
                let data = try await driveService.downloadFileData(fileId: additDataItem.id)
                let metadata = try JSONDecoder().decode(AdditMetadata.self, from: data)
                if let artist = metadata.artist { albumArtist = artist }
                tracklist = metadata.tracklist
            }
        } catch {
            print("[SaveToLocal] Failed to fetch .addit-data: \(error)")
        }

        // Fetch cover image
        var coverRelativePath: String?
        do {
            if let coverItem = try await driveService.findCoverImage(inFolder: album.googleFolderId) {
                let coverData = try await driveService.downloadFileData(fileId: coverItem.id)
                let coverURL = albumDir.appendingPathComponent("cover.jpg")
                try coverData.write(to: coverURL)
                coverRelativePath = "LocalAlbums/\(localAlbumId)/cover.jpg"
            }
        } catch {
            print("[SaveToLocal] Failed to fetch cover: \(error)")
        }

        // Find the highest displayOrder across all local albums
        let localDescriptor = FetchDescriptor<Album>(
            predicate: #Predicate { $0.storageSourceRaw == "localStorage" }
        )
        let existingLocalAlbums = (try? modelContext.fetch(localDescriptor)) ?? []
        let nextOrder = (existingLocalAlbums.map(\.displayOrder).max() ?? 0) + 1

        // Insert album and tracks atomically
        let newAlbum = Album(
            googleFolderId: "local_\(localAlbumId)",
            name: album.name,
            artistName: albumArtist,
            trackCount: downloadedTracks.count,
            dateAdded: .now,
            canEdit: true,
            isFolderOwner: true,
            displayOrder: nextOrder,
            storageSource: .localStorage
        )
        newAlbum.localCoverPath = coverRelativePath
        if let tracklist, !tracklist.isEmpty {
            newAlbum.cachedTracklist = tracklist
        }
        modelContext.insert(newAlbum)

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
                album: newAlbum,
                mimeType: dl.mimeType,
                fileSize: dl.fileSize,
                trackNumber: trackNumber,
                localFilePath: dl.relativePath
            )
            modelContext.insert(track)
        }

        try? modelContext.save()
        print("[SaveToLocal] Saved album with \(downloadedTracks.count) tracks")

        await MainActor.run {
            isSavingToLocal = false
            saveProgress = (0, 0, "")
            // Switch to Local Library and navigate back
            storageSource = StorageSource.localStorage.rawValue
            dismiss()
        }
    }

    private func saveToGoogleDrive(parentId: String, markStarred: Bool) async {
        guard !isSavingToDrive, album.isLocal else { return }
        await MainActor.run {
            isSavingToDrive = true
            uploadProgress = (0, 0, "")
        }

        let fm = FileManager.default
        let localTracks = sortedTracks
        let totalSteps = localTracks.count + 2 // tracks + .addit-data + cover

        do {
            // 1. Create the destination folder in Drive
            await MainActor.run {
                uploadProgress = (current: 0, total: totalSteps, trackName: "Creating folder...")
            }
            let driveFolder = try await driveService.createFolder(name: album.name, inParent: parentId)

            // Star the new folder if the user picked the Starred tab
            if markStarred {
                try? await driveService.setStarred(fileId: driveFolder.id, starred: true)
            }

            // 2. Upload .addit-data with tracklist + artist
            await MainActor.run {
                uploadProgress = (current: 1, total: totalSteps, trackName: ".addit-data")
            }
            let tracklist: [String]
            if !album.cachedTracklist.isEmpty {
                tracklist = album.cachedTracklist
            } else {
                tracklist = localTracks.map(\.name)
            }
            let metadata = AdditMetadata(tracklist: tracklist, artist: album.artistName)
            let additData = try JSONEncoder().encode(metadata)
            let additDataItem = try await driveService.createFile(
                name: ".addit-data",
                mimeType: "application/json",
                inFolder: driveFolder.id,
                data: additData
            )

            // 3. Upload cover.jpg if present
            var uploadedCoverItem: DriveItem?
            if let coverPath = album.resolvedLocalCoverPath,
               fm.fileExists(atPath: coverPath),
               let coverData = try? Data(contentsOf: URL(fileURLWithPath: coverPath)) {
                await MainActor.run {
                    uploadProgress = (current: 2, total: totalSteps, trackName: "cover.jpg")
                }
                uploadedCoverItem = try? await driveService.createFile(
                    name: "cover.jpg",
                    mimeType: "image/jpeg",
                    inFolder: driveFolder.id,
                    data: coverData
                )
            }

            // 4. Upload each audio track
            struct UploadedTrack {
                let driveItem: DriveItem
                let mimeType: String
                let fileSize: Int64
                let trackNumber: Int
            }
            var uploadedTracks: [UploadedTrack] = []

            for (index, track) in localTracks.enumerated() {
                guard let url = track.localFileURL,
                      fm.fileExists(atPath: url.path) else {
                    print("[SaveToDrive] Skipping missing file: \(track.name)")
                    continue
                }
                await MainActor.run {
                    uploadProgress = (current: 2 + index + 1, total: totalSteps, trackName: track.name)
                }
                let data = try Data(contentsOf: url)
                let mime = track.mimeType.isEmpty ? "audio/mpeg" : track.mimeType
                let driveItem = try await driveService.createFile(
                    name: track.name,
                    mimeType: mime,
                    inFolder: driveFolder.id,
                    data: data
                )
                uploadedTracks.append(UploadedTrack(
                    driveItem: driveItem,
                    mimeType: mime,
                    fileSize: Int64(data.count),
                    trackNumber: track.trackNumber
                ))
            }

            print("[SaveToDrive] Uploaded \(uploadedTracks.count)/\(localTracks.count) tracks")

            // 5. Create the new Drive Album record in shared store
            let existingAlbums = (try? modelContext.fetch(FetchDescriptor<Album>())) ?? []
            let nextOrder = (existingAlbums.map(\.displayOrder).max() ?? -1) + 1

            let newAlbum = Album(
                googleFolderId: driveFolder.id,
                name: album.name,
                artistName: album.artistName,
                trackCount: uploadedTracks.count,
                dateAdded: .now,
                canEdit: true,
                isFolderOwner: true,
                displayOrder: nextOrder,
                storageSource: .googleDrive
            )
            newAlbum.additDataFileId = additDataItem.id
            newAlbum.cachedTracklist = tracklist
            if let coverItem = uploadedCoverItem {
                newAlbum.coverFileId = coverItem.id
                newAlbum.coverMimeType = "image/jpeg"
                newAlbum.coverModifiedTime = coverItem.modifiedTime
                newAlbum.coverUpdatedAt = .now
            }
            if let email = authService.userEmail {
                newAlbum.accountId = AccountManager.storageIdentifier(for: email)
            }
            modelContext.insert(newAlbum)

            for uploaded in uploadedTracks {
                let track = Track(
                    googleFileId: uploaded.driveItem.id,
                    name: uploaded.driveItem.name,
                    album: newAlbum,
                    mimeType: uploaded.mimeType,
                    fileSize: uploaded.fileSize,
                    trackNumber: uploaded.trackNumber,
                    modifiedTime: uploaded.driveItem.modifiedTime
                )
                modelContext.insert(track)
            }

            try? modelContext.save()
            print("[SaveToDrive] Created Drive album '\(album.name)' with \(uploadedTracks.count) tracks")

            await MainActor.run {
                isSavingToDrive = false
                uploadProgress = (0, 0, "")
                // Switch to Google Drive Library and navigate back
                storageSource = StorageSource.googleDrive.rawValue
                dismiss()
            }
        } catch {
            print("[SaveToDrive] Failed: \(error)")
            await MainActor.run {
                isSavingToDrive = false
                uploadProgress = (0, 0, "")
                saveToDriveError = error.localizedDescription
            }
        }
    }

    private func downloadAndShare(track: Track) {
        Task {
            do {
                let fileURL = try await cacheService.cacheTrack(track)
                cachedTrackIds.insert(track.googleFileId)
                // Copy to temp directory with the original filename so the share sheet shows the proper name
                let tempDir = FileManager.default.temporaryDirectory
                let destination = tempDir.appendingPathComponent(track.displayName + "." + track.fileExtension)
                let fm = FileManager.default
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(at: fileURL, to: destination)
                shareFileURL = destination
            } catch {
                print("Failed to download track for sharing: \(error)")
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

struct TrackRow: View {
    let track: Track
    let number: Int
    let isCurrentTrack: Bool
    let isPlaying: Bool
    let isCached: Bool
    var isLocal: Bool = false
    var onToggleCache: (() -> Void)?
    var onDownload: (() -> Void)?
    var onToggleHidden: (() -> Void)?
    @Environment(ThemeService.self) private var themeService

    var body: some View {
        HStack(spacing: 12) {
            if isCurrentTrack {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(themeService.accentColor)
                    .frame(width: 24)
            } else {
                Text("\(number)")
                    .font(.subheadline)
                    .foregroundColor(track.isHidden ? Color.secondary.opacity(0.3) : .secondary)
                    .frame(width: 24)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayName)
                    .font(.body.weight(.medium))
                    .foregroundColor(isCurrentTrack ? themeService.accentColor : track.isHidden ? Color.secondary.opacity(0.5) : .primary)
                    .fadingTruncation()

                HStack(spacing: 4) {
                    if isCached {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(track.isHidden ? Color.secondary.opacity(0.3) : .secondary)
                    }
                    if let size = track.fileSize {
                        Text(formatFileSize(size))
                            .font(.caption)
                            .foregroundColor(track.isHidden ? Color.secondary.opacity(0.3) : .secondary)
                    }
                }
            }

            Spacer()

            Menu {
                // File info section
                Section {
                    HStack {
                        if let date = track.formattedModifiedDate {
                            Text(date)
                                .font(.system(size: 9))
                        }
                        if track.formattedModifiedDate != nil && !track.fileExtension.isEmpty {
                            Divider()
                        }
                        if !track.fileExtension.isEmpty {
                            Text(track.fileExtension)
                                .font(.system(size: 9))
                        }
                    }
                    .frame(height: 10)
                }

                Button {
                    onToggleHidden?()
                } label: {
                    Label(track.isHidden ? "Unhide Track" : "Hide Track",
                          systemImage: track.isHidden ? "eye" : "eye.slash")
                }

                Button {
                    onDownload?()
                } label: {
                    Label("Download", systemImage: "square.and.arrow.up")
                }

                if !isLocal {
                    Button {
                        onToggleCache?()
                    } label: {
                        if isCached {
                            Label("Remove Offline Access", systemImage: "xmark.circle")
                        } else {
                            Label("Make Available Offline", systemImage: "arrow.down.circle")
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 10)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576.0
        return String(format: "%.1f MB", mb)
    }
}

struct DiscMarkerRow: View {
    let label: String
    /// Pre-formatted disc duration (e.g. "42:18" or "1:05:22"). `nil` when
    /// the underlying tracks haven't been measured yet — in that case the
    /// trailing side stays empty rather than showing "0:00".
    var duration: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            // Invisible mirror of the trailing duration. Kept in layout
            // (hidden, not omitted) so it reserves the same width as the
            // real duration on the right — the two sides must have
            // matching fixed-width pieces for the flexible dividers to
            // balance and put the label at the true horizontal center.
            if let duration {
                durationText(duration).hidden()
            }

            // Use matching VStack{Divider()} constructs on both sides
            // (rather than Spacer on the left) so their flex behavior
            // is identical — Spacer and Divider don't share leftover
            // space equally in an HStack, which would push the label
            // off-center.
            VStack { Divider() }
                .opacity(0)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            // Thin line from the label's right edge to the duration's
            // left edge. When there's no disc length (uncached tracks)
            // this divider is kept in the layout but hidden, so the
            // label still lands at the exact horizontal center.
            VStack { Divider() }
                .opacity(duration == nil ? 0 : 1)

            if let duration {
                durationText(duration)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func durationText(_ value: String) -> some View {
        Text(value)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            // Matches the per-row alignment used by the album total:
            // push the text's right edge to line up with each TrackRow's
            // ellipsis glyph (which sits ~7pt inside its 32pt frame,
            // with an 8pt row inset).
            .padding(.trailing, 7)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Sheet that lets the user pick a destination folder in Google Drive,
/// reusing the same browser used by CreateAlbumView.
struct ChooseDriveFolderSheet: View {
    let onSelectParent: (_ parentId: String, _ markStarred: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedSource: FolderSource = .personal

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Source", selection: $selectedSource) {
                    ForEach(FolderSource.allCases, id: \.self) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                ParentFolderBrowserView(
                    folderId: nil,
                    folderName: selectedSource.rawValue,
                    source: selectedSource,
                    buttonLabel: "Save Here",
                    buttonIcon: "icloud.and.arrow.up",
                    onSelectParent: { parentId, markStarred in
                        onSelectParent(parentId, markStarred)
                    }
                )
                .id(selectedSource)
            }
            .navigationDestination(for: DriveItem.self) { folder in
                ParentFolderBrowserView(
                    folderId: folder.id,
                    folderName: folder.name,
                    source: selectedSource,
                    buttonLabel: "Save Here",
                    buttonIcon: "icloud.and.arrow.up",
                    onSelectParent: { parentId, markStarred in
                        onSelectParent(parentId, markStarred)
                    }
                )
            }
            .navigationTitle("Save to Drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Download Progress Ring

/// Circular progress indicator sized to fit inside a toolbar button. The
/// surrounding `Button { } label: { ... }` in a `ToolbarItem` is what
/// gives this its liquid-glass shell on iOS 26 — the system styles the
/// button automatically when it lives in the nav-bar trailing group, so
/// we don't apply `.glassEffect()` here. We just draw the two concentric
/// rings (a faint track plus a stroked arc representing progress) and
/// let the toolbar do the rest.
private struct DownloadProgressRing: View {
    /// 0…1 fill fraction.
    let progress: Double

    private var clamped: Double {
        max(0, min(1, progress))
    }

    var body: some View {
        ZStack {
            // Track ring — faint background that shows the unfilled
            // portion of the circumference.
            Circle()
                .stroke(Color.primary.opacity(0.22), lineWidth: 2.2)

            // Progress arc — drawn from 12 o'clock clockwise. `trim`
            // controls the fraction of the circumference that's drawn;
            // the `-90°` rotation moves the start point from the
            // default (3 o'clock) up to 12 o'clock so the ring fills
            // the way users expect from a clock face.
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(
                    Color.primary,
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.25), value: clamped)
        }
        // ~17pt matches the visual weight of the SF Symbol glyphs the
        // adjacent toolbar buttons use, so the two buttons read as the
        // same family even though one is text-shaped and the other is
        // a custom drawing.
        .frame(width: 17, height: 17)
    }
}

