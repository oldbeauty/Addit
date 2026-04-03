import Foundation
import AVFoundation
import MediaPlayer
import SwiftUI

enum RepeatMode {
    case off, all, one
}

@Observable
final class AudioPlayerService {
    var cacheService: AudioCacheService?
    var albumArtService: AlbumArtService?

    var queue: [Track] = []
    var currentIndex: Int = 0
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isShuffleOn: Bool = false
    var repeatMode: RepeatMode = .off
    var isLoading: Bool = false
    var isSeeking: Bool = false
    var hideNowPlayingBar: Bool = false
    var userQueue: [Track] = []
    var playbackError: String? = nil
    var failedTrack: Track? = nil

    var currentTrack: Track? {
        guard !queue.isEmpty, currentIndex >= 0, currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }

    /// Exposed for AudioAnalyzerService to install taps
    @ObservationIgnored let engine = AVAudioEngine()
    @ObservationIgnored private let playerNode = AVAudioPlayerNode()
    @ObservationIgnored private var currentAudioFile: AVAudioFile?
    @ObservationIgnored private var seekFrameOffset: AVAudioFramePosition = 0
    @ObservationIgnored private var playerTimeOffset: AVAudioFramePosition = 0
    @ObservationIgnored private var timeTimer: Timer?
    @ObservationIgnored private var originalQueue: [Track] = []
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    /// Incremented each time we load or seek; the completion handler checks this to ignore stale callbacks
    @ObservationIgnored private var scheduleGeneration: UInt64 = 0
    @ObservationIgnored private var isLoadingTrack = false

    // Gapless playback
    @ObservationIgnored private var nextAudioFile: AVAudioFile?
    @ObservationIgnored private var nextTrackIndex: Int?
    @ObservationIgnored private var isGaplessTransition = false

    init() {
        configureAudioSession()
        setupEngine()
        setupRemoteCommands()
    }

    // MARK: - Playback Controls

    func playAlbum(_ album: Album, startingAt index: Int = 0, shuffled: Bool = false) {
        userQueue.removeAll()
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
        userQueue.removeAll()
        originalQueue = tracks
        queue = tracks
        currentIndex = tracks.firstIndex(where: { $0.googleFileId == track.googleFileId }) ?? 0
        if isShuffleOn {
            applyShuffle()
        }
        Task { await loadAndPlay() }
    }

    func play() {
        do {
            if !engine.isRunning {
                try engine.start()
            }
            playerNode.play()
            isPlaying = true
            startTimeTracking()
            updateNowPlayingPlaybackInfo()
        } catch {
            print("Engine start error: \(error.localizedDescription)")
        }
    }

