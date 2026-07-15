import Foundation
import AVFoundation
import Accelerate
import SwiftData

// MARK: - Split plan (segments + naming rules)

/// One contiguous slice of the master track in a split session.
struct SplitSegment: Identifiable, Equatable {
    let id: UUID
    var start: TimeInterval
    var end: TimeInterval
    /// User-assigned name. `nil` = derive the timestamped default from the
    /// current bounds (so defaults recompute when neighboring splits move).
    var customName: String?

    var length: TimeInterval { end - start }
}

/// The editable state of a split session: an always-contiguous, always-sorted
/// list of segments covering `0…duration`. Pure value type — all the naming
/// edge-case rules live here, away from the view.
struct SplitPlan {
    private(set) var segments: [SplitSegment]
    let duration: TimeInterval
    /// Name embedded in default segment names. If the master is itself a
    /// previously saved split ("03:45 - 07:12 Foo"), the timestamp prefix is
    /// stripped so re-splitting a split doesn't nest prefixes unboundedly.
    let baseName: String
    /// Uniform timestamp width for every name of this master (hours iff the
    /// master runs ≥ 1 h) — keeps lexicographic order == chronological order.
    let showsHours: Bool

    /// Refuse splits that would create a segment shorter than this.
    static let minimumSegmentLength: TimeInterval = 1.0

    init(duration: TimeInterval, masterDisplayName: String) {
        self.duration = duration
        self.showsHours = duration >= 3600
        self.baseName = Self.strippingTimestampPrefix(from: masterDisplayName)
        self.segments = [SplitSegment(id: UUID(), start: 0, end: duration, customName: nil)]
    }

    /// Interior split points (segment boundaries), ascending.
    var boundaries: [TimeInterval] { segments.dropLast().map(\.end) }
    var hasSplits: Bool { segments.count > 1 }

    func segmentIndex(containing time: TimeInterval) -> Int {
        var index = 0
        for (i, segment) in segments.enumerated() where time >= segment.start { index = i }
        return index
    }

    func canSplit(at time: TimeInterval) -> Bool {
        guard duration > 0 else { return false }
        let segment = segments[segmentIndex(containing: time)]
        return time - segment.start >= Self.minimumSegmentLength
            && segment.end - time >= Self.minimumSegmentLength
    }

    /// Split the segment containing `time`. The left piece — the one that
    /// keeps the original segment's start — keeps any custom name; the right
    /// piece starts fresh with a timestamped default.
    mutating func addSplit(at time: TimeInterval) {
        guard canSplit(at: time) else { return }
        let index = segmentIndex(containing: time)
        let old = segments[index]
        let left = SplitSegment(id: old.id, start: old.start, end: time, customName: old.customName)
        let right = SplitSegment(id: UUID(), start: time, end: old.end, customName: nil)
        segments.replaceSubrange(index...index, with: [left, right])
    }

    /// Remove boundary `boundaries[index]`, merging its two neighbors. The
    /// merged segment prefers the left neighbor's custom name (it keeps the
    /// left start), falling back to the right's so a deliberate rename
    /// survives the merge whenever one exists.
    mutating func removeBoundary(at index: Int) {
        guard index >= 0, index < segments.count - 1 else { return }
        let left = segments[index]
        let right = segments[index + 1]
        let merged = SplitSegment(
            id: left.id, start: left.start, end: right.end,
            customName: left.customName ?? right.customName
        )
        segments.replaceSubrange(index...(index + 1), with: [merged])
    }

    /// Set a custom name. Whitespace-only input clears the custom name,
    /// restoring the timestamped default.
    mutating func rename(segmentID: UUID, to name: String) {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        segments[index].customName = trimmed.isEmpty ? nil : trimmed
    }

    func displayName(for segment: SplitSegment) -> String {
        segment.customName ?? defaultName(for: segment)
    }

    func defaultName(for segment: SplitSegment) -> String {
        let start = TrackSplitEngine.timestamp(segment.start, includeHours: showsHours)
        let end = TrackSplitEngine.timestamp(segment.end, includeHours: showsHours)
        return "\(start) - \(end) \(baseName)"
    }

