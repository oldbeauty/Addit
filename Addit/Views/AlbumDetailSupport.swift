import SwiftUI
import UIKit

// Supporting views for AlbumDetailView, split out for file size.

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
    var onSplit: (() -> Void)?
    @Environment(ThemeService.self) private var themeService

    var body: some View {
        HStack(spacing: 12) {
            if isCurrentTrack {
                MiniEQGrid(isPlaying: isPlaying)
                    .frame(width: 24)
            } else {
                // Display layer (Phosphor): track numbers are readouts.
                Text("\(number)")
                    .font(.readout(11))
                    .foregroundStyle(track.isHidden ? Phosphor.ghost : Phosphor.dim)
                    .frame(width: 24)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayName)
                    .font(.uiBody.weight(.medium))
                    .foregroundColor(isCurrentTrack ? themeService.accentColor : track.isHidden ? Color.secondary.opacity(0.5) : .primary)
                    .fadingTruncation()

                HStack(spacing: 4) {
                    if isCached {
                        // Small dot marks a downloaded/on-device track.
                        Circle()
                            .frame(width: 6, height: 6)
                            .foregroundColor(track.isHidden ? Color.secondary.opacity(0.3) : .secondary)
                    }
                    if let size = track.fileSize {
                        Text(formatFileSize(size))
                            .font(.uiCaption)
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
                                .font(.ui(9))
                        }
                        if track.formattedModifiedDate != nil && !track.fileExtension.isEmpty {
                            Divider()
                        }
                        if !track.fileExtension.isEmpty {
                            Text(track.fileExtension)
                                .font(.ui(9))
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
                    Label("Export", systemImage: "square.and.arrow.up")
                }

                if let onSplit {
                    Button(action: onSplit) {
                        Label("Split Track", systemImage: "scissors")
                    }
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
                    .font(.uiSubheadline)
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 8)
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
                .font(.uiCaption)
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
        // Display layer (Phosphor): durations are readouts.
        Text(value)
            .font(.readout(10))
            .foregroundStyle(Phosphor.dim)
            .phosphorGlow(intensity: 0.4)
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

/// Sheet that lets the user pick a destination folder in the active
/// account's cloud, reusing the same browser used by CreateAlbumView.
struct ChooseDriveFolderSheet: View {
    let onSelectParent: (_ parentId: String, _ markStarred: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(CloudServiceRouter.self) private var cloudRouter
    @State private var selectedSource: FolderSource = .personal

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Source", selection: $selectedSource) {
                    ForEach(FolderSource.availableCases(for: cloudRouter.activeService), id: \.self) { source in
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

/// Identifiable wrapper so a picked cover photo can drive the cropper's
/// `fullScreenCover(item:)`.
struct CoverCropItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

// MARK: - Download Progress Ring

/// Circular progress indicator sized to fit inside a toolbar button. The
/// surrounding `Button { } label: { ... }` in a `ToolbarItem` is what
/// gives this its liquid-glass shell on iOS 26 — the system styles the
/// button automatically when it lives in the nav-bar trailing group, so
/// we don't apply `.glassEffect()` here. We just draw the two concentric
/// rings (a faint track plus a stroked arc representing progress) and
/// let the toolbar do the rest.
struct DownloadProgressRing: View {
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