    func pause() {
        playerNode.pause()
        isPlaying = false
        stopTimeTracking()
        updateNowPlayingPlaybackInfo()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func next() {
        guard !queue.isEmpty else { return }
        clearGaplessState()

        if repeatMode == .one {
            seek(to: 0)
            play()
            return
        }

        // Play from user queue first
        if !userQueue.isEmpty {
            let nextTrack = userQueue.removeFirst()
            queue.insert(nextTrack, at: currentIndex + 1)
            currentIndex += 1
            Task { await loadAndPlay() }
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
        clearGaplessState()

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
        guard let audioFile = currentAudioFile else { return }
        clearGaplessState()
        currentTime = time
        let sampleRate = audioFile.processingFormat.sampleRate
        let targetFrame = AVAudioFramePosition(time * sampleRate)
        let totalFrames = audioFile.length

        guard targetFrame < totalFrames else { return }

        // Invalidate any pending completion
        scheduleGeneration &+= 1
        let gen = scheduleGeneration

        let wasPlaying = isPlaying
        playerNode.stop()

        playerTimeOffset = 0
        seekFrameOffset = targetFrame
        let remainingFrames = AVAudioFrameCount(totalFrames - targetFrame)

        playerNode.scheduleSegment(audioFile, startingFrame: targetFrame, frameCount: remainingFrames, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.completionFired(generation: gen)
        }

        if wasPlaying {
            playerNode.play()
        }
        updateNowPlayingPlaybackInfo()
        scheduleNextTrackGapless(afterGeneration: gen)
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

    // MARK: - Queue Management

    func addToQueue(_ track: Track) {
        userQueue.append(track)
    }

    func removeFromUserQueue(at index: Int) {
        guard userQueue.indices.contains(index) else { return }
        userQueue.remove(at: index)
    }

    func moveUserQueueTrack(from source: IndexSet, to destination: Int) {
        userQueue.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - Engine Setup

    private func setupEngine() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        engine.prepare()
    }

    // MARK: - Private

    private func completionFired(generation: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.scheduleGeneration, !self.isLoadingTrack else { return }
            self.handleTrackEnd()
        }
    }

    private func loadAndPlay() async {
        guard let track = currentTrack else { return }

        isLoadingTrack = true
        isLoading = true

        // Invalidate any pending completion from previous track
        scheduleGeneration &+= 1
        let gen = scheduleGeneration

        playerNode.stop()

        do {
            let fileURL: URL
            if let localURL = track.localFileURL {
                fileURL = localURL
                let exists = FileManager.default.fileExists(atPath: localURL.path)
                print("[Player] Local track: \(track.name), path: \(localURL.path), exists: \(exists)")
            } else {
                guard let cacheService else { throw NSError(domain: "AudioPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cache service not available"]) }
                fileURL = try await cacheService.cacheTrack(track)
            }

            var audioFile: AVAudioFile
            do {
                audioFile = try AVAudioFile(forReading: fileURL)
            } catch {
                // AVAudioFile can't read this format — try converting via AVAssetExportSession
                print("AVAudioFile failed, attempting conversion: \(error.localizedDescription)")
                let convertedURL = try await convertToCompatibleFormat(fileURL)
                audioFile = try AVAudioFile(forReading: convertedURL)
            }

            currentAudioFile = audioFile
            seekFrameOffset = 0
            playerTimeOffset = 0

            // Reconnect with the file's format
            engine.disconnectNodeOutput(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: audioFile.processingFormat)

            duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
            currentTime = 0

            playerNode.scheduleSegment(audioFile, startingFrame: 0, frameCount: AVAudioFrameCount(audioFile.length), at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.completionFired(generation: gen)
            }

            playbackError = nil
            isLoading = false
            isLoadingTrack = false
            play()
            updateNowPlayingInfo()
            prefetchUpcoming()
            scheduleNextTrackGapless(afterGeneration: gen)
        } catch {
            isLoading = false
            isLoadingTrack = false
            failedTrack = track
            playbackError = "Unable to play this audio format"
            print("Failed to load track: \(error.localizedDescription)")
        }
    }

    private func convertToCompatibleFormat(_ sourceURL: URL) async throws -> URL {
        let convertedURL = sourceURL.deletingPathExtension().appendingPathExtension("converted.m4a")
        let fm = FileManager.default
        if fm.fileExists(atPath: convertedURL.path) {
            return convertedURL
        }

        let asset = AVURLAsset(url: sourceURL)

        // Check if the asset has any playable audio before attempting conversion
        print("[Convert] Loading tracks for: \(sourceURL.lastPathComponent)")
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            print("[Convert] Found \(tracks.count) audio track(s)")
        } catch {
            print("[Convert] loadTracks failed: \(error)")
            throw error
        }
        guard let audioTrack = tracks.first else {
            print("[Convert] No audio tracks found")
            throw NSError(domain: "AudioPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: "No audio track found"])
        }

        // Log track format details
        if let descriptions = try? await audioTrack.load(.formatDescriptions) {
            for desc in descriptions {
                let mediaSubType = CMFormatDescriptionGetMediaSubType(desc)
                let fourCC = String(format: "%c%c%c%c",
                    (mediaSubType >> 24) & 0xFF,
                    (mediaSubType >> 16) & 0xFF,
                    (mediaSubType >> 8) & 0xFF,
                    mediaSubType & 0xFF)
                print("[Convert] Track format: \(fourCC)")
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                    print("[Convert] Sample rate: \(asbd.pointee.mSampleRate), channels: \(asbd.pointee.mChannelsPerFrame), bitsPerChannel: \(asbd.pointee.mBitsPerChannel)")
                }
            }
        }

        // First try AVAssetExportSession (fast path) with timeout
        print("[Convert] Trying AVAssetExportSession...")
        if let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) {
            exportSession.outputURL = convertedURL
            exportSession.outputFileType = .m4a

            let exportResult: Bool = await withCheckedContinuation { continuation in
                var resumed = false
                let timeout = DispatchWorkItem {
                    guard !resumed else { return }
                    resumed = true
                    print("[Convert] Export session timed out")
                    exportSession.cancelExport()
                    continuation.resume(returning: false)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)

                Task {
                    for await state in exportSession.states(updateInterval: 0.1) {
                        switch state {
                        case .pending, .waiting, .exporting:
                            continue
                        @unknown default:
                            break
                        }
                        break
                    }
                    timeout.cancel()
                    guard !resumed else { return }
                    resumed = true
                    let success = fm.fileExists(atPath: convertedURL.path)
                    print("[Convert] Export session finished, success: \(success)")
                    if !success {
                        print("[Convert] Export session failed")
                    }
                    continuation.resume(returning: success)
                }
            }

            if exportResult {
                return convertedURL
            }
            try? fm.removeItem(at: convertedURL)
        } else {
            print("[Convert] Could not create export session")
        }