    /// "03:45 - 07:12 Foo" → "Foo"; anything else passes through unchanged.
    private static func strippingTimestampPrefix(from name: String) -> String {
        let pattern = #/^\d{1,2}(?::\d{2}){1,2}\ -\ \d{1,2}(?::\d{2}){1,2}\ /#
        guard let match = name.prefixMatch(of: pattern) else { return name }
        let remainder = String(name[match.range.upperBound...])
        return remainder.isEmpty ? name : remainder
    }
}

// MARK: - Engine (waveform, export, bookkeeping)

enum SplitError: LocalizedError {
    case unreadableAudio
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .unreadableAudio: return "This audio file can't be read for splitting."
        case .exportFailed: return "Couldn't export the audio segment."
        }
    }
}

/// Pure helpers for the track-split feature: waveform extraction for the
/// editor, segment export, and tracklist bookkeeping. UI lives in
/// `TrackSplitView`; nothing here touches services or views.
enum TrackSplitEngine {

    // MARK: Waveform

    struct Waveform: Sendable {
        /// Normalized 0…1 peak per bucket, `samplesPerSecond` buckets per
        /// second of audio.
        let samples: [Float]
        let samplesPerSecond: Double
        let duration: TimeInterval
    }

    /// Bucket density for the split editor. 16/s keeps a 90-minute album rip
    /// under ~90k floats while leaving several buckets inside any ≥1 s
    /// silence gap, so transitions stay visible after peak-downsampling to
    /// screen bars.
    private static let bucketsPerSecond: Double = 16

    /// Reads the whole file once (sequential, chunked) and returns peak
    /// buckets. Sibling of `AudioPlayerService.extractWaveform` (private,
    /// per-bar seeking, no progress reporting) — duplicated rather than
    /// shared so the load-bearing player service stays untouched.
    ///
    /// Runs synchronously inside an async context; yields between chunks and
    /// honors task cancellation.
    static func loadWaveform(
        from url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Waveform {
        let file = try AVAudioFile(forReading: url)
        let totalFrames = file.length
        let sampleRate = file.processingFormat.sampleRate
        guard totalFrames > 0, sampleRate > 0 else { throw SplitError.unreadableAudio }

        let duration = Double(totalFrames) / sampleRate
        let bucketCount = max(60, Int(duration * bucketsPerSecond))
        let framesPerBucket = max(1, Int(totalFrames) / bucketCount)
        let channelCount = Int(file.processingFormat.channelCount)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: 65_536
        ) else { throw SplitError.unreadableAudio }

        var peaks = [Float](repeating: 0, count: bucketCount)
        var framePosition = 0
        var lastReported = 0.0

        while framePosition < Int(totalFrames) {
            try Task.checkCancellation()
            buffer.frameLength = 0
            try file.read(into: buffer)
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0, let channelData = buffer.floatChannelData else { break }

            // Walk the chunk bucket-by-bucket so each vDSP peak scan stays
            // within a single bucket's frame range.
            var local = 0
            while local < frameCount {
                let globalFrame = framePosition + local
                let bucket = min(bucketCount - 1, globalFrame / framesPerBucket)
                let bucketEndFrame = (bucket + 1) * framesPerBucket
                let sliceLength = min(frameCount - local, max(1, bucketEndFrame - globalFrame))
                var slicePeak: Float = 0
                for channel in 0..<channelCount {
                    var channelPeak: Float = 0
                    vDSP_maxmgv(channelData[channel] + local, 1, &channelPeak, vDSP_Length(sliceLength))
                    slicePeak = max(slicePeak, channelPeak)
                }
                peaks[bucket] = max(peaks[bucket], slicePeak)
                local += sliceLength
            }

            framePosition += frameCount
            let fraction = Double(framePosition) / Double(totalFrames)
            if fraction - lastReported >= 0.01 {
                lastReported = fraction
                progress(fraction)
            }
            await Task.yield()
        }

        var maxPeak: Float = 0
        vDSP_maxv(peaks, 1, &maxPeak, vDSP_Length(bucketCount))
        if maxPeak > 0 {
            var scale = 1 / maxPeak
            vDSP_vsmul(peaks, 1, &scale, &peaks, 1, vDSP_Length(bucketCount))
        }

        return Waveform(
            samples: peaks,
            samplesPerSecond: Double(bucketCount) / duration,
            duration: duration
        )
    }

