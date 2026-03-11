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
        return "\(album.coverArtTaskID)-\(refreshMarker)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Draggable scrubber
            Slider(
                value: Binding(
                    get: { isScrubbing ? seekValue : playerService.currentTime },
                    set: { seekValue = $0; playerService.currentTime = $0 }
                ),
                in: 0...max(playerService.duration, 1)
            ) { editing in
                if editing {
                    isScrubbing = true
                    seekValue = playerService.currentTime
                    playerService.beginSeeking()
                } else {
                    playerService.endSeeking(to: seekValue)
                    isScrubbing = false
                }
            }
            .tint(themeService.accentColor)
            .frame(height: 16)
            .padding(.horizontal, 16)
            .padding(.top, 4)

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
                    Text(miniPlayerSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

                Button {
                    playerService.next()
                } label: {
                    Image(systemName: "forward.fill")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
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
            let resolution = await albumArtService.resolveAlbumArt(for: album)
            albumImage = resolution.image
            albumArtService.applyResolution(resolution, to: album, modelContext: modelContext)
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
