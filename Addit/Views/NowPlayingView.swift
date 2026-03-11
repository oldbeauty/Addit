import SwiftUI
import UIKit
import SwiftData

struct NowPlayingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AudioPlayerService.self) private var playerService
    @Environment(AlbumArtService.self) private var albumArtService
    @Environment(ThemeService.self) private var themeService
    @Environment(\.dismiss) private var dismiss
    @State private var seekValue: TimeInterval = 0
    @State private var albumImage: UIImage?

    private var artworkTaskID: String? {
        guard let album = playerService.currentTrack?.album else { return nil }
        let refreshMarker = albumArtService.lastUpdatedAlbumFolderId == album.googleFolderId
            ? albumArtService.artworkRefreshVersion
            : 0
        return "\(album.coverArtTaskID)-\(refreshMarker)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drag indicator
            Capsule()
                .fill(.secondary.opacity(0.5))
                .frame(width: 40, height: 5)
                .padding(.top, 8)

            Spacer()

            // Album art placeholder
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    LinearGradient(
                        colors: [themeService.accentColor.opacity(0.6), themeService.accentColor.opacity(0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 320)
                .overlay {
                    Group {
                        if let albumImage {
                            Image(uiImage: albumImage)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: 80))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(radius: 20, y: 10)
                .padding(.horizontal, 40)

            Spacer()
                .frame(height: 32)

            // Track info
            VStack(spacing: 4) {
                Text(playerService.currentTrack?.displayName ?? "Not Playing")
                    .font(.title3.bold())
                    .lineLimit(1)
                Text(nowPlayingSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 24)

            Spacer()
                .frame(height: 24)

            // Scrubber
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { playerService.isSeeking ? seekValue : playerService.currentTime },
                        set: { seekValue = $0; playerService.currentTime = $0 }
                    ),
                    in: 0...max(playerService.duration, 1)
                ) { editing in
                    if editing {
                        seekValue = playerService.currentTime
                        playerService.beginSeeking()
                    } else {
                        playerService.endSeeking(to: seekValue)
                    }
                }
                .tint(themeService.accentColor)

                HStack {
                    Text(formatTime(playerService.isSeeking ? seekValue : playerService.currentTime))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Text(formatTime(playerService.duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 24)

            Spacer()
                .frame(height: 24)

            // Playback controls
            HStack(spacing: 40) {
                Button {
                    playerService.toggleShuffle()
                } label: {
                        Image(systemName: "shuffle")
                            .font(.title3)
                            .foregroundStyle(playerService.isShuffleOn ? themeService.accentColor : .secondary)
                }

                Button {
                    playerService.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.title2)
                }

                Button {
                    playerService.togglePlayPause()
                } label: {
                    ZStack {
                        if playerService.isLoading {
                            ProgressView()
                                .scaleEffect(1.5)
                        } else {
                            Image(systemName: playerService.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 60))
                        }
                    }
                    .frame(width: 60, height: 60)
                }

                Button {
                    playerService.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                }

                Button {
                    playerService.cycleRepeatMode()
                } label: {
                        Image(systemName: repeatIcon)
                            .font(.title3)
                            .foregroundStyle(playerService.repeatMode == .off ? .secondary : themeService.accentColor)
                }
            }

            Spacer()

            // Queue info
            if !playerService.queue.isEmpty {
                Text("Track \(playerService.currentIndex + 1) of \(playerService.queue.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)
            }
        }
        .padding()
        .task(id: artworkTaskID) {
            guard let album = playerService.currentTrack?.album else {
                albumImage = nil
                return
            }
            let resolution = await albumArtService.resolveAlbumArt(for: album)
            albumImage = resolution.image
            albumArtService.applyResolution(resolution, to: album, modelContext: modelContext)
        }
    }

    private var nowPlayingSubtitle: String {
        let albumName = playerService.currentTrack?.album?.name ?? ""
        if let artistName = playerService.currentTrack?.album?.artistName {
            return "\(artistName) \u{2014} \(albumName)"
        }
        return albumName
    }

    private var repeatIcon: String {
        switch playerService.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite && !time.isNaN else { return "0:00" }
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
