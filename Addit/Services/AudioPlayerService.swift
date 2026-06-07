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
    /// Atomic snapshot of the three interdependent fields needed to map
    /// the audio engine's render-time clock back into "how far into the
    /// current audio file are we." Bundling them into a struct means any
    /// reader (most importantly `updateCurrentTime`) captures the whole
    /// triple in a single load and computes its result from a
    /// self-consistent view — there's no possibility of, say, reading
    /// the new track's `seekFrame` while still seeing the old track's
    /// `audioFile` and `playerTimeOffset`. The single-statement
    /// `anchor = PlaybackAnchor(...)` reassignment is the atomic swap
    /// that replaces what used to be three separate field mutations.
    private struct PlaybackAnchor {
        /// The file currently being decoded by `playerNode`.
        let audioFile: AVAudioFile
        /// Frame within `audioFile` that playback was last "anchored"
        /// at — i.e., the position the engine started reading from
        /// after the last `scheduleSegment`. Updated on seek, reset to
        /// 0 on a fresh track load or after a gapless advance.
        let seekFrame: AVAudioFramePosition
        /// `playerNode.sampleTime` value that corresponds to
        /// `seekFrame` of `audioFile`. Subtract this from the current
        /// `playerTime.sampleTime` to get frames elapsed within the
        /// current audio file. Grows monotonically across gapless
        /// transitions; resets to 0 on every `playerNode.stop()`.
        let playerTimeOffset: AVAudioFramePosition

        var sampleRate: Double { audioFile.processingFormat.sampleRate }
        var totalFrames: AVAudioFramePosition { audioFile.length }
        var duration: TimeInterval { Double(totalFrames) / sampleRate }

        /// Map a `playerNode` sample-time reading to the corresponding
        /// elapsed-time-in-file. Returned value is monotonic in
        /// `engineSampleTime` for as long as the anchor doesn't change.
        func elapsedSeconds(forEngineSampleTime engineSampleTime: AVAudioFramePosition) -> TimeInterval {
            let elapsedFrames = engineSampleTime - playerTimeOffset
            return Double(seekFrame + elapsedFrames) / sampleRate
        }
    }
    @ObservationIgnored private var anchor: PlaybackAnchor?
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
    /// True when the pre-scheduled gapless next track came from `userQueue`
    /// rather than the album's natural ordering. Used by `handleTrackEnd`
    /// to know whether it needs to splice `userQueue.first` into `queue`
    /// before advancing `currentIndex`.
    @ObservationIgnored private var nextIsFromUserQueue = false
    /// Track identity (Drive file ID) of whatever is currently
    /// pre-scheduled as the gapless next track. Used as a comparison key
    /// in `rebuildGaplessIfNeeded`: if the desired-next based on current
    /// queue state matches this ID, the existing schedule is still
    /// correct and no rebuild is needed. `nil` means nothing is scheduled.
    @ObservationIgnored private var nextScheduledTrackID: String?
    /// In-flight Task that's loading the next track's audio file and
    /// scheduling it on the player. Cancelled when we need to tear down
    /// and rebuild the gapless schedule due to a queue mutation.
    @ObservationIgnored private var gaplessLoadTask: Task<Void, Never>?

    /// In-flight Task that's fetching the current track's album artwork
    /// for the lock-screen Now Playing display. Cancelled when the
    /// current track changes so that a slow artwork fetch for track N
    /// can't complete and overwrite the lock-screen display for track
    /// N+1 (or worse, N+5 after several skips).
    @ObservationIgnored private var artworkTask: Task<Void, Never>?

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
            if engineWasStopped, let snapshot = anchor {
                let trackDuration = snapshot.duration
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
            #if DEBUG
            print("Engine start error: \(error.localizedDescription)")
            #endif
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
        #if DEBUG
        print("[Q] next() entry currentIndex=\(currentIndex) userQueueLen=\(userQueue.count) isGapless=\(isGaplessTransition) nextTrackIndex=\(nextTrackIndex.map(String.init) ?? "nil") scheduleGen=\(scheduleGeneration)")
        #endif
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
            #if DEBUG
            print("[Q] next() path=userQueue track=\"\(nextTrack.name)\" newIndex=\(currentIndex) remainingUserQueue=\(userQueue.count)")
            #endif
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
        #if DEBUG
        let advTrack = (currentIndex >= 0 && currentIndex < queue.count) ? queue[currentIndex].name : "?"
        print("[Q] next() path=regular newIndex=\(currentIndex) track=\"\(advTrack)\"")
        #endif
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
        guard let snapshot = anchor else { return }
        let audioFile = snapshot.audioFile
        clearGaplessState()
        currentTime = time
        let sampleRate = snapshot.sampleRate
        let targetFrame = AVAudioFramePosition(time * sampleRate)
        let totalFrames = snapshot.totalFrames

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
                #if DEBUG
                print("Engine start error during seek: \(error.localizedDescription)")
                #endif
                return
            }
        }

        playerNode.stop()

        anchor = PlaybackAnchor(audioFile: audioFile, seekFrame: targetFrame, playerTimeOffset: 0)
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
        guard let snapshot = anchor else { return }
        let audioFile = snapshot.audioFile
        let sampleRate = snapshot.sampleRate
        let targetFrame = AVAudioFramePosition(currentTime * sampleRate)
        let totalFrames = snapshot.totalFrames
        guard targetFrame < totalFrames else { return }

        scheduleGeneration &+= 1
        let gen = scheduleGeneration

        anchor = PlaybackAnchor(audioFile: audioFile, seekFrame: targetFrame, playerTimeOffset: 0)
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
        #if DEBUG
        print("[Q] addToQueue track=\"\(track.name)\" userQueueLen=\(userQueue.count) isGapless=\(isGaplessTransition) nextScheduledTrackID=\(nextScheduledTrackID ?? "nil") scheduleGen=\(scheduleGeneration)")
        #endif
        rebuildGaplessIfNeeded()
    }

    func removeFromUserQueue(at index: Int) {
        guard userQueue.indices.contains(index) else { return }
        userQueue.remove(at: index)
        rebuildGaplessIfNeeded()
    }

    func moveUserQueueTrack(from source: IndexSet, to destination: Int) {
        userQueue.move(fromOffsets: source, toOffset: destination)
        rebuildGaplessIfNeeded()
    }

    // MARK: - Gapless rescheduling

    /// What track *should* play next given the current state of
    /// `userQueue`, `queue`, `currentIndex`, and `repeatMode`. Mirrors the
    /// branching in `scheduleNextTrackGapless`. `nil` means "nothing —
    /// playback ends after the current track."
    private func desiredNextTrack() -> (track: Track, idx: Int, fromUserQueue: Bool)? {
        if !userQueue.isEmpty {
            return (userQueue[0], currentIndex + 1, true)
        } else if currentIndex < queue.count - 1 {
            return (queue[currentIndex + 1], currentIndex + 1, false)
        } else if repeatMode == .all, let first = queue.first {
            return (first, 0, false)
        }
        return nil
    }

    /// Called after any mutation that could change what the gapless next
    /// track should be (queue additions, removals, reorders, repeat-mode
    /// changes, etc.). If the currently pre-scheduled track is still the
    /// correct one, this is a no-op. Otherwise tears down the current
    /// playback pipeline, re-schedules the current track from its current
    /// playback frame, and lets `scheduleNextTrackGapless` pick the new
    /// gapless target. The brief audio interruption from `stop()` happens
    /// at the moment of the user's queue action (where a tiny blip is
    /// expected and unobjectionable), so the eventual transition into the
    /// queued track is truly gapless.
    private func rebuildGaplessIfNeeded() {
        let desired = desiredNextTrack()
        let desiredID = desired?.track.googleFileId
        if desiredID == nextScheduledTrackID {
            #if DEBUG
            print("[Q] rebuildGaplessIfNeeded NO-OP desired=\(desiredID ?? "nil") matches scheduled")
            #endif
            return
        }
        if isGaplessTransition {
            // The next track has already been scheduled on the player
            // node. Removing a scheduled segment requires `stop()`, which
            // flushes the audio buffer and causes a brief audible pause.
            // This branch only fires when the queue is mutated within
            // ~`armLeadTime` seconds of the current track ending — a
            // narrow window.
            #if DEBUG
            print("[Q] rebuildGaplessIfNeeded MISMATCH desired=\(desiredID ?? "nil") scheduled=\(nextScheduledTrackID ?? "nil") armed=true → replaceCurrentScheduling (brief pause)")
            #endif
            replaceCurrentScheduling()
        } else {
            // Pre-loaded but not armed on the engine yet. Just cancel the
            // pending load and start a new one with the corrected target.
            // The engine never sees this — playback continues uninterrupted.
            #if DEBUG
            print("[Q] rebuildGaplessIfNeeded MISMATCH desired=\(desiredID ?? "nil") scheduled=\(nextScheduledTrackID ?? "nil") armed=false → re-preload (no pause)")
            #endif
            gaplessLoadTask?.cancel()
            gaplessLoadTask = nil
            nextAudioFile = nil
            nextTrackIndex = nil
            nextFileURL = nil
            nextWaveform = nil
            nextIsFromUserQueue = false
            nextScheduledTrackID = nil
            scheduleNextTrackGapless(afterGeneration: scheduleGeneration)
        }
    }

    /// Stop the player, re-schedule the current track from its current
    /// playback frame, and call `scheduleNextTrackGapless` to set up the
    /// new gapless target. Only the engine's segment queue is reset —
    /// `currentIndex`, `currentTrack`, `duration`, and `currentTime` all
    /// remain coherent across this call.
    private func replaceCurrentScheduling() {
        guard let snapshot = anchor else { return }
        let currentFile = snapshot.audioFile

        // Snapshot the current playback frame BEFORE stop() blows away
        // the playerNode's render-time clock. Falls back to the most
        // recent seek baseline if lastRenderTime isn't yet valid (e.g.
        // we're called immediately after a load, before the engine has
        // rendered anything).
        let currentFrame: AVAudioFramePosition = {
            guard let nodeTime = playerNode.lastRenderTime,
                  nodeTime.isSampleTimeValid,
                  let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
                return snapshot.seekFrame
            }
            return snapshot.seekFrame + (playerTime.sampleTime - snapshot.playerTimeOffset)
        }()
        let remaining = AVAudioFrameCount(max(0, snapshot.totalFrames - currentFrame))
        guard remaining > 0 else {
            // Already past the end of the current track — nothing useful
            // we can do here; the existing handleTrackEnd flow will pick
            // up the new gapless target on its own.
            return
        }

        let wasPlaying = playerNode.isPlaying

        // Cancel any in-flight load Task and reset all gapless state.
        gaplessLoadTask?.cancel()
        gaplessLoadTask = nil
        playerNode.stop()
        nextAudioFile = nil
        nextTrackIndex = nil
        nextFileURL = nil
        nextWaveform = nil
        nextWaveformSamplesPerSecond = 0
        isGaplessTransition = false
        nextIsFromUserQueue = false
        nextScheduledTrackID = nil

        // Bump generation so any callback from the previous schedule that
        // hasn't fired yet sees a stale generation and bails.
        scheduleGeneration &+= 1
        let gen = scheduleGeneration

        // Re-anchor the time-tracking baseline. playerNode.lastRenderTime
        // resets to 0 after stop(); we treat currentFrame as the new
        // "where in the file we're at" anchor.
        anchor = PlaybackAnchor(audioFile: currentFile, seekFrame: currentFrame, playerTimeOffset: 0)

        playerNode.scheduleSegment(
            currentFile,
            startingFrame: currentFrame,
            frameCount: remaining,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            self?.completionFired(generation: gen)
        }

        if wasPlaying {
            playerNode.play()
        }
        #if DEBUG
        print("[Q] replaceCurrentScheduling re-anchored at frame=\(currentFrame) remaining=\(remaining) newGen=\(gen) wasPlaying=\(wasPlaying)")
        #endif
        scheduleNextTrackGapless(afterGeneration: gen)
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
            guard let self else { return }
            #if DEBUG
            print("[Q] completionFired (regular) expectedGen=\(generation) currentGen=\(self.scheduleGeneration) isLoadingTrack=\(self.isLoadingTrack) → \(generation == self.scheduleGeneration && !self.isLoadingTrack ? "handleTrackEnd" : "bail")")
            #endif
            guard generation == self.scheduleGeneration, !self.isLoadingTrack else { return }
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
        #if DEBUG
        print("[Q] loadAndPlay track=\"\(track.name)\" currentIndex=\(currentIndex) newGen=\(gen) userQueueLen=\(userQueue.count)")
        #endif

        playerNode.stop()

        do {
            let fileURL: URL
            if let localURL = track.localFileURL {
                fileURL = localURL
                let exists = FileManager.default.fileExists(atPath: localURL.path)
                #if DEBUG
                print("[Player] Local track: \(track.name), path: \(localURL.path), exists: \(exists)")
                #endif
            } else {
                guard let cacheService else { throw NSError(domain: "AudioPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cache service not available"]) }
                fileURL = try await cacheService.cacheTrack(track)
            }

            var audioFile: AVAudioFile
            do {
                audioFile = try AVAudioFile(forReading: fileURL)
            } catch {
                // AVAudioFile can't read this format — try converting via AVAssetExportSession
                #if DEBUG
                print("AVAudioFile failed, attempting conversion: \(error.localizedDescription)")
                #endif
                let convertedURL = try await convertToCompatibleFormat(fileURL)
                audioFile = try AVAudioFile(forReading: convertedURL)
            }

            anchor = PlaybackAnchor(audioFile: audioFile, seekFrame: 0, playerTimeOffset: 0)

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
            #if DEBUG
            print("Failed to load track: \(error.localizedDescription)")
            #endif
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
        #if DEBUG
        print("[Convert] Loading tracks for: \(sourceURL.lastPathComponent)")
        #endif
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            #if DEBUG
            print("[Convert] Found \(tracks.count) audio track(s)")
            #endif
        } catch {
            #if DEBUG
            print("[Convert] loadTracks failed: \(error)")
            #endif
            throw error
        }
        guard let audioTrack = tracks.first else {
            #if DEBUG
            print("[Convert] No audio tracks found")
            #endif
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
                #if DEBUG
                print("[Convert] Track format: \(fourCC)")
                #endif
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                    #if DEBUG
                    print("[Convert] Sample rate: \(asbd.pointee.mSampleRate), channels: \(asbd.pointee.mChannelsPerFrame), bitsPerChannel: \(asbd.pointee.mBitsPerChannel)")
                    #endif
                }
            }
        }

        // First try AVAssetExportSession (fast path) with timeout
        #if DEBUG
        print("[Convert] Trying AVAssetExportSession...")
        #endif
        if let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) {
            exportSession.outputURL = convertedURL
            exportSession.outputFileType = .m4a

            let exportResult: Bool = await withCheckedContinuation { continuation in
                var resumed = false
                let timeout = DispatchWorkItem {
                    guard !resumed else { return }
                    resumed = true
                    #if DEBUG
                    print("[Convert] Export session timed out")
                    #endif
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
                    #if DEBUG
                    print("[Convert] Export session finished, success: \(success)")
                    #endif
                    if !success {
                        #if DEBUG
                        print("[Convert] Export session failed")
                        #endif
                    }
                    continuation.resume(returning: success)
                }
            }

            if exportResult {
                return convertedURL
            }
            try? fm.removeItem(at: convertedURL)
        } else {
            #if DEBUG
            print("[Convert] Could not create export session")
            #endif
        }

        // Fallback: use AVAssetReader + AVAssetWriter for more codec support
        #if DEBUG
        print("[Convert] Trying AVAssetReader/Writer fallback...")
        #endif
        let convertedWAV = sourceURL.deletingPathExtension().appendingPathExtension("converted.wav")
        if fm.fileExists(atPath: convertedWAV.path) {
            return convertedWAV
        }

        nonisolated(unsafe) let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            #if DEBUG
            print("[Convert] AVAssetReader init failed: \(error)")
            #endif
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
            #if DEBUG
            print("[Convert] AVAssetReader startReading failed: \(reader.error?.localizedDescription ?? "unknown")")
            #endif
            try? fm.removeItem(at: convertedWAV)
            throw reader.error ?? NSError(domain: "AudioPlayer", code: -3, userInfo: [NSLocalizedDescriptionKey: "Cannot read audio data"])
        }
        #if DEBUG
        print("[Convert] AVAssetReader started reading")
        #endif

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
                            #if DEBUG
                            print("[Convert] Reader failed during read: \(reader.error?.localizedDescription ?? "unknown")")
                            #endif
                        }
                        continuation.resume()
                        return
                    }
                }
            }
        }

        await writer.finishWriting()
        #if DEBUG
        print("[Convert] Writer finished, status: \(writer.status.rawValue)")
        #endif

        guard writer.status == .completed else {
            #if DEBUG
            print("[Convert] Writer failed: \(writer.error?.localizedDescription ?? "unknown")")
            #endif
            try? fm.removeItem(at: convertedWAV)
            throw writer.error ?? NSError(domain: "AudioPlayer", code: -2, userInfo: [NSLocalizedDescriptionKey: "Audio conversion failed"])
        }

        return convertedWAV
    }

    /// How close to the end of the current track (in seconds) we'll wait
    /// before actually scheduling the next track on the player node.
    /// Anything ≥ this and we keep the next track only in memory; below
    /// this, `updateCurrentTime` arms the engine schedule. Tuned to give
    /// the audio engine comfortable lead time without arming so early
    /// that queue mutations late in the track would require a pause.
    private static let armLeadTime: TimeInterval = 0.5

    /// Two-phase gapless pipeline:
    ///   1. PRELOAD — load the desired next track's audio file and
    ///      waveform into memory. No engine interaction. Idle state.
    ///   2. ARM (`armNextTrackOnEngineIfNeeded`) — take the pre-loaded
    ///      file and `playerNode.scheduleSegment` it. Triggered by
    ///      `updateCurrentTime` when the current track has less than
    ///      `armLeadTime` remaining.
    ///
    /// Splitting these means queue mutations that happen before arming
    /// don't need to touch the engine at all — they just cancel the
    /// in-flight load and start a new one, with zero audible disruption.
    /// Only mutations in the last `armLeadTime` of a track require the
    /// `replaceCurrentScheduling` pause-rebuild path, which is rare.
    private func scheduleNextTrackGapless(afterGeneration gen: UInt64) {
        // Clear any previous gapless state
        nextAudioFile = nil
        nextTrackIndex = nil
        nextFileURL = nil
        nextWaveform = nil
        isGaplessTransition = false
        nextIsFromUserQueue = false
        nextScheduledTrackID = nil

        // Pick the next track. User queue ALWAYS wins over the album's
        // natural ordering — the queue is the user's explicit "play this
        // next" intent. The album track only fills in when the queue is
        // empty.
        let nextTrack: Track
        let nextIdx: Int
        let fromUserQueue: Bool
        if !userQueue.isEmpty {
            nextTrack = userQueue[0]
            // The queued track will be spliced into `queue` at this index
            // when handleTrackEnd's gapless branch advances. We schedule it
            // here so the engine has the audio ready well before the
            // boundary.
            nextIdx = currentIndex + 1
            fromUserQueue = true
        } else if currentIndex < queue.count - 1 {
            nextTrack = queue[currentIndex + 1]
            nextIdx = currentIndex + 1
            fromUserQueue = false
        } else if repeatMode == .all {
            nextTrack = queue[0]
            nextIdx = 0
            fromUserQueue = false
        } else {
            #if DEBUG
            print("[Q] scheduleNextTrackGapless BAIL reason=endOfQueue currentIndex=\(currentIndex) queueLen=\(queue.count) repeat=\(repeatMode) scheduleGen=\(gen)")
            #endif
            return
        }

        #if DEBUG
        print("[Q] scheduleNextTrackGapless QUEUED nextIdx=\(nextIdx) track=\"\(nextTrack.name)\" fromUserQueue=\(fromUserQueue) currentIndex=\(currentIndex) scheduleGen=\(gen)")
        #endif

        gaplessLoadTask?.cancel()
        let trackID = nextTrack.googleFileId
        // Stake out the track ID immediately so rebuildGaplessIfNeeded's
        // comparison check sees it before the load completes — otherwise
        // a queue mutation that arrives mid-load would needlessly cancel
        // and restart against an identical desired target.
        nextScheduledTrackID = trackID
        gaplessLoadTask = Task {
            do {
                let fileURL: URL
                if let localURL = nextTrack.localFileURL {
                    fileURL = localURL
                } else {
                    guard let cs = self.cacheService else { return }
                    fileURL = try await cs.cacheTrack(nextTrack)
                }

                // Check generation + cancellation. A queue mutation that
                // happened during loading would have cancelled this task
                // *and* bumped the generation, so either guard catches it.
                try Task.checkCancellation()
                guard gen == scheduleGeneration else { return }

                var audioFile: AVAudioFile
                do {
                    audioFile = try AVAudioFile(forReading: fileURL)
                } catch {
                    let convertedURL = try await convertToCompatibleFormat(fileURL)
                    audioFile = try AVAudioFile(forReading: convertedURL)
                }

                try Task.checkCancellation()
                guard gen == scheduleGeneration else { return }

                // Check format compatibility — must match current format for gapless
                guard let currentSnapshot = anchor else { return }
                let currentFormat = currentSnapshot.audioFile.processingFormat
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

                try Task.checkCancellation()
                guard gen == scheduleGeneration else { return }

                // Stage in memory but DO NOT arm the engine yet.
                nextAudioFile = audioFile
                nextTrackIndex = nextIdx
                nextFileURL = fileURL
                nextWaveform = precomputedWaveform
                nextWaveformSamplesPerSecond = nextSps
                nextIsFromUserQueue = fromUserQueue
                // isGaplessTransition stays false until armed.
                #if DEBUG
                print("[Q] preload LOADED track=\"\(nextTrack.name)\" fromUserQueue=\(fromUserQueue) — staged, not armed")
                #endif

                // Poll the audio engine's own clock until we're within
                // `armLeadTime` of the current track's end, then arm.
                // This must NOT be driven by `CADisplayLink` because
                // display-link ticks stop firing when the screen is off
                // — the audio engine keeps rendering in background but
                // the UI clock doesn't. Reading
                // `playerNode.lastRenderTime` directly works because the
                // audio thread keeps that timestamp current regardless
                // of screen state.
                while !Task.isCancelled {
                    try Task.checkCancellation()
                    guard gen == scheduleGeneration else { return }
                    let remaining = self.remainingTimeInCurrentTrack()
                    if remaining <= Self.armLeadTime {
                        self.armNextTrackOnEngineIfNeeded()
                        return
                    }
                    // Sleep until we're close to the boundary, with a
                    // 100 ms floor so we don't spin and a generous
                    // ceiling so we re-check periodically even if the
                    // user paused (in which case `remaining` won't
                    // decrease and we want occasional wake-ups in case
                    // playback resumed).
                    let sleepSeconds = max(0.1, min(remaining - Self.armLeadTime, 5.0))
                    try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
                }
            } catch {
                // Pre-loading failed (cancellation or load error) —
                // normal non-gapless transition will happen via handleTrackEnd.
            }
        }
    }

    /// Seconds remaining in the currently playing track, computed from
    /// the audio engine's render-time clock (not the published
    /// `currentTime`, which is only refreshed by the screen-bound
    /// `CADisplayLink` and so goes stale when the device is locked).
    /// Returns `.infinity` if we can't read the clock yet — callers
    /// treat that as "wait, not time to arm yet."
    private func remainingTimeInCurrentTrack() -> TimeInterval {
        guard let snapshot = anchor,
              let nodeTime = playerNode.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return .infinity
        }
        let elapsedSeconds = snapshot.elapsedSeconds(forEngineSampleTime: playerTime.sampleTime)
        return max(0, snapshot.duration - elapsedSeconds)
    }

    /// Take the in-memory pre-loaded next track and actually schedule it
    /// on the player node. After this returns, `isGaplessTransition` is
    /// true and the engine will play the next track immediately when the
    /// current segment ends. Idempotent — called from `updateCurrentTime`
    /// every display tick once we're inside `armLeadTime` of the end.
    private func armNextTrackOnEngineIfNeeded() {
        guard !isGaplessTransition,
              let audioFile = nextAudioFile,
              nextTrackIndex != nil else { return }
        let expectedGen = scheduleGeneration
        isGaplessTransition = true
        playerNode.scheduleSegment(
            audioFile,
            startingFrame: 0,
            frameCount: AVAudioFrameCount(audioFile.length),
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                #if DEBUG
                print("[Q] gaplessCompletion fired expectedGen=\(expectedGen) currentGen=\(self.scheduleGeneration) isGapless=\(self.isGaplessTransition) → \(self.isGaplessTransition && expectedGen == self.scheduleGeneration ? "handleTrackEnd" : "bail")")
                #endif
                guard self.isGaplessTransition, expectedGen == self.scheduleGeneration else { return }
                self.handleTrackEnd()
            }
        }
        #if DEBUG
        print("[Q] arm ARMED on engine expectedGen=\(expectedGen)")
        #endif
    }

    private func clearGaplessState() {
        if isGaplessTransition {
            // Bump generation by 2 to invalidate both the current track's
            // and the pre-scheduled next track's completion handlers
            scheduleGeneration &+= 2
        }
        gaplessLoadTask?.cancel()
        gaplessLoadTask = nil
        nextAudioFile = nil
        nextTrackIndex = nil
        nextFileURL = nil
        nextWaveform = nil
        isGaplessTransition = false
        nextIsFromUserQueue = false
        nextScheduledTrackID = nil
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
            #if DEBUG
            print("Audio session error: \(error.localizedDescription)")
            #endif
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
        // Capture the anchor in a single atomic load. Everything below
        // operates on this self-consistent snapshot — even if a gapless
        // advance swaps in a new anchor between now and the next tick,
        // we'll just compute against the old one this frame and the new
        // one next frame. No possibility of mixing fields across tracks.
        guard !isSeeking,
              let nodeTime = playerNode.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              let snapshot = anchor else { return }

        let time = snapshot.elapsedSeconds(forEngineSampleTime: playerTime.sampleTime)
        if time >= 0 && time <= snapshot.duration {
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
        #if DEBUG
        print("[Q] handleTrackEnd entry currentIndex=\(currentIndex) isGapless=\(isGaplessTransition) nextTrackIndex=\(nextTrackIndex.map(String.init) ?? "nil") nextIsFromUserQueue=\(nextIsFromUserQueue) userQueueLen=\(userQueue.count) repeat=\(repeatMode) scheduleGen=\(scheduleGeneration)")
        #endif
        if repeatMode == .one {
            seek(to: 0)
            play()
            return
        }

        // If the next track was pre-scheduled gaplessly, just update state
        if isGaplessTransition, let nextIndex = nextTrackIndex, let nextFile = nextAudioFile {
            // If the pre-scheduled track came from the user queue, splice
            // it into the album `queue` at `nextIndex` and pop it off the
            // user queue. The advance below then sets `currentIndex` to
            // that slot. After this, `queue[currentIndex]` correctly
            // reports the now-playing track to anything that reads it
            // (currentTrack, the queue UI, Now Playing info, etc.).
            if nextIsFromUserQueue && !userQueue.isEmpty {
                let queuedTrack = userQueue.removeFirst()
                queue.insert(queuedTrack, at: nextIndex)
                #if DEBUG
                print("[Q] handleTrackEnd spliced userQueue track=\"\(queuedTrack.name)\" into queue at idx=\(nextIndex) remainingUserQueue=\(userQueue.count)")
                #endif
            }
            #if DEBUG
            let nextName = (nextIndex >= 0 && nextIndex < queue.count) ? queue[nextIndex].name : "?"
            print("[Q] handleTrackEnd branch=gapless advancing to nextIndex=\(nextIndex) track=\"\(nextName)\" userQueueLen=\(userQueue.count)")
            #endif
            let precomputedWaveform = nextWaveform
            let precomputedSps = nextWaveformSamplesPerSecond
            isGaplessTransition = false
            nextAudioFile = nil
            nextTrackIndex = nil
            nextFileURL = nil
            nextWaveform = nil
            nextWaveformSamplesPerSecond = 0

            // Compute the new anchor deterministically from the outgoing
            // track's bookkeeping. Querying lastRenderTime at the exact
            // track boundary is unreliable — playerTime(forNodeTime:) can
            // return nil right as one segment ends and the next begins.
            // Using `outgoing.totalFrames - outgoing.seekFrame` is always
            // correct regardless of whether the render thread is at a
            // segment boundary, because both values are known statically
            // from our own bookkeeping rather than the engine's clock.
            //
            // The whole anchor (audioFile / seekFrame / playerTimeOffset)
            // is updated in a single struct assignment — `updateCurrentTime`
            // can never see a mix of new-track and old-track fields.
            let outgoing = anchor
            let framesJustPlayed = (outgoing?.totalFrames ?? 0) - (outgoing?.seekFrame ?? 0)
            let newOffset = (outgoing?.playerTimeOffset ?? 0) + framesJustPlayed

            currentIndex = nextIndex
            anchor = PlaybackAnchor(audioFile: nextFile, seekFrame: 0, playerTimeOffset: newOffset)
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

        #if DEBUG
        print("[Q] handleTrackEnd branch=fallthrough calling next() userQueueLen=\(userQueue.count)")
        #endif
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

        // Cancel any in-flight artwork fetch from a previous track —
        // otherwise its `await` can complete after the user has skipped
        // ahead and overwrite the lock-screen artwork with the wrong
        // album's image. After ~20 minutes of an album auto-advancing,
        // multiple stale Tasks could otherwise stack up and the last one
        // to finish would win.
        artworkTask?.cancel()
        artworkTask = nil

        if let album = currentTrack?.album, album.isLocal {
            if let path = album.resolvedLocalCoverPath, let image = UIImage(contentsOfFile: path) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                var updatedInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                updatedInfo[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = updatedInfo
            }
        } else if let coverFileId = currentTrack?.album?.coverFileId, let albumArtService {
            // Snapshot the expected coverFileId at launch time. When the
            // async fetch completes, we verify the current track's
            // coverFileId still matches before writing — a belt-and-
            // suspenders check on top of cancellation in case the
            // cancellation propagation lost a race.
            let expectedCoverFileId = coverFileId
            #if DEBUG
            print("[NP] artworkTask START coverFileId=\(coverFileId)")
            #endif
            artworkTask = Task {
                do {
                    let image = await albumArtService.image(for: coverFileId)
                    try Task.checkCancellation()
                    guard let image else { return }
                    // Final safety check: the current track must still
                    // be the one we were fetching for. If the user has
                    // advanced, drop the result silently — the new
                    // track's `updateNowPlayingInfo` will have already
                    // kicked off its own artwork fetch.
                    guard currentTrack?.album?.coverFileId == expectedCoverFileId else {
                        #if DEBUG
                        print("[NP] artworkTask STALE expected=\(expectedCoverFileId) current=\(currentTrack?.album?.coverFileId ?? "nil") — dropping")
                        #endif
                        return
                    }
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    var updatedInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    updatedInfo[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = updatedInfo
                    #if DEBUG
                    print("[NP] artworkTask APPLIED coverFileId=\(expectedCoverFileId)")
                    #endif
                } catch {
                    // Cancellation — drop quietly.
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
