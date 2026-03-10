import Foundation
import AVFoundation
import MediaPlayer

enum RepeatMode {
    case off, all, one
}

@Observable
final class AudioPlayerService {
    var cacheService: AudioCacheService?

    var queue: [Track] = []
    var currentIndex: Int = 0
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isShuffleOn: Bool = false
    var repeatMode: RepeatMode = .off
    var isLoading: Bool = false
    var isSeeking: Bool = false

    var currentTrack: Track? {
        guard !queue.isEmpty, currentIndex >= 0, currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }

    @ObservationIgnored private var player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var originalQueue: [Track] = []
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?

    init() {
        configureAudioSession()
        setupTimeObserver()
        setupEndObserver()
        setupRemoteCommands()
    }

    // MARK: - Playback Controls

    func playAlbum(_ album: Album, startingAt index: Int = 0, shuffled: Bool = false) {
        let sorted = album.tracks.sorted { $0.trackNumber < $1.trackNumber }
        originalQueue = sorted

        if shuffled {
            var shuffledTracks = sorted
            if !shuffledTracks.isEmpty && index < shuffledTracks.count {
                let startTrack = shuffledTracks.remove(at: index)
                shuffledTracks.shuffle()
                shuffledTracks.insert(startTrack, at: 0)
            }
            queue = shuffledTracks
            currentIndex = 0
            isShuffleOn = true
        } else {
            queue = sorted
            currentIndex = index
            isShuffleOn = false
        }

        Task { await loadAndPlay() }
    }

    func playTrack(_ track: Track, inQueue tracks: [Track]) {
        originalQueue = tracks
        queue = tracks
        currentIndex = tracks.firstIndex(where: { $0.googleFileId == track.googleFileId }) ?? 0
        if isShuffleOn {
            applyShuffle()
        }
        Task { await loadAndPlay() }
    }

    func play() {
        player.play()
        isPlaying = true
        updateNowPlayingPlaybackInfo()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlayingPlaybackInfo()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func next() {
        guard !queue.isEmpty else { return }

        if repeatMode == .one {
            seek(to: 0)
            play()
            return
        }

        if currentIndex < queue.count - 1 {
            currentIndex += 1
        } else if repeatMode == .all {
            currentIndex = 0
        } else {
            pause()
            return
        }
        Task { await loadAndPlay() }
    }

    func previous() {
        guard !queue.isEmpty else { return }

        if currentTime > 3.0 {
            seek(to: 0)
            return
        }

        if currentIndex > 0 {
            currentIndex -= 1
        } else if repeatMode == .all {
            currentIndex = queue.count - 1
        } else {
            seek(to: 0)
            return
        }
        Task { await loadAndPlay() }
    }

    func seek(to time: TimeInterval) {
        currentTime = time
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: cmTime) { [weak self] _ in
            self?.updateNowPlayingPlaybackInfo()
        }
    }

    func beginSeeking() {
        isSeeking = true
    }

    func endSeeking(to time: TimeInterval) {
        seek(to: time)
        isSeeking = false
    }

    func toggleShuffle() {
        isShuffleOn.toggle()
        if isShuffleOn {
            applyShuffle()
        } else {
            let current = currentTrack
            queue = originalQueue
            if let current {
                currentIndex = queue.firstIndex(where: { $0.googleFileId == current.googleFileId }) ?? 0
            }
        }
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // MARK: - Private

    private func loadAndPlay() async {
        guard let track = currentTrack, let cacheService else { return }

        isLoading = true
        do {
            let fileURL = try await cacheService.cacheTrack(track)
            let item = AVPlayerItem(url: fileURL)
            player.replaceCurrentItem(with: item)

            // Wait for ready state
            while item.status == .unknown {
                try await Task.sleep(for: .milliseconds(50))
            }

            if item.status == .readyToPlay {
                let dur = try await item.asset.load(.duration)
                duration = CMTimeGetSeconds(dur)
                currentTime = 0
                isLoading = false
                play()
                updateNowPlayingInfo()
                prefetchUpcoming()
            } else {
                isLoading = false
            }
        } catch {
            isLoading = false
            print("Failed to load track: \(error.localizedDescription)")
        }
    }

    private func prefetchUpcoming() {
        prefetchTask?.cancel()
        prefetchTask = Task {
            guard let cacheService else { return }
            let indicesToPrefetch = upcomingIndices(count: 2)
            for index in indicesToPrefetch {
                guard !Task.isCancelled else { return }
                let track = queue[index]
                do {
                    _ = try await cacheService.cacheTrack(track)
                } catch {
                    // Prefetch is best-effort; don't block on failure
                }
            }
        }
    }

    private func upcomingIndices(count: Int) -> [Int] {
        guard !queue.isEmpty else { return [] }
        var indices: [Int] = []
        for offset in 1...count {
            let next = currentIndex + offset
            if next < queue.count {
                indices.append(next)
            } else if repeatMode == .all {
                indices.append(next % queue.count)
            }
        }
        return indices
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("Audio session error: \(error.localizedDescription)")
        }
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, !self.isSeeking else { return }
            self.currentTime = CMTimeGetSeconds(time)
        }
    }

    private func setupEndObserver() {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleTrackEnd()
        }
    }

    private func handleTrackEnd() {
        if repeatMode == .one {
            seek(to: 0)
            play()
        } else {
            next()
        }
    }

    private func applyShuffle() {
        let current = currentTrack
        var remaining = queue
        if let idx = remaining.firstIndex(where: { $0.googleFileId == current?.googleFileId }) {
            remaining.remove(at: idx)
        }
        remaining.shuffle()
        if let current {
            remaining.insert(current, at: 0)
        }
        queue = remaining
        currentIndex = 0
    }

    // MARK: - Now Playing Info Center

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.next()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = currentTrack?.displayName ?? ""
        info[MPMediaItemPropertyAlbumTitle] = currentTrack?.album?.name ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingPlaybackInfo() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
