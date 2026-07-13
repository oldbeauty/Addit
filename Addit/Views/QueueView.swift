import SwiftUI

struct QueueView: View {
    @Environment(AudioPlayerService.self) private var playerService
    @Environment(ThemeService.self) private var themeService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Now Playing
                if let current = playerService.currentTrack {
                    Section("Now Playing") {
                        QueueTrackRow(track: current, isPlaying: true)
                            .listRowBackground(themeService.accentColor.opacity(0.1))
                    }
                }

                // User-queued tracks (reorderable)
                if !playerService.userQueue.isEmpty {
                    Section("Playing Next") {
                        ForEach(Array(playerService.userQueue.enumerated()), id: \.offset) { index, track in
                            QueueTrackRow(track: track, isPlaying: false)
                        }
                        .onDelete { offsets in
                            for index in offsets.sorted().reversed() {
                                playerService.removeFromUserQueue(at: index)
                            }
                        }
                        .onMove { source, destination in
                            playerService.moveUserQueueTrack(from: source, to: destination)
                        }
                    }
                }

                // Remaining album queue
                let albumRemaining = remainingAlbumTracks
                if !albumRemaining.isEmpty {
                    Section(albumQueueHeader) {
                        ForEach(albumRemaining, id: \.googleFileId) { track in
                            QueueTrackRow(track: track, isPlaying: false)
                        }
                    }
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !playerService.userQueue.isEmpty {
                        EditButton()
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var remainingAlbumTracks: [Track] {
        let idx = playerService.currentIndex + 1
        guard idx < playerService.queue.count else { return [] }
        return Array(playerService.queue[idx...])
    }

    private var albumQueueHeader: String {
        if let albumName = playerService.currentTrack?.album?.name {
            return "Next from \(albumName)"
        }
        return "Up Next"
    }
}

private struct QueueTrackRow: View {
    let track: Track
    let isPlaying: Bool
    @Environment(ThemeService.self) private var themeService

    var body: some View {
        HStack(spacing: 12) {
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.uiCaption)
                    .foregroundStyle(themeService.accentColor)
                    .frame(width: 20)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayName)
                    .font(.uiBody)
                    .foregroundStyle(isPlaying ? themeService.accentColor : .primary)
                    .lineLimit(1)

                if let albumName = track.album?.name {
                    Text(albumName)
                        .font(.uiCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}
