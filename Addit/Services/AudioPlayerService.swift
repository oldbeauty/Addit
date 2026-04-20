import Foundation
import AVFoundation
import MediaPlayer
import SwiftUI
import Accelerate

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

    /// Downsampled waveform amplitudes (0…1) for the current track, used by the mini scrubber.
    var waveformSamples: [Float] = []

    /// How many samples in `waveformSamples` correspond to one second of audio.
    /// Used by zoomed views (e.g. the centered live waveform) to map the
    /// current playback time to an index range.
    var waveformSamplesPerSecond: Double = 0

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
    @ObservationIgnored private var timeTimer: CADisplayLink?
    @ObservationIgnored private var originalQueue: [Track] = []
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    /// Incremented each time we load or seek; the completion handler checks this to ignore stale callbacks
    @ObservationIgnored private var scheduleGeneration: UInt64 = 0
    @ObservationIgnored private var isLoadingTrack = false

    // Gapless playback
    @ObservationIgnored private var nextAudioFile: AVAudioFile?
    @ObservationIgnored private var nextTrackIndex: Int?
    @ObservationIgnored private var nextFileURL: URL?
    @ObservationIgnored private var nextWaveform: [Float]?
    @ObservationIgnored private var nextWaveformSamplesPerSecond: Double = 0
    @ObservationIgnored private var isGaplessTransition = false

    // Waveform extraction
    @ObservationIgnored private var waveformTask: Task<Void, Never>?

    /// Counter for throttling periodic now-playing info sync (see updateCurrentTime)
    @ObservationIgnored private var nowPlayingSyncCounter: Int = 0

    /// Tracks whether we were playing when an audio-session interruption
    /// began, so we only auto-resume on `.ended` if the user hadn't paused
    /// manually before the interruption.
    @ObservationIgnored private var wasPlayingBeforeInterruption = false

    init() {
        configureAudioSession()
        setupEngine()
        setupRemoteCommands()
        registerAudioSessionObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Playback Controls

    func playAlbum(_ album: Album, startingAt index: Int = 0, shuffled: Bool = false) {
        userQueue.removeAll()
        let sorted = album.tracks.sorted { $0.trackNumber < $1.trackNumber }.filter { !$0.isHidden }
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
            try AVAudioSession.sharedInstance().setActive(true)
            let engineWasStopped = !engine.isRunning
            if engineWasStopped {
                try engine.start()
            }

            // If the engine was stopped (e.g. from pause() or an interruption),
            // all previously-scheduled audio on the playerNode was invalidated.
            if engineWasStopped, let audioFile = currentAudioFile {
                let trackDuration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
                if currentTime >= trackDuration - 1.0 {
                    // We're within 1 s of the end (or past it).  Replaying those
                    // last dying frames would sound like the track repeated —
                    // especially if a route-change pause fired just as the track
                    // was finishing and invalidated the pending completionFired
                    // dispatch.  Advance to the next track instead.
                    handleTrackEnd()
                    return
                } else {
                    rescheduleFromCurrentTime()
                }
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
        // Snapshot position before we tear anything down
        updateCurrentTime()

        // Invalidate ALL pending completion handlers BEFORE stopping
        // the node.  playerNode.stop() immediately fires every queued
        // completion (current track + gapless next track).  Without
        // bumping the generation first, those callbacks see a valid
        // generation, call handleTrackEnd(), and silently advance to
        // the next song.
        scheduleGeneration &+= 1
        clearGaplessState()

        playerNode.stop()
        engine.stop()

        isPlaying = false
        // Deliberately DON'T stop the display link here.  updateCurrentTime()
        // early-returns as soon as lastRenderTime becomes nil (engine stopped),
        // so currentTime stays frozen at the paused position.  Keeping the
        // display link alive means that on resume, the centered waveform
        // starts scrolling the instant lastRenderTime becomes valid again —
        // instead of waiting for the next CADisplayLink creation + first tick.
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

        // Ensure engine is running so we can schedule + play
        if !engine.isRunning {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                try engine.start()
            } catch {
                print("Engine start error during seek: \(error.localizedDescription)")
                return
            }
        }

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

    /// Re-schedules playback of the current audio file from `currentTime`.
    /// Used after the engine has been stopped (pause, interruption) and
    /// all previously-scheduled segments have been invalidated.
    private func rescheduleFromCurrentTime() {
        guard let audioFile = currentAudioFile else { return }
        let sampleRate = audioFile.processingFormat.sampleRate
        let targetFrame = AVAudioFramePosition(currentTime * sampleRate)
        let totalFrames = audioFile.length
        guard targetFrame < totalFrames else { return }

        scheduleGeneration &+= 1
        let gen = scheduleGeneration

        playerTimeOffset = 0
        seekFrameOffset = targetFrame
        let remainingFrames = AVAudioFrameCount(totalFrames - targetFrame)

        playerNode.scheduleSegment(audioFile, startingFrame: targetFrame, frameCount: remainingFrames, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.completionFired(generation: gen)
        }

        clearGaplessState()
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
            restoreOriginalOrder()
        }
        // The next track changed — re-do gapless pre-scheduling
        clearGaplessState()
        let gen = scheduleGeneration
        scheduleNextTrackGapless(afterGeneration: gen)
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

            // Generate waveform asynchronously from the file URL
            generateWaveform(from: fileURL)

            playerNode.scheduleSegment(audioFile, startingFrame: 0, frameCount: AVAudioFrameCount(audioFile.length), at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.completionFired(generation: gen)
            }

            // Start the engine BEFORE calling play() so play() sees
            // engineWasStopped=false and doesn't re-schedule the segment
            // we just scheduled.  Without this, play() bumps the
            // generation and schedules Track A a SECOND time on the
            // node — audio plays Track A, then plays it again from the
            // start before finally advancing.  (Classic "audio replays
            // after full playthrough" bug.)
            if !engine.isRunning {
                try AVAudioSession.sharedInstance().setActive(true)
                try engine.start()
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
        nextFileURL = nil
        nextWaveform = nil
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

                // Pre-generate waveform for seamless visual transition
                let nextDuration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
                let nextBarCount = Self.waveformSampleCount(for: nextDuration)
                let precomputedWaveform = Self.extractWaveform(from: fileURL, barCount: nextBarCount)
                let nextSps: Double = {
                    guard let w = precomputedWaveform, nextDuration > 0 else { return 0 }
                    return Double(w.count) / nextDuration
                }()

                // Check generation one more time after waveform extraction
                guard gen == scheduleGeneration else { return }

                // Schedule on the player node — it will play immediately after current segment
                nextAudioFile = audioFile
                nextTrackIndex = nextIdx
                nextFileURL = fileURL
                nextWaveform = precomputedWaveform
                nextWaveformSamplesPerSecond = nextSps
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
        // Idempotent — if a display link is already running (e.g. we paused
        // but kept the link alive so the centered waveform can resume
        // instantly), don't tear it down and recreate it.
        if timeTimer != nil { return }
        let displayLink = CADisplayLink(target: DisplayLinkTarget { [weak self] in
            self?.updateCurrentTime()
        }, selector: #selector(DisplayLinkTarget.tick))
        displayLink.add(to: .main, forMode: .common)
        timeTimer = displayLink
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

        // Periodically push elapsed-time to the Now Playing info center so
        // the lock-screen scrubber stays in sync over long tracks.  The
        // system extrapolates from elapsed + rate, but small clock drift
        // accumulates; ~15-second updates prevent visible desync.
        nowPlayingSyncCounter += 1
        if nowPlayingSyncCounter >= 900 {  // ~15 s at 60 fps
            nowPlayingSyncCounter = 0
            updateNowPlayingPlaybackInfo()
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
            let precomputedWaveform = nextWaveform
            let precomputedSps = nextWaveformSamplesPerSecond
            isGaplessTransition = false
            nextAudioFile = nil
            nextTrackIndex = nil
            nextFileURL = nil
            nextWaveform = nil
            nextWaveformSamplesPerSecond = 0

            // Advance playerTimeOffset by exactly the number of frames that
            // just played from the outgoing track.  Querying lastRenderTime at
            // the exact track boundary is unreliable — playerTime(forNodeTime:)
            // can return nil right as one segment ends and the next begins,
            // leaving playerTimeOffset at 0 and breaking currentTime for the
            // incoming track (progress pins to end or jumps wildly).
            // This deterministic calculation is always correct regardless of
            // whether the render thread is at a segment boundary.
            let framesJustPlayed = (currentAudioFile?.length ?? 0) - seekFrameOffset
            playerTimeOffset = playerTimeOffset + framesJustPlayed

            currentIndex = nextIndex
            currentAudioFile = nextFile
            seekFrameOffset = 0
            duration = Double(nextFile.length) / nextFile.processingFormat.sampleRate
            currentTime = 0

            // Swap in the pre-computed waveform instantly (no regeneration delay)
            waveformTask?.cancel()
            waveformSamples = precomputedWaveform ?? []
            waveformSamplesPerSecond = precomputedSps

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
        // Keep everything up to and including the current track in place.
        // Only shuffle the upcoming portion of the queue.
        guard currentIndex < queue.count else { return }
        let played = Array(queue[...currentIndex])
        var upcoming = Array(queue[(currentIndex + 1)...])
        upcoming.shuffle()
        queue = played + upcoming
    }

    private func restoreOriginalOrder() {
        // Put the upcoming tracks back in their original (album) order
        // while keeping the current track where it is.
        guard currentTrack != nil else { return }

        // Figure out which tracks have already been played (up to current)
        let playedIds = Set(queue[...currentIndex].map { $0.googleFileId })

        // Upcoming tracks in their original order, excluding already-played ones
        let upcomingOriginal = originalQueue.filter { !playedIds.contains($0.googleFileId) }

        queue = Array(queue[...currentIndex]) + upcomingOriginal
        // currentIndex stays the same — we only changed what comes after
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
        // Explicitly disable `togglePlayPauseCommand`. iOS dispatches both
        // `pauseCommand` AND `togglePlayPauseCommand` for a single Control
        // Center tap; if both are registered, the second delivery flips our
        // state right back, which is what produced the lock-screen flicker
        // loop before. `playCommand` / `pauseCommand` alone are enough —
        // iOS routes based on current playback rate.
        center.togglePlayPauseCommand.isEnabled = false
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

    // MARK: - Audio Session Observers

    private func registerAudioSessionObservers() {
        let nc = NotificationCenter.default

        nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        }

        nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            self?.handleRouteChange(note)
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            // iOS has already paused/stopped the engine for us.
            // Snapshot the position and sync our state.
            wasPlayingBeforeInterruption = isPlaying
            // Invalidate completions — engine stop fires them immediately
            scheduleGeneration &+= 1
            clearGaplessState()
            if isPlaying {
                updateCurrentTime()   // capture position while node data is still valid
                isPlaying = false
                stopTimeTracking()
                updateNowPlayingPlaybackInfo()
            }
        case .ended:
            guard let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if options.contains(.shouldResume), wasPlayingBeforeInterruption {
                // play() handles engine restart + re-scheduling from currentTime
                play()
            }
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let rawReason = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }

        // Old device went away (headphones unplugged, Bluetooth disconnected).
        // Apple's convention is to pause rather than switch to the speaker.
        if reason == .oldDeviceUnavailable, isPlaying {
            pause()
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
        // Use `?? [:]` instead of a guard — on the very first play(),
        // nowPlayingInfo is still nil (updateNowPlayingInfo() hasn't
        // run yet), so a guard would silently skip the rate update
        // and the system would never learn we're playing.
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

    }

    // MARK: - Waveform

    /// Floor on sample count for very short tracks.  The mini/full scrubbers
    /// peak-downsample to fit available width, so more samples is never
    /// visually worse — but for zoomed views (centered window) we want
    /// enough resolution to show a meaningful 2-second slice.
    private static let waveformMinSamples = 120
    /// Target sample rate for the extracted waveform (samples per second of
    /// audio).  30/s means a 2-second window contains ~60 bars.
    private static let waveformSamplesPerSecond: Double = 30

    /// Computes how many bars to extract for a track of the given duration.
    private static func waveformSampleCount(for duration: TimeInterval) -> Int {
        max(waveformMinSamples, Int(duration * waveformSamplesPerSecond))
    }

    /// Reads the audio file at `url` on a background thread, downsamples
    /// into peak-amplitude buckets (0…1), and publishes the result on the
    /// main thread.
    private func generateWaveform(from url: URL) {
        waveformTask?.cancel()
        waveformSamples = []
        waveformSamplesPerSecond = 0

        let trackDuration = duration
        let barCount = Self.waveformSampleCount(for: trackDuration)
        waveformTask = Task.detached(priority: .utility) { [weak self] in
            guard let samples = Self.extractWaveform(from: url, barCount: barCount) else { return }
            guard !Task.isCancelled else { return }
            let sps = trackDuration > 0 ? Double(samples.count) / trackDuration : 0
            await MainActor.run { [weak self] in
                self?.waveformSamples = samples
                self?.waveformSamplesPerSecond = sps
            }
        }
    }

    /// Pure function — reads an audio file and returns an array of normalised
    /// peak amplitudes (one per bar).  Returns nil on error.
    private nonisolated static func extractWaveform(from url: URL, barCount: Int) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }

        let totalFrames = file.length
        guard totalFrames > 0 else { return nil }

        let framesPerBar = Int(totalFrames) / barCount
        guard framesPerBar > 0 else { return nil }

        // Use the file's processing format (deinterleaved float, possibly multi-channel)
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)

        // Process in chunks to keep memory low
        let chunkSize = min(framesPerBar, 65536)
        var peaks = [Float](repeating: 0, count: barCount)
        var globalMax: Float = 0

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkSize)) else { return nil }

        for barIndex in 0..<barCount {
            if Task.isCancelled { return nil }

            let barStart = AVAudioFramePosition(barIndex) * AVAudioFramePosition(framesPerBar)
            let barEnd = min(barStart + AVAudioFramePosition(framesPerBar), totalFrames)
            var barPeak: Float = 0

            file.framePosition = barStart

            var pos = barStart
            while pos < barEnd {
                let toRead = AVAudioFrameCount(min(Int(barEnd - pos), chunkSize))
                buffer.frameLength = 0
                do {
                    try file.read(into: buffer, frameCount: toRead)
                } catch {
                    break
                }
                guard buffer.frameLength > 0, let channelData = buffer.floatChannelData else { break }

                // Peak amplitude across all channels
                for ch in 0..<channelCount {
                    var chunkPeak: Float = 0
                    vDSP_maxmgv(channelData[ch], 1, &chunkPeak, vDSP_Length(buffer.frameLength))
                    barPeak = max(barPeak, chunkPeak)
                }

                pos += AVAudioFramePosition(buffer.frameLength)
            }

            peaks[barIndex] = barPeak
            globalMax = max(globalMax, barPeak)
        }

        // Normalise to 0…1
        guard globalMax > 0 else { return [Float](repeating: 0, count: barCount) }
        var scale = 1.0 / globalMax
        vDSP_vsmul(peaks, 1, &scale, &peaks, 1, vDSP_Length(barCount))

        return peaks
    }
}

/// Bridging helper so a `CADisplayLink` (which needs an `@objc` selector)
/// can call a plain Swift closure on every display refresh.
private final class DisplayLinkTarget: NSObject {
    private let callback: () -> Void
    init(_ callback: @escaping () -> Void) { self.callback = callback }
    @objc func tick() { callback() }
}
