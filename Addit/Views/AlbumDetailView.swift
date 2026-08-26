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
    @Environment(TransferService.self) var transfers
    @Environment(ThemeService.self) var themeService
    @Environment(AudioCacheService.self) var cacheService
    @Environment(\.modelContext) var modelContext
    @Environment(\.dismiss) var dismiss
    @AppStorage("storageSource") var storageSource: String = StorageSource.googleDrive.rawValue
    @State private var isSyncing = true
    @State var cachedTrackIds: Set<String> = []
    @State private var syncError: String?
    @State private var showAccessSheet = false
    @State private var navigateToChat = false
    @State var albumImage: UIImage?
    @State private var queuedTrackId: String?
    @State var displayItems: [TracklistItem] = []
    @State private var toolbarActionGeneration = 0
    @State var shareFileURL: URL?
    @State var isExportingAlbum = false
    @State var exportProgress: (current: Int, total: Int, trackName: String) = (0, 0, "")
    @State var exportError: String?
    /// Duration (seconds) per track, keyed by `track.googleFileId`. Populated
    /// by `calculateAlbumDuration()` from cached / on-disk audio files. Used
    /// for both the album total and per-disc totals.
    @State private var trackDurations: [String: Double] = [:]
    /// Destination provider for "Duplicate to…", which is also what presents
    /// the folder picker — the presentation's identity *is* the chosen cloud.
    @State var duplicateTarget: AccountProvider?
    /// Edit was asked for on an album the user can only read.
    @State var showEditAccessDenied = false
    @State private var linkShareItem: AlbumLinkShareItem?
    /// Held while the restricted-access warning is up; released to
    /// `linkShareItem` when it's acknowledged.
    @State private var restrictedShareItem: AlbumLinkShareItem?
    @State private var isPreparingShare = false
    /// Second step of "Duplicate to…" from the denial alert — an alert button
    /// can't open a submenu, so the destinations get their own dialog.
    @State var showDuplicateDestinations = false
    @State var saveToDriveError: String?
    /// A duplicate that partly succeeded isn't a failure — the copy exists and
    /// plays — so the alert heading has to be able to say something other than
    /// "Upload Failed".
    @State var saveToDriveErrorTitle = "Upload Failed"
    @State private var trackToSplit: Track?
    /// Whether the header's blurb is showing past its four-line cap. Resets
    /// with the view, which is the right scope — it's a reading state, not a
    /// preference.
    @State private var isDescriptionExpanded = false
    /// True only while a pull has actually triggered a sync. Gates the
    /// pull-to-refresh indicator.
    @State private var isRefreshing = false

    // MARK: Inline edit mode state (behavior inherited from the old AlbumMetadataEditorSheet)

    @State var isEditing = false
    /// Working copy of `displayItems` while editing — unfiltered, so hidden
    /// tracks stay reorderable/deletable. Committed back on Save.
    @State var editItems: [TracklistItem] = []
    @State var editedTitle = ""
    @State var editedArtist = ""
    @State var editedDescription = ""
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
    /// Which cloud edit mode's "add tracks" is browsing. Non-nil presents the
    /// picker; the value travels with it so the download reads the same drive
    /// that was browsed.
    @State var editDriveSource: AccountProvider?
    @State var isUploadingTracks = false

    /// What the rename popup is editing — album title, artist, description,
    /// or one track.
    enum EditRenameTarget: Identifiable {
        case title, artist, description, track(Track)

        var id: String {
            switch self {
            case .title: return "title"
            case .artist: return "artist"
            case .description: return "description"
            case .track(let track): return "track-\(track.googleFileId)"
            }
        }

        /// The description is prose and wants room and newlines; a name is one
        /// line. This also decides whether the popup opens with its text
        /// pre-selected — see `PromptPopup`.
        var isMultiline: Bool {
            if case .description = self { return true }
            return false
        }
    }

    /// Leading inset every track row carries, and the header text with them.
    ///
    /// It is the corner radius on purpose. The cover fills the row edge to
    /// edge, so a title ranged against the row's own edge would sit beside a
    /// curve already turning away and read as misaligned. Inset the text by
    /// exactly the radius and it lands on the tangent — where the rounding
    /// finishes and the straight edge starts, which is the line the eye
    /// follows down the page. Keeping the tracklist on the same number is
    /// what keeps the title, the artist and the track numbers on one edge.
    static let rowLeadingInset: CGFloat = 12

    /// Distance from the side of the screen to the tracklist's container.
    ///
    /// Ours, not the system's. This List used to be inset-grouped, which
    /// brought two problems that only appeared once the cover spanned the
    /// full row: the section's rounded container clipped the cover's top
    /// corners (they read rounder and flatter than the bottom two), and its
    /// ~45pt top content margin held the cover far down the screen. Both
    /// were being fought with compensating hacks — clearance padding to
    /// dodge the corner arc, a negative content margin to claw the position
    /// back — and the negative margin is what started the cover blinking on
    /// a short pull, since it puts the header row's top outside the scroll
    /// view's bounds where the List is free to recycle it.
    ///
    /// A plain List has no section container, so there is no arc to dodge
    /// and no margin to cancel. The 16pt is simply matched to what the
    /// grouped style was drawing, so nothing moved sideways.
    private static let listSideMargin: CGFloat = 16

    /// Screen edge to the tracklist's left edge: the side margin, plus the
    /// inset that lands text on the cover's tangent.
    static var trackRowLeadingInset: CGFloat { listSideMargin + rowLeadingInset }

    /// Screen edge to the tracklist's right edge.
    static var trackRowTrailingInset: CGFloat { listSideMargin + 8 }

    /// Gap between edit mode's dashed border and the artwork inside it.
    private static let editCoverBorderInset: CGFloat = 4

    /// How far the toolbar buttons sit in from the side of the screen.
    /// Measured off a screenshot: the back button's left edge is 16pt in.
    private static let toolbarButtonScreenInset: CGFloat = 16

    /// How far the toolbar buttons' bottom edge sits above the line where
    /// List content starts — the navigation bar's bottom, i.e. the top of
    /// the safe area. The glass buttons measure ~37pt tall centred in a
    /// 44pt bar, so a little under 4pt of bar shows beneath them. Measured
    /// off the same screenshot.
    private static let toolbarButtonBottomToContentTop: CGFloat = 3.5

    /// Gap from the start of the List's content down to the top of the
    /// cover, chosen so the cover clears the toolbar buttons by exactly the
    /// distance those buttons clear the side of the screen. One rhythm: the
    /// space around the buttons is the same in both directions.
    private static var coverTopGap: CGFloat {
        toolbarButtonScreenInset - toolbarButtonBottomToContentTop
    }

    /// Only reached if there is no window to ask, which shouldn't happen
    /// on screen — the size the cover was fixed at for most of its life.
    private static let fallbackCoverSize: CGFloat = 256


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
                    LoadingIndicator()

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
    // MARK: - Album cover

    private var coverCorner: CGFloat { 12 }

    /// The square the cover occupies: as wide as the row it sits in, with
    /// that side length handed to `content`.
    ///
    /// **Both covers go through here, and nothing may be added outside it.**
    /// The width is measured off the header stack, and this box lives inside
    /// that same stack, so anything that makes the cover's footprint exceed
    /// the measurement makes the stack grow, which reports a larger width,
    /// which grows the cover again — an unbounded loop that hangs the screen
    /// on push. That happened twice: once on a deliberate 4pt overhang, and
    /// once on the `.padding(4)` edit mode's dashed border had been wearing
    /// all along, harmless back when the cover was a fixed 256.
    ///
    /// The fixed frame here is the outermost modifier for exactly that
    /// reason. Padding, borders and overlays added *inside* `content` shrink
    /// what they wrap and can never enlarge the box, so the loop is closed
    /// off by construction rather than by remembering not to trip it. The
    /// rule that remains is a one-liner: decorate inside the closure, never
    /// on the value this returns.
    ///
    /// `content` receives the side length because `PixelSortCoverView` needs
    /// a concrete number to build its pixel grid from.
    private func coverBox<Content: View>(
        @ViewBuilder content: @escaping (CGFloat) -> Content
    ) -> some View {
        let side = coverSize
        return content(side)
            .frame(width: side, height: side)
    }

    /// The window's width, read rather than measured.
    ///
    /// Measuring meant `@State`, and a `@State` width is only ever as steady
    /// as the values the layout system happens to report: a List re-creating
    /// the header row mid-pull reported a width that wasn't the settled one,
    /// the cover resized for a frame, and that read as the artwork blinking.
    /// Filtering those transients was guesswork about which readings to
    /// distrust. This value doesn't move except on rotation, which
    /// re-renders anyway.
    private var windowWidth: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.keyWindow?.bounds.width ?? Self.fallbackCoverSize
    }

    /// The cover spans the tracklist exactly, edge to edge.
    private var coverSize: CGFloat {
        windowWidth - 2 * Self.listSideMargin
    }

    /// The gradient that shows through wherever there's no artwork yet.
    private var coverPlaceholderFill: LinearGradient {
        LinearGradient(
            colors: [themeService.accentColor.opacity(0.6), themeService.accentColor.opacity(0.3)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// The tappable artwork itself (pixel-sort interaction preserved),
    /// clipped to its rounded rect. No shadows here — the mount adds those.
    private var coverArtwork: some View {
        coverBox { side in
            RoundedRectangle(cornerRadius: coverCorner, style: .continuous)
                .fill(coverPlaceholderFill)
                .overlay {
                    if let albumImage {
                        // Tap to kick off a luminance-based pixel-sort
                        // animation; tap again at the sorted state to replay
                        // the log in reverse back to the original.
                        PixelSortCoverView(
                            image: albumImage,
                            size: side,
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
    }

    /// The cover, flat.
    ///
    /// It used to be a raised part in a debossed "crater" plate — inner
    /// shadows carving a well, a drop shadow and contact shadow lifting the
    /// artwork out of it, a rim highlight on the top edge. All of it is gone;
    /// the artwork is just the artwork. That also hands the header back the
    /// 44pt the plate's surround was occupying.
    private var albumCover: some View {
        coverArtwork
    }

    private var headerSection: some View {
        Section {
            VStack(spacing: 16) {
                if isEditing {
                    editableAlbumCover
                    editTitleBlock
                    editControlsRow
                    editDescriptionRow
                } else {
                    albumCover
                    titleBlock
                    playButtons
                    descriptionBlock
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Self.listSideMargin)
            .padding(.top, Self.coverTopGap)
            .padding(.bottom, 8)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            // Plain draws a separator on every row, so the header arrived
            // with a rule above the cover and another between the transport
            // buttons and the first track. The tracklist owns the rules.
            .listRowSeparator(.hidden)
        }
    }

    /// Title and artist, ranged left off the same edge as the track numbers.
    ///
    /// The header row carries zero `listRowInsets` while every track row is
    /// inset by `rowLeadingInset`, so that same constant is what puts
    /// these two on the
    /// tracklist's own left edge rather than the List's. The cover above
    /// stays centered — it's a fixed 256pt square and centering is its own
    /// decision, not one this block inherits.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(album.name)
                .font(.uiTitle2.weight(.semibold))
                .multilineTextAlignment(.leading)
                .lineLimit(2)

            Text(album.artistName ?? "Unknown Artist")
                .font(.uiSubheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Self.rowLeadingInset)
    }

    /// The blurb, below the transport buttons.
    ///
    /// Track-name size at regular weight — it reads as another line of the
    /// album's own text rather than as a caption, and the tracklist right
    /// under it sets the size the eye is already using.
    ///
    /// The 3pt top pad is what keeps `playButtons` centered: the buttons'
    /// own 1pt bottom pad plus the stack's 16 makes 17, and 3 more makes the
    /// gap below them 20 — the same 20 that sits above them. Without a blurb
    /// nothing here renders and the buttons keep their original centering
    /// against the first track row instead.
    @ViewBuilder
    private var descriptionBlock: some View {
        if let blurb = album.albumDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !blurb.isEmpty {
            // Four lines, then tap for the rest. Uncapped, a long blurb
            // pushes the tracklist off the first screen; capped with no
            // way to open it, the text is simply unreadable.
            Text(blurb)
                .font(.uiBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(isDescriptionExpanded ? nil : 4)
                .padding(.top, 3)
                .padding(.horizontal, 32)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.snappy(duration: 0.2)) {
                        isDescriptionExpanded.toggle()
                    }
                }
        }
    }

    /// Play and shuffle, as bare glyphs.
    ///
    /// They used to be `TactileButtonStyle` caps seated in debossed sockets,
    /// matching the album cover's crater. That treatment is gone, so these are
    /// the icons and nothing else — except a `GlassRim` around play, the same
    /// tilt-tracking hairline the library covers wear, which marks it as the
    /// primary action without putting a plate back under it.
    ///
    /// The 56pt frames are load-bearing beyond the tap target: edit mode sizes
    /// its own controls row to `playButtons`' height so the tracklist starts at
    /// the same place in both modes.
    var playButtons: some View {
        HStack(spacing: 24) {
            Button {
                playerService.playAlbum(album)
            } label: {
                Image(systemName: "play.fill")
                    .font(.ui(20, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: Self.playControlSize, height: Self.playControlSize)
                    .overlay { GlassRim(shape: Circle()) }
                    .contentShape(Circle())
            }
            .buttonStyle(ImprintButtonStyle())

            Button {
                if isThisAlbumPlaying {
                    playerService.toggleShuffle()
                } else {
                    playerService.playAlbum(album, shuffled: true)
                }
            } label: {
                // On/off needs two signals, not one. Tinting the glyph alone
                // failed because the accent is a pale cyan and the off state
                // was `.primary` — two light colours a shade apart, which is
                // no signal at all. Off is now dimmed, and on adds a dot.
                Image(systemName: "shuffle")
                    .font(.ui(20, weight: .semibold))
                    .foregroundStyle(shuffleEngaged ? themeService.accentColor : .secondary)
                    .frame(width: Self.playControlSize, height: Self.playControlSize)
                    .overlay(alignment: .bottom) {
                        // The running-state idiom: a dot under the thing that
                        // is on. Sized and placed to sit clear of the glyph
                        // without needing a plate to sit on.
                        Circle()
                            .fill(themeService.accentColor)
                            .frame(width: 5, height: 5)
                            .padding(.bottom, 11)
                            .opacity(shuffleEngaged ? 1 : 0)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(ImprintButtonStyle())
            .animation(.easeInOut(duration: 0.18), value: shuffleEngaged)
        }
        .padding(.top, 4)
        .padding(.bottom, 1)
    }

    /// Side of the play/shuffle hit targets, and the ring's diameter.
    static let playControlSize: CGFloat = 56

    /// Edit-mode title/artist: tap to open the rename popup, like the sheet.
    /// Flat text — no engraving, no pencil — with the same fonts and line
    /// limits as `titleBlock` so both header variants measure identically.
    private var editTitleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                beginEditRename(.title)
            } label: {
                Text(editedTitle)
                    // Same weight as `titleBlock`. `.bold()` was one step
                    // heavier, so the title thickened on entering edit mode.
                    .font(.uiTitle2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Self.rowLeadingInset)
    }

    /// Edit-mode counterpart of `descriptionBlock`, under the row that stands
    /// in for the transport buttons. Always present, unlike the read-only one:
    /// with no blurb yet it's the placeholder that gives you somewhere to tap.
    private var editDescriptionRow: some View {
        Button {
            beginEditRename(.description)
        } label: {
            Text(editedDescription.isEmpty ? "Description" : editedDescription)
                .font(.uiBody)
                .foregroundStyle(editedDescription.isEmpty ? .tertiary : .secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .padding(.top, 3)
                .padding(.horizontal, 32)
        }
        .buttonStyle(.plain)
    }

    /// Edit-mode cover: the artwork is a PhotosPicker with the sheet's dashed
    /// "tap to replace" ring. The pixel-sort tap interaction is swapped out so
    /// the tap goes to the picker.
    private var editableAlbumCover: some View {
        PhotosPicker(selection: $selectedCoverPhoto, matching: .images) {
            editCoverArtwork
        }
        .buttonStyle(.plain)
        .disabled(isUploadingCover)
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

    /// Edit mode's cover: the same square, with the artwork inset inside a
    /// dashed border rather than the border hung outside the artwork.
    ///
    /// That inversion matters. The border used to be an `.overlay` on a
    /// `.padding(4)`, which made this variant 8pt wider than the read-only
    /// one — invisible while both were a fixed 256, and a hung screen once
    /// the cover started deriving its width from the row. Insetting the
    /// artwork instead keeps the two headers exactly the same size, which
    /// is what `editTitleBlock` has always claimed about the text and is
    /// now true of the cover too: entering edit mode moves nothing.
    private var editCoverArtwork: some View {
        coverBox { side in
            ZStack {
                RoundedRectangle(cornerRadius: coverCorner, style: .continuous)
                    .fill(coverPlaceholderFill)
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
                    .padding(Self.editCoverBorderInset)

                RoundedRectangle(cornerRadius: coverCorner + 2, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .foregroundStyle(.secondary.opacity(0.6))

                if isUploadingCover {
                    RoundedRectangle(cornerRadius: coverCorner, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .padding(Self.editCoverBorderInset)
                    LoadingIndicator()
                }
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
                    .listRowInsets(EdgeInsets(top: 3, leading: Self.trackRowLeadingInset, bottom: 3, trailing: Self.trackRowTrailingInset))
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
                .listRowInsets(EdgeInsets(top: 12, leading: Self.trackRowLeadingInset, bottom: 8, trailing: Self.listSideMargin + 15))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
    }

    /// Contents of the ellipsis menu. Same items, same order as the panel that
    /// preceded it — the system draws the container now, so there's no frame,
    /// padding, divider or dismissal here to draw or manage.
    ///
    /// Still a separate property rather than inline in the `ToolbarItem` for
    /// the same type-checker-budget reason as `trackRowCell` / `initialLoad`.
    @ViewBuilder
    private var albumActions: some View {
        if !album.isLocal {
            Button {
                showAccessSheet = true
            } label: {
                Label("Access", systemImage: "person.2")
            }

            // The link on its own, for when access is already sorted and you
            // just want to send it. Whether the recipient can actually open it
            // is a question about the folder's permissions, which is why the
            // Sharing sheet — where those are visible — carries the same link
            // with a note about who it currently works for.
            //
            // Not a plain `ShareLink`: `albumImage` is the cover already on
            // screen, and handing it over builds the preview card with no
            // network round trip and no dependence on the cover being publicly
            // readable.
            if AlbumShareLink(album: album) != nil {
                Button {
                    offerShareLink(track: nil)
                } label: {
                    Label("Share Link", systemImage: "link")
                }
            }

            // Chat rides on the Drive comments API, which OneDrive
            // has no equivalent for — hidden for OneDrive albums.
            if driveService.supportsComments {
                Button {
                    navigateToChat = true
                } label: {
                    Label("Chat", systemImage: "bubble.left")
                }
            }
        }

        Button {
            enterEditMode()
        } label: {
            Label("Edit", systemImage: "pencil")
        }

        if !album.isLocal {
            Button {
                toggleAllCache()
            } label: {
                Label(
                    allTracksCached ? "Remove Offline Access" : "Make Available Offline",
                    systemImage: allTracksCached ? "xmark.circle" : "arrow.down.circle"
                )
            }
        }

        if hasHiddenTracks {
            Button {
                withAnimation { album.showHiddenTracks.toggle() }
                try? modelContext.save()
            } label: {
                Label(album.showHiddenTracks ? "Hide Hidden Tracks" : "Show Hidden Tracks",
                      systemImage: album.showHiddenTracks ? "eye.slash" : "eye")
            }
        }

        Button {
            Task { await exportAlbum() }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }

        Menu {
            // Only providers with a signed-in account — there's nowhere to
            // copy to otherwise, and the destination needn't be the account
            // currently being viewed.
            ForEach(AccountProvider.allCases) { provider in
                if authService.accountManager.activeEmail(for: provider) != nil {
                    Button {
                        duplicateTarget = provider
                    } label: {
                        Label(provider.displayName, systemImage: "icloud.and.arrow.up")
                    }
                }
            }

            // Absent for an album that's already local: a second copy in the
            // same library has nothing to distinguish it — no folder to pick,
            // same name, same files.
            if !album.isLocal {
                Button {
                    Task { await saveToLocalLibrary() }
                } label: {
                    Label("Local Library", systemImage: "iphone")
                }
            }
        } label: {
            Label("Duplicate to…", systemImage: "plus.square.on.square")
        }
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
            onSplit: splitAction(for: track),
            // Absent for a local album — nothing on the other end to point at.
            onShareLink: AlbumShareLink(track: track, in: album) == nil ? nil : {
                offerShareLink(track: track)
            }
        )
        .listRowInsets(EdgeInsets(top: 3, leading: Self.trackRowLeadingInset, bottom: 3, trailing: Self.trackRowTrailingInset))
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
            // The system draws this label white in BOTH schemes and ignores
            // any styling we put on it, so the tint has to carry the contrast.
            // Only bites on the pale end of the palette; darker accents pass
            // through untouched.
            .tint(themeService.accentColor.legibleUnderWhiteLabel)
        }
        .overlay(alignment: .trailing) {
            if queuedTrackId == track.googleFileId {
                Text("Queued")
                    .font(.uiCaption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    // Same deepened fill as the swipe pill that triggers it —
                    // the confirmation should read as the same object as the
                    // control. White is always right on it: the fill is capped
                    // below `legibleForeground`'s flip point by construction.
                    .background(themeService.accentColor.legibleUnderWhiteLabel, in: Capsule())
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

    /// Build the display list from state that is already on the device: the
    /// album's cached `.addit-data` tracklist, or plain track numbers when
    /// there is none. No network, no file I/O — a fetch and a name match —
    /// so this is cheap enough to run from `onAppear` and land in the first
    /// frame, which is the whole point of caching the tracklist.
    private func seedDisplayItems() {
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
            seedDisplayItems()
        } else {
            await syncFromDrive()
        }
        // Re-run rather than first-run: `onAppear` already seeded this from
        // disk before the first frame. Tracks that arrived or vanished in
        // the sync above are the only thing this catches.
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
            seedDisplayItems()
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
                        LoadingIndicator(label: "Syncing from Drive...")
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
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
                            .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .appBackground()
        .staticTopFade()
        .listStyle(.plain)
        .listSectionSpacing(0)
        // Plain has no default top margin to cancel, so the header's own
        // top padding is the whole gap and nothing needs pulling upward.
        .contentMargins(.top, 0, for: .scrollContent)
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
                        LoadingIndicator(size: .small)
                    } else {
                        Button("Save") {
                            Task { await saveEdits() }
                        }
                        .disabled(editedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } else {
                // One ring for every kind of background work: this album's
                // offline download, and any album transfer. Placed before the
                // ellipsis so it renders to its left in the trailing group.
                // The same ring appears in the library's toolbar, which is
                // what makes it survive leaving this screen.
                ToolbarItem(placement: .primaryAction) {
                    ActivityRing(albumFolderId: album.googleFolderId)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        albumActions
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
        }
        // Album export stages every track (downloading the uncached ones)
        // before the share sheet can appear, which is slow enough that
        // without this the tap looked like it did nothing at all.
        .overlay {
            if isExportingAlbum {
                progressCardOverlay(
                    progress: exportProgress,
                    countPrefix: "Track",
                    fallback: "Preparing export..."
                )
            }
        }
    }

    /// Share Link, from anywhere on this screen.
    ///
    /// `albumImage` — the art already on screen — goes onto the card directly,
    /// so it appears even for a restricted album, whose folder the preview
    /// fetcher cannot read.
    ///
    /// A restricted album is still worth sending a link for — the recipient may
    /// already be on the list — but if they aren't, the link fails in a way they
    /// can't diagnose from their end. So the warning comes first, and then the
    /// share proceeds either way.
    private func offerShareLink(track: Track?) {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        Task {
            defer { isPreparingShare = false }
            // Sequential rather than `async let`: the concurrent child task
            // that `async let` creates isn't main-actor isolated, and `Album`
            // is a SwiftData model that can't cross that boundary.
            let isRestricted = await ShareAccess.isRestricted(album, driveService: driveService)

            let item: AlbumLinkShareItem?
            if let track {
                item = await AlbumLinkShareItem.make(for: track, in: album, image: albumImage)
            } else {
                item = await AlbumLinkShareItem.make(for: album, image: albumImage)
            }
            guard let item else { return }

            if isRestricted {
                restrictedShareItem = item
            } else {
                linkShareItem = item
            }
        }
    }

    private var presentationLayer: some View {
        // Edit-mode presentations belong to the screen, not to the header row
        // they used to hang off — see `editModePresentations`.
        editModePresentations(chromeLayer)
        .sheet(isPresented: $showAccessSheet) {
            AccessSheet(album: album)
        }
        .sheet(item: $duplicateTarget) { provider in
            ChooseDriveFolderSheet(provider: provider) { parentId, markStarred in
                duplicateTarget = nil
                Task { await duplicateAlbum(to: provider, parentId: parentId, markStarred: markStarred) }
            }
            .environment(cloudRouter)
            .environment(authService)
        }
        .alert(saveToDriveErrorTitle, isPresented: Binding(
            get: { saveToDriveError != nil },
            set: { if !$0 { saveToDriveError = nil } }
        )) {
            Button("OK") { saveToDriveError = nil }
        } message: {
            Text(saveToDriveError ?? "")
        }
        .alert("No Edit Access", isPresented: $showEditAccessDenied) {
            Button("Duplicate to…") { showDuplicateDestinations = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You do not have edit access to this album. Do you wish to create a copy of your own?")
        }
        .confirmationDialog(
            "Duplicate to",
            isPresented: $showDuplicateDestinations,
            titleVisibility: .visible
        ) {
            // Same destinations as the album menu's own "Duplicate to…", and
            // for the same reason: only providers with an account, and no
            // local option for an album that already is local.
            ForEach(AccountProvider.allCases) { provider in
                if authService.accountManager.activeEmail(for: provider) != nil {
                    Button(provider.displayName) { duplicateTarget = provider }
                }
            }
            if !album.isLocal {
                Button("Local Library") { Task { await saveToLocalLibrary() } }
            }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .navigationDestination(isPresented: $navigateToChat) {
            ChatView(album: album)
        }
        .sheet(isPresented: Binding(
            get: { shareFileURL != nil },
            set: { if !$0 { discardSharedFile() } }
        )) {
            if let url = shareFileURL {
                // Also cleans up on the activity controller's own dismissal,
                // which never reaches the binding setter above.
                ShareSheet(activityItems: [url]) { discardSharedFile() }
            }
        }
        .overlay {
            if isPreparingShare { PreparingLinkOverlay() }
        }
        .sheet(item: $linkShareItem) { item in
            ShareSheet(activityItems: [item])
        }
        .alert("Restricted Access", isPresented: Binding(
            get: { restrictedShareItem != nil },
            set: { if !$0 { restrictedShareItem = nil } }
        )) {
            Button("Cancel", role: .cancel) { restrictedShareItem = nil }
            Button("Proceed") {
                let item = restrictedShareItem
                restrictedShareItem = nil
                // Next runloop turn. Handing SwiftUI a sheet while an alert is
                // still tearing down is exactly how a presentation goes
                // missing — the same class of desync as the rename popup.
                DispatchQueue.main.async { linkShareItem = item }
            }
        } message: {
            Text(ShareAccess.restrictedWarning)
        }
        .fullScreenCover(item: $trackToSplit, onDismiss: refreshTracklist) { splitTrack in
            TrackSplitView(track: splitTrack, album: album)
                .environment(cloudRouter)
                .environment(cacheService)
                .environment(themeService)
                .environment(playerService)
        }
    }

    /// Drops the staged export once sharing ends, so a "send only" leaves
    /// nothing behind. (A hardlinked source only loses the extra link here,
    /// never the bytes.) Album exports nest their zip in a per-export UUID
    /// directory that has to go too, or every export strands a wrapper dir;
    /// single-track exports sit directly in tmp, so the parent is only removed
    /// when it is a strict subdirectory — deleting tmp itself would take every
    /// other subsystem's scratch files with it.
    func discardSharedFile() {
        guard let url = shareFileURL else { return }
        shareFileURL = nil

        let fm = FileManager.default
        try? fm.removeItem(at: url)

        let tmp = fm.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let parent = url.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL.path
        if parent != tmp, parent.hasPrefix(tmp + "/") {
            try? fm.removeItem(atPath: parent)
        }
    }

    var body: some View {
        presentationLayer
        .refreshable {
            // A pull-to-refresh mid-edit would clobber the working copy
            // with a fresh sync — ignored until the user saves or cancels.
            if !isEditing {
                // This closure runs for exactly the length of a real
                // refresh, which is what the indicator is gated on — a
                // short pull never enters it, so nothing is drawn.
                isRefreshing = true
                defer { isRefreshing = false }
                await syncFromDrive()
            }
        }
        .additRefreshIndicator(tint: themeService.accentColor, isRefreshing: isRefreshing)
        .onAppear {
            // Everything this page can know without the network, resolved
            // before the first frame is drawn: the cover, the running order,
            // and which tracks are already on disk. All three used to be
            // produced inside `.task`, which doesn't start until after that
            // frame — so the page slid in blank, then popped its cover in,
            // then filled and reordered its rows, then grew offline badges,
            // all while you watched. Nothing here needs a round trip; it is
            // all sitting in the store or the caches directory.
            //
            // `onAppear` runs when the transition adds the view, so state set
            // here is picked up by the same update — it is genuinely frame
            // zero, not "one frame later."
            if albumImage == nil {
                if album.isLocal {
                    if let coverPath = album.resolvedLocalCoverPath {
                        albumImage = UIImage(contentsOfFile: coverPath)
                    }
                } else if let coverFileId = album.coverFileId {
                    albumImage = albumArtService.cachedImage(for: coverFileId)
                }
            }
            if displayItems.isEmpty {
                seedDisplayItems()
            }
            refreshCachedState()
        }
        .task {
            await initialLoad()
        }
        .task(id: "\(playableTracks.map(\.googleFileId))") {
            await calculateAlbumDuration()
        }
        .onChange(of: album.tracks.count) {
            if album.isLocal {
                seedDisplayItems()
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
                // Don't blank a cover we already showed from cache — but only
                // when the resolve never actually reached the provider.
                // `shouldPersistMetadata` is exactly that signal: false means
                // offline or no client, and `image` is a local fallback worth
                // less than what's on screen. True means the provider answered,
                // and an answer of "there is no cover here" has to be allowed
                // through, or artwork someone deleted upstream would linger
                // until the view was torn down and rebuilt.
                if resolution.image != nil || resolution.shouldPersistMetadata || albumImage == nil {
                    albumImage = resolution.image
                }
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
            seedDisplayItems()
            return
        }

        isSyncing = true
        syncError = nil
        defer { isSyncing = false }

        // Backstop for the `onAppear` seed — covers pull-to-refresh on an
        // album whose tracks arrived after the first frame. Normally a no-op.
        if displayItems.isEmpty && !album.tracks.isEmpty {
            seedDisplayItems()
        }

        do {
            // Refresh folder name and permissions from Drive
            if let folderInfo = try? await driveService.getFileMetadata(fileId: album.googleFolderId) {
                album.name = folderInfo.name
                album.canEdit = folderInfo.canEdit
                album.isFolderOwner = folderInfo.ownedByMe ?? false
                // The folder's own description field is the album blurb, so a
                // collaborator's edit — made here or in Drive itself — arrives
                // with the same refresh that picks up a rename.
                album.albumDescription = folderInfo.description
            }

            let response = try await driveService.listAudioFiles(inFolder: album.googleFolderId)
            let driveFiles = response.files
            let driveIds = Set(driveFiles.map(\.id))
            let localIds = Set(album.tracks.map(\.googleFileId))

            // Remove tracks that no longer exist on Drive. Their offline copies
            // go with them — the file they mirror is gone upstream, so the
            // cache entry could never be reached or refreshed again — and so
            // does any reference the player still holds, which would otherwise
            // be a detached model it traps on.
            let vanished = album.tracks.filter { !driveIds.contains($0.googleFileId) }
            playerService.forget(trackIds: Set(vanished.map(\.googleFileId)))
            for track in vanished {
                LibraryCleanup.purge(track, cache: cacheService)
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

            // Commit the inserts and deletes above before anything reads the
            // track set back. `syncAdditMetadata` renumbers and rebuilds off a
            // fetch, and a fetch that has to merge pending deletes is how a
            // just-removed Track can still surface.
            try? modelContext.save()

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

    /// What a read of the album's ordering metadata actually told us.
    ///
    /// `absent` and `unavailable` look identical at the call site — both give
    /// you no metadata — but they mean opposite things, and collapsing them
    /// is a data-loss bug: `absent` means the folder genuinely has no
    /// ordering and alphabetical is correct, while `unavailable` means we
    /// never found out. Acting on `unavailable` as if it were `absent`
    /// renumbers the album alphabetically and clears `cachedTracklist`.
    private enum AdditMetadataFetch {
        case found(AdditMetadata)
        case absent
        case unavailable
    }

    private func fetchAdditMetadata() async -> AdditMetadataFetch {
        // Try .addit-data (JSON) first
        do {
            if let item = try await driveService.findFile(named: ".addit-data", inFolder: album.googleFolderId) {
                album.additDataFileId = item.id
                let data = try await driveService.downloadFileData(fileId: item.id)
                guard let decoded = try? JSONDecoder().decode(AdditMetadata.self, from: data) else {
                    // The file is there but didn't parse — a truncated
                    // download, or a collaborator's write caught mid-flight.
                    // Whatever it is, it is not "this album has no order."
                    return .unavailable
                }
                return .found(decoded)
            }
        } catch {
            return .unavailable
        }

        // Legacy fallback: read .addit-tracklist and .addit-artist separately
        do {
            var legacy = AdditMetadata()

            if let item = try await driveService.findFile(named: ".addit-tracklist", inFolder: album.googleFolderId),
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
                return .found(legacy)
            }
            return .absent
        } catch {
            return .unavailable
        }
    }

    private func syncAdditMetadata(driveFiles: [DriveItem]) async {
        let metadata: AdditMetadata?

        switch await fetchAdditMetadata() {
        case .found(let fetched):
            metadata = fetched
        case .absent:
            metadata = nil
        case .unavailable:
            // We couldn't read the ordering, so we have no business changing
            // it. Falling through to the `else` branch below would renumber
            // the album alphabetically and then write `cachedTracklist = []`,
            // destroying a hand-ordered tracklist because a single request
            // blipped — and the next successful sync would put it back. That
            // round trip is exactly the "rearranges sometimes, seemingly
            // arbitrarily" behaviour.
            //
            // Reseeding from the tracklist we already trust still folds in
            // any tracks this sync added or removed; they land at the end,
            // where an unlisted track belongs until the order is next saved.
            seedDisplayItems()
            return
        }

        // Apply artist name
        if let metadata {
            if let artist = metadata.artist {
                album.artistName = artist.isEmpty ? nil : artist
            }
        }

        // Fetched, not `album.tracks`: this runs with inserts and deletes
        // still pending on the context, and the relationship can serve either
        // a stale array or one that still contains just-deleted models.
        let allTracks = fetchAllTracks()

        // Apply track ordering (skip disc markers)
        if let orderedNames = metadata?.tracklist, !orderedNames.isEmpty {
            var trackNumber = 1

            for name in orderedNames {
                if name.hasPrefix(AdditMetadata.discMarkerPrefix) { continue }
                if let track = allTracks.first(where: { $0.name == name }) {
                    track.trackNumber = trackNumber
                    trackNumber += 1
                }
            }

            let listedNames = Set(orderedNames.filter { !$0.hasPrefix(AdditMetadata.discMarkerPrefix) })
            let unlistedTracks = allTracks
                .filter { !listedNames.contains($0.name) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            for track in unlistedTracks {
                track.trackNumber = trackNumber
                trackNumber += 1
            }
        } else {
            // Default: order from Drive API response
            for (index, file) in driveFiles.enumerated() {
                if let track = allTracks.first(where: { $0.googleFileId == file.id }) {
                    track.trackNumber = index + 1
                }
            }
        }

        // Build display items with disc markers interleaved. Re-sorted rather
        // than reusing `allTracks`, whose order predates the renumbering above.
        buildDisplayItems(
            from: metadata,
            tracks: allTracks.sorted { $0.trackNumber < $1.trackNumber }
        )

        // Cache tracklist for instant display on next visit
        album.cachedTracklist = metadata?.tracklist ?? []
    }

    /// `tracks` is required, and always comes from `fetchAllTracks()`. It used
    /// to default to `album.tracks`, which is a SwiftData to-many relationship
    /// — unordered, sometimes stale, and capable of still holding models this
    /// same sync just deleted. Two callers reading two different track sets is
    /// how the seed and the post-sync rebuild could disagree about an album
    /// nothing had changed.
    private func buildDisplayItems(from metadata: AdditMetadata?, tracks allTracks: [Track]) {
        var items: [TracklistItem] = []

        if let orderedNames = metadata?.tracklist, !orderedNames.isEmpty {
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
        } else {
            items = allTracks.map { .track($0) }
        }

        // Rebuilding an unchanged tracklist has to be invisible. It isn't for
        // free: every build mints new `UUID`s for the disc markers, so the
        // `ForEach` sees each one as a delete plus an insert and animates the
        // rows around it. The post-sync rebuild almost always produces exactly
        // what is already on screen — that churn *was* the reorder you saw a
        // beat after opening an album. Compare by content and leave it alone.
        //
        // Renames are safe to skip: the key is the file ID and `TrackRow`
        // reads the name off the (observable) model, which sync updated in
        // place.
        guard items.map(\.contentKey) != displayItems.map(\.contentKey) else { return }
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

