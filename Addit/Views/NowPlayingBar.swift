import SwiftUI

struct NowPlayingBar: View {
    @Binding var showFullPlayer: Bool
    @Environment(AudioPlayerService.self) private var playerService
    @State private var seekValue: TimeInterval = 0
    @State private var isScrubbing = false

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
            .tint(Color.accentColor)
            .frame(height: 16)
            .padding(.horizontal, 16)
            .padding(.top, 4)

            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: "music.note")
                            .foregroundStyle(Color.accentColor)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(playerService.currentTrack?.displayName ?? "")
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Text(playerService.currentTrack?.album?.name ?? "")
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
    }
}