    // MARK: Export

    /// Exports `sourceURL` (optionally a `start…end` slice) as an .m4a at
    /// `destinationURL`. Tries a lossless passthrough first — for the common
    /// AAC case it's a fast packet copy; codecs an .m4a can't carry (mp3,
    /// flac, …) throw and fall through to the AAC re-encode preset.
    /// `allowPassthrough: false` skips the passthrough attempt (used when
    /// converting a file whose codec is already known to be unplayable).
    static func exportAudio(
        from sourceURL: URL,
        to destinationURL: URL,
        start: TimeInterval? = nil,
        end: TimeInterval? = nil,
        allowPassthrough: Bool = true
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let presets = allowPassthrough
            ? [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A]
            : [AVAssetExportPresetAppleM4A]

        var lastError: Error = SplitError.exportFailed
        for preset in presets {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            if let start, let end {
                let scale: CMTimeScale = 44_100
                session.timeRange = CMTimeRange(
                    start: CMTime(seconds: start, preferredTimescale: scale),
                    end: CMTime(seconds: end, preferredTimescale: scale)
                )
            }
            do {
                try? FileManager.default.removeItem(at: destinationURL)
                try await session.export(to: destinationURL, as: .m4a)
                return
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }
        throw lastError
    }

    // MARK: Naming

    /// "mm:ss" (or "h:mm:ss" when `includeHours`) with zero-padded fields so
    /// same-width names sort lexicographically in chronological order.
    static func timestamp(_ seconds: TimeInterval, includeHours: Bool) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return includeHours
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    /// Makes a segment name safe as a file name on-device and in Drive.
    /// Colons are legal on both (default names contain them); slashes and
    /// leading dots are not.
    static func sanitizedFileName(_ name: String) -> String {
        var cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\0", with: "")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// "Base.ext", or "Base 2.ext", "Base 3.ext", … until unique.
    static func uniqueFileName(base: String, ext: String, existing: Set<String>) -> String {
        let candidate = "\(base).\(ext)"
        guard existing.contains(candidate) else { return candidate }
        var counter = 2
        while existing.contains("\(base) \(counter).\(ext)") { counter += 1 }
        return "\(base) \(counter).\(ext)"
    }

    // MARK: Tracklist bookkeeping

    /// Inserts the new split names right after the master track's entry
    /// (appends at the end when the master isn't listed).
    static func inserting(names newNames: [String], after masterName: String, into tracklist: [String]) -> [String] {
        var list = tracklist
        if let index = list.firstIndex(of: masterName) {
            list.insert(contentsOf: newNames, at: index + 1)
        } else {
            list.append(contentsOf: newNames)
        }
        return list
    }

    /// Reassigns `trackNumber` to match a tracklist (same matching rules as
    /// AlbumDetailView's `.addit-data` sync: first unmatched name wins, disc
    /// markers skipped, unlisted tracks keep their relative order at the end).
    static func renumber(tracks: [Track], accordingTo tracklist: [String]) {
        var counter = 0
        var matched = Set<PersistentIdentifier>()
        for name in tracklist where !name.hasPrefix(AdditMetadata.discMarkerPrefix) {
            guard let track = tracks.first(where: {
                $0.name == name && !matched.contains($0.persistentModelID)
            }) else { continue }
            counter += 1
            track.trackNumber = counter
            matched.insert(track.persistentModelID)
        }
        for track in tracks where !matched.contains(track.persistentModelID) {
            counter += 1
            track.trackNumber = counter
        }
    }
}