        // Fallback: use AVAssetReader + AVAssetWriter for more codec support
        print("[Convert] Trying AVAssetReader/Writer fallback...")
        let convertedWAV = sourceURL.deletingPathExtension().appendingPathExtension("converted.wav")
        if fm.fileExists(atPath: convertedWAV.path) {
            return convertedWAV
        }

        nonisolated(unsafe) let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            print("[Convert] AVAssetReader init failed: \(error)")
            throw error
        }
        nonisolated(unsafe) let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: convertedWAV, fileType: .wav)
        nonisolated(unsafe) let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        writer.add(writerInput)

        guard reader.startReading() else {
            print("[Convert] AVAssetReader startReading failed: \(reader.error?.localizedDescription ?? "unknown")")
            try? fm.removeItem(at: convertedWAV)
            throw reader.error ?? NSError(domain: "AudioPlayer", code: -3, userInfo: [NSLocalizedDescriptionKey: "Cannot read audio data"])
        }
        print("[Convert] AVAssetReader started reading")

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "audio.convert")) {
                while writerInput.isReadyForMoreMediaData {
                    if let buffer = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(buffer)
                    } else {
                        writerInput.markAsFinished()
                        if reader.status == .failed {
                            print("[Convert] Reader failed during read: \(reader.error?.localizedDescription ?? "unknown")")
                        }
                        continuation.resume()
                        return
                    }
                }
            }
        }

        await writer.finishWriting()
        print("[Convert] Writer finished, status: \(writer.status.rawValue)")

        guard writer.status == .completed else {
            print("[Convert] Writer failed: \(writer.error?.localizedDescription ?? "unknown")")
            try? fm.removeItem(at: convertedWAV)
            throw writer.error ?? NSError(domain: "AudioPlayer", code: -2, userInfo: [NSLocalizedDescriptionKey: "Audio conversion failed"])
        }

        return convertedWAV
    }

    private func scheduleNextTrackGapless(afterGeneration gen: UInt64) {
        // Clear any previous gapless state
        nextAudioFile = nil
        nextTrackIndex = nil
        isGaplessTransition = false

        // Determine next index
        let nextIdx: Int
        if !userQueue.isEmpty {
            // User queue tracks can't be pre-scheduled (they modify the queue)
            return
        } else if currentIndex < queue.count - 1 {
            nextIdx = currentIndex + 1
        } else if repeatMode == .all {
            nextIdx = 0
        } else {
            return
        }

        let nextTrack = queue[nextIdx]

        Task {
            do {
                let fileURL: URL
                if let localURL = nextTrack.localFileURL {
                    fileURL = localURL
                } else {
                    guard let cs = self.cacheService else { return }
                    fileURL = try await cs.cacheTrack(nextTrack)
                }

                // Check generation hasn't changed (user hasn't skipped/seeked)
                guard gen == scheduleGeneration else { return }

                var audioFile: AVAudioFile
                do {
                    audioFile = try AVAudioFile(forReading: fileURL)
                } catch {
                    let convertedURL = try await convertToCompatibleFormat(fileURL)
                    audioFile = try AVAudioFile(forReading: convertedURL)
                }

                // Check generation again after conversion
                guard gen == scheduleGeneration else { return }

                // Check format compatibility — must match current format for gapless
                guard let currentFile = currentAudioFile else { return }
                let currentFormat = currentFile.processingFormat
                let nextFormat = audioFile.processingFormat

                guard currentFormat.sampleRate == nextFormat.sampleRate,
                      currentFormat.channelCount == nextFormat.channelCount else {
                    // Format mismatch — fall back to normal transition
                    return
                }

                // Schedule on the player node — it will play immediately after current segment
                nextAudioFile = audioFile
                nextTrackIndex = nextIdx
                isGaplessTransition = true

                let expectedGen = gen
                playerNode.scheduleSegment(audioFile, startingFrame: 0, frameCount: AVAudioFrameCount(audioFile.length), at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self, self.isGaplessTransition, expectedGen == self.scheduleGeneration else { return }
                        self.handleTrackEnd()
                    }
                }
            } catch {
                // Pre-scheduling failed — normal transition will happen via handleTrackEnd
            }
        }
    }

    private func clearGaplessState() {
        if isGaplessTransition {
            // Bump generation by 2 to invalidate both the current track's
            // and the pre-scheduled next track's completion handlers
            scheduleGeneration &+= 2
        }
        nextAudioFile = nil
        nextTrackIndex = nil
        isGaplessTransition = false
    }

    private func prefetchUpcoming() {
        prefetchTask?.cancel()
        prefetchTask = Task {
            guard let cacheService else { return }

            var tracksToPrefetch: [Track] = Array(userQueue.prefix(2))
            if tracksToPrefetch.count < 2 {
                let remaining = 2 - tracksToPrefetch.count
                let indices = upcomingIndices(count: remaining)
                tracksToPrefetch.append(contentsOf: indices.map { queue[$0] })
            }

            for track in tracksToPrefetch {
                guard !Task.isCancelled else { return }
                if track.isLocal { continue } // Local tracks don't need prefetching
                do {
                    _ = try await cacheService.cacheTrack(track)
                } catch {}
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

    // MARK: - Time Tracking

    private func startTimeTracking() {
        stopTimeTracking()
        timeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateCurrentTime()
        }
    }

    private func stopTimeTracking() {
        timeTimer?.invalidate()
        timeTimer = nil
    }

    private func updateCurrentTime() {
        guard !isSeeking,
              let nodeTime = playerNode.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              let audioFile = currentAudioFile else { return }

        let sampleRate = audioFile.processingFormat.sampleRate
        let elapsedFrames = playerTime.sampleTime - playerTimeOffset
        let time = Double(seekFrameOffset + elapsedFrames) / sampleRate
        if time >= 0 && time <= duration {
            currentTime = time
        }
    }

    private func handleTrackEnd() {
        if repeatMode == .one {
            seek(to: 0)
            play()
            return
        }

        // If the next track was pre-scheduled gaplessly, just update state
        if isGaplessTransition, let nextIndex = nextTrackIndex, let nextFile = nextAudioFile {
            isGaplessTransition = false
            nextAudioFile = nil
            nextTrackIndex = nil

            // Capture the current player time so we can offset the time display
            if let nodeTime = playerNode.lastRenderTime, nodeTime.isSampleTimeValid,
               let playerTime = playerNode.playerTime(forNodeTime: nodeTime) {
                playerTimeOffset = playerTime.sampleTime
            }

            currentIndex = nextIndex
            currentAudioFile = nextFile
            seekFrameOffset = 0
            duration = Double(nextFile.length) / nextFile.processingFormat.sampleRate
            currentTime = 0

            updateNowPlayingInfo()
            prefetchUpcoming()

            // Pre-schedule the next-next track
            let gen = scheduleGeneration
            scheduleNextTrackGapless(afterGeneration: gen)
            return
        }

        next()
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
        info[MPMediaItemPropertyArtist] = currentTrack?.album?.artistName ?? ""
        info[MPMediaItemPropertyAlbumTitle] = currentTrack?.album?.name ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if let album = currentTrack?.album, album.isLocal {
            if let path = album.resolvedLocalCoverPath, let image = UIImage(contentsOfFile: path) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                var updatedInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                updatedInfo[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = updatedInfo
            }
        } else if let coverFileId = currentTrack?.album?.coverFileId, let albumArtService {
            Task {
                if let image = await albumArtService.image(for: coverFileId) {
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    var updatedInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    updatedInfo[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = updatedInfo
                }
            }
        }
    }

    private func updateNowPlayingPlaybackInfo() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
