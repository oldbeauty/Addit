import SwiftUI
import UIKit
import SwiftData

struct NowPlayingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AudioPlayerService.self) private var playerService
    @Environment(AlbumArtService.self) private var albumArtService
    @Environment(ThemeService.self) private var themeService
    @Environment(AudioAnalyzerService.self) private var analyzer
    @Environment(\.dismiss) private var dismiss
    @State private var seekValue: TimeInterval = 0
    @State private var albumImage: UIImage?
    @State private var showQueueSheet = false
    @State private var showVisualizer = false

    private var artworkTaskID: String? {
        guard let album = playerService.currentTrack?.album else { return nil }
        let refreshMarker = albumArtService.lastUpdatedAlbumFolderId == album.googleFolderId
            ? albumArtService.artworkRefreshVersion
            : 0
        return "\(album.coverArtTaskID)-\(refreshMarker)-\(album.localCoverPath ?? "")"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drag indicator
            Capsule()
                .fill(.secondary.opacity(0.5))
                .frame(width: 40, height: 5)
                .padding(.top, 8)

            Spacer()

            // Album art / EQ visualizer
            TabView(selection: $showVisualizer) {
                albumArtView
                    .tag(false)
                EQVisualizerView()
                    .padding(.top, 20)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .tag(true)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 320)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(radius: 20, y: 10)
            .padding(.horizontal, 40)
            .onChange(of: showVisualizer) { _, visible in
                if visible { analyzer.start() } else { analyzer.stop() }
            }

            // Page indicator icons
            HStack(spacing: 12) {
                // Album icon — small rounded square
                Image(systemName: "square.fill")
                    .font(.system(size: 8))
                    .foregroundColor(showVisualizer ? .secondary.opacity(0.4) : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))

                // EQ icon — small bar chart
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 10))
                    .foregroundColor(showVisualizer ? .primary : .secondary.opacity(0.4))
            }
            .padding(.top, 12)
            .padding(.bottom, 4)

            Spacer()
                .frame(height: 16)

            // Track info
            VStack(spacing: 4) {
                Text(playerService.currentTrack?.displayName ?? "Not Playing")
                    .font(.title3.bold())
                    .lineLimit(1)
                if let error = playerService.playbackError {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else {
                    Text(nowPlayingSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 24)

            Spacer()
                .frame(height: 24)

            // Scrubber
            VStack(spacing: 4) {
                FullScrubber(
                    value: playerService.isSeeking ? seekValue : playerService.currentTime,
                    duration: playerService.duration,
                    accentColor: themeService.accentColor,
                    onChanged: { newValue in
                        if !playerService.isSeeking {
                            seekValue = playerService.currentTime
                            playerService.beginSeeking()
                        }
                        seekValue = newValue
                        playerService.currentTime = newValue
                    },
                    onEnded: { finalValue in
                        playerService.endSeeking(to: finalValue)
                    }
                )

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

            // Queue button
            if !playerService.queue.isEmpty {
                Button {
                    showQueueSheet = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.title3)
                        .foregroundStyle(.primary.opacity(0.6))
                        .overlay(alignment: .topTrailing) {
                            if !playerService.userQueue.isEmpty {
                                Text("\(playerService.userQueue.count)")
                                    .font(.system(size: 10).bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(themeService.accentColor, in: Capsule())
                                    .offset(x: 10, y: -8)
                            }
                        }
                }
                .padding(.bottom, 16)
            }
        }
        .padding()
        .sheet(isPresented: $showQueueSheet) {
            QueueView()
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

    private var albumArtView: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(
                LinearGradient(
                    colors: [themeService.accentColor.opacity(0.6), themeService.accentColor.opacity(0.2)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .aspectRatio(1, contentMode: .fit)
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

private struct FullScrubber: View {
    let value: TimeInterval
    let duration: TimeInterval
    let accentColor: Color
    let onChanged: (TimeInterval) -> Void
    let onEnded: (TimeInterval) -> Void

    private let trackHeight: CGFloat = 4
    private let thumbSize: CGFloat = 14

    private var progress: Double {
        duration > 0 ? value / duration : 0
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let thumbX = width * progress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(accentColor.opacity(0.2))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(accentColor)
                    .frame(width: max(0, thumbX), height: trackHeight)

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
