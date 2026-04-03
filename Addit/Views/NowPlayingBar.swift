import SwiftUI
import UIKit
import SwiftData

struct NowPlayingBar: View {
    @Binding var showFullPlayer: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(AudioPlayerService.self) private var playerService
    @Environment(AlbumArtService.self) private var albumArtService
    @Environment(ThemeService.self) private var themeService
    @State private var seekValue: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var albumImage: UIImage?
    private let artworkSize: CGFloat = 44

    private var artworkTaskID: String? {
        guard let album = playerService.currentTrack?.album else { return nil }
        let refreshMarker = albumArtService.lastUpdatedAlbumFolderId == album.googleFolderId
            ? albumArtService.artworkRefreshVersion
            : 0
        return "\(album.coverArtTaskID)-\(refreshMarker)-\(album.localCoverPath ?? "")"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Draggable scrubber
            MiniScrubber(
                value: isScrubbing ? seekValue : playerService.currentTime,
                duration: playerService.duration,
                accentColor: themeService.accentColor,
                onChanged: { newValue in
                    if !isScrubbing {
                        isScrubbing = true
                        playerService.beginSeeking()
                    }
                    seekValue = newValue
                    playerService.currentTime = newValue
                },
                onEnded: { finalValue in
                    playerService.endSeeking(to: finalValue)
                    isScrubbing = false
                }
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)

            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(themeService.accentColor.opacity(0.2))
                    .frame(width: artworkSize, height: artworkSize)
                    .overlay {
                        Group {
                            if let albumImage {
                                Image(uiImage: albumImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: artworkSize, height: artworkSize)
                            } else {
                                Image(systemName: "music.note")
                                    .foregroundStyle(themeService.accentColor)
                                    .frame(width: artworkSize, height: artworkSize)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(playerService.currentTrack?.displayName ?? "")
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    if let error = playerService.playbackError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    } else {
                        Text(miniPlayerSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if playerService.isLoading {
                    ProgressView()
                        .frame(width: 32, height: 32)
                } else {
                    Button {
                        playerService.togglePlayPause()
                    } label: {
                        Image(systemName: playerService.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(Rectangle())
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .onTapGesture {
            if !isScrubbing {
                showFullPlayer = true
            }
        }
        .task(id: artworkTaskID) {
            guard let album = playerService.currentTrack?.album else {
                albumImage = nil
                return
            }
            if album.isLocal {
                if let path = album.resolvedLocalCoverPath {
                    albumImage = UIImage(contentsOfFile: path)
                } else {
                    albumImage = nil
                }
            } else {
                let resolution = await albumArtService.resolveAlbumArt(for: album)
                albumImage = resolution.image
                albumArtService.applyResolution(resolution, to: album, modelContext: modelContext)
            }
        }
    }

    private var miniPlayerSubtitle: String {
        let albumName = playerService.currentTrack?.album?.name ?? ""
        if let artistName = playerService.currentTrack?.album?.artistName {
            return "\(artistName) \u{2014} \(albumName)"
        }
        return albumName
    }
}

private struct MiniScrubber: View {
    let value: TimeInterval
    let duration: TimeInterval
    let accentColor: Color
    let onChanged: (TimeInterval) -> Void
    let onEnded: (TimeInterval) -> Void

    private let trackHeight: CGFloat = 3
    private let thumbSize: CGFloat = 12

    private var progress: Double {
        duration > 0 ? value / duration : 0
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let thumbX = width * progress

            ZStack(alignment: .leading) {
                // Track background
                Capsule()
                    .fill(accentColor.opacity(0.2))
                    .frame(height: trackHeight)

                // Filled track
                Capsule()
                    .fill(accentColor)
                    .frame(width: max(0, thumbX), height: trackHeight)

                // Thumb
                Circle()
                    .fill(accentColor)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: max(0, min(thumbX - thumbSize / 2, width - thumbSize)))
            }
            .frame(height: thumbSize)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let fraction = max(0, min(1, drag.location.x / width))
                        onChanged(fraction * max(duration, 1))
                    }
                    .onEnded { drag in
                        let fraction = max(0, min(1, drag.location.x / width))
                        onEnded(fraction * max(duration, 1))
                    }
            )
        }
        .frame(height: thumbSize)
    }
}
