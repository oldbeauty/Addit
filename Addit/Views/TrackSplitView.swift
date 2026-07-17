import SwiftUI
import SwiftData
import AVFoundation
import UIKit

/// Full-screen, non-destructive track splitter. Built for carving a
/// full-album rip into individual songs: a ~1-minute window of the waveform
/// scrolls under a fixed center playhead (SoundCloud-style) so silence gaps
/// between songs are easy to line up; "Add Split" drops a cut at the
/// playhead. Saving exports each segment as a NEW track in the same album —
/// the master track is never modified or deleted.
struct TrackSplitView: View {
    let track: Track
    let album: Album

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(CloudServiceRouter.self) private var cloudRouter
    @Environment(AudioCacheService.self) private var cacheService
    @Environment(ThemeService.self) private var themeService
    @Environment(AudioPlayerService.self) private var playerService

    private var driveService: any CloudDriveService { cloudRouter.service(for: album) }

    // MARK: State

    private enum Phase: Equatable {
        case loading(String)
        case ready
        case failed(String)
    }

    @State private var phase: Phase = .loading("Preparing audio…")
    @State private var analysisProgress: Double?
    @State private var sourceURL: URL?
    @State private var convertedTempURL: URL?
    @State private var waveform: TrackSplitEngine.Waveform?
    @State private var plan = SplitPlan(duration: 0)

    /// Time under the fixed center playhead. The single scrub state — the
    /// window, minimap, readouts, and Add Split all key off it.
    @State private var centerTime: TimeInterval = 0

    // Scrubbing. No fling physics — the wave stops dead on touch-up so the
    // playhead lands exactly where the finger left it.
    @State private var dragStartCenterTime: TimeInterval?
    @State private var isDragging = false

    // Haptic detents while a finger scrubs: selection ticks at regular time
    // intervals, a firmer thump when the playhead crosses a split boundary.
    @State private var tickHaptic = UISelectionFeedbackGenerator()
    @State private var boundaryHaptic = UIImpactFeedbackGenerator(style: .light)

    // Preview playback — a private AVAudioPlayer, deliberately independent
    // of AudioPlayerService's engine pipeline (we only ask the main player
    // to pause so the two never play over each other).
    @State private var previewPlayer: AVAudioPlayer?
    @State private var isPreviewing = false
    @State private var previewFollowTask: Task<Void, Never>?

    // Rename
    @State private var renamingSegmentID: UUID?
    @State private var renameText = ""

    /// Measured name-capsule widths, keyed by segment id — the label-push
    /// math needs real widths to know when a split line touches a capsule.
    @State private var labelWidths: [UUID: CGFloat] = [:]

    // Save
    @State private var isSaving = false
    @State private var saveStatus = ""
    @State private var savedSegmentIndices: Set<Int> = []
    @State private var savedNamesByIndex: [Int: String] = [:]
    @State private var exportTempDir: URL?
    @State private var saveError: String?
    @State private var showDiscardDialog = false

    // MARK: Layout constants

    /// Seconds of audio visible across the window.
    private let windowDuration: TimeInterval = 60
    /// Top strip of the window reserved for split chips + segment names.
    private let labelDeckHeight: CGFloat = 64
    private let windowHeight: CGFloat = 250

    // MARK: Body

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading(let label): loadingView(label)
                case .failed(let message): failedView(message)
                case .ready: editor
                }
            }
            .navigationTitle(track.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { attemptCancel() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Splits") { Task { await saveSplits() } }
                        .fontWeight(.semibold)
                        .disabled(phase != .ready || !plan.hasSplits || isSaving)
                }
            }
        }
        .task { await prepare() }
        .onDisappear { teardown() }
        .overlay { if isSaving { savingOverlay } }
        .confirmationDialog(
            "Discard your splits?",
            isPresented: $showDiscardDialog,
            titleVisibility: .visible
        ) {
            Button("Discard Splits", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("The original track is never changed — but your unsaved split points will be lost.")
        }
        .selectAllInTextFields(while: renamingSegmentID != nil)
        .alert("Rename Track", isPresented: renameAlertBinding) {
            TextField("Track name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let id = renamingSegmentID {
                    plan.rename(segmentID: id, to: renameText)
                }
            }
        } message: {
            Text("Clear the field to restore the default name.")
        }
        .alert("Couldn't Save Splits", isPresented: saveErrorBinding) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renamingSegmentID != nil },
            set: { if !$0 { renamingSegmentID = nil } }
        )
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }

    // MARK: Loading / failure

    private func loadingView(_ label: String) -> some View {
        VStack(spacing: 16) {
            if let analysisProgress {
                ProgressView(value: analysisProgress)
                    .frame(maxWidth: 220)
                    .tint(themeService.accentColor)
            } else {
                ProgressView()
                    .tint(themeService.accentColor)
            }
            Text(label)
                .font(.uiSubheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Can't Split This Track")
                .font(.uiHeadline)
            Text(message)
                .font(.uiSubheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Editor

    private var editor: some View {
        VStack(spacing: 0) {
            segmentReadout
                .padding(.top, 18)

            Spacer(minLength: 8)

            minimap
                .frame(height: 40)
                .padding(.horizontal, 20)

            timeRow
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 2)

            waveformWindow
                .frame(height: windowHeight)

            Spacer(minLength: 8)

            controls
                .padding(.horizontal, 36)
                .padding(.bottom, 28)
        }
    }

    /// Readout for the segment currently under the playhead: position in the
    /// split sequence, editable name, and bounds.
    private var segmentReadout: some View {
        let index = plan.segmentIndex(containing: centerTime)
        let segment = plan.segments[index]
        return VStack(spacing: 5) {
            Text("TRACK \(index + 1) OF \(plan.segments.count)")
                .font(.readout(10))
                .foregroundStyle(Phosphor.dim)
            Button {
                beginRename(segment)
            } label: {
                HStack(spacing: 6) {
                    Text(plan.displayName(for: segment))
                        .font(.uiHeadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .font(.uiCaption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
            }
            .buttonStyle(.plain)
            Text("\(timeLabel(segment.start))–\(timeLabel(segment.end))")
                .font(.readout(10))
                .foregroundStyle(Phosphor.ghost)
        }
    }

    /// Full-track overview: coarse waveform, split ticks, viewport highlight.
    /// Tap/drag jumps the window anywhere in the file instantly.
    private var minimap: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard let waveform, waveform.duration > 0 else { return }
                let samples = waveform.samples
                let midY = size.height / 2

                // Bars, one per 2pt column.
                let pitch: CGFloat = 2
                let samplesPerColumn = max(1, Int((Double(pitch) / Double(size.width)) * Double(samples.count)))
                var x: CGFloat = 0
                while x < size.width {
                    let i0 = Int((Double(x) / Double(size.width)) * Double(samples.count))
                    let i1 = min(samples.count - 1, i0 + samplesPerColumn)
                    guard i0 <= i1, i0 < samples.count else { break }
                    let peak = samples[i0...i1].max() ?? 0
                    let h = max(1.5, CGFloat(peak) * size.height * 0.9)
                    context.fill(
                        Path(CGRect(x: x, y: midY - h / 2, width: 1.2, height: h)),
                        with: .color(Phosphor.ghost)
                    )
                    x += pitch
                }

                // Viewport window.
                let winStart = CGFloat((centerTime - windowDuration / 2) / waveform.duration) * size.width
                let winWidth = max(6, CGFloat(windowDuration / waveform.duration) * size.width)
                let winRect = CGRect(x: winStart, y: 0, width: winWidth, height: size.height)
                context.fill(Path(roundedRect: winRect, cornerRadius: 3), with: .color(Phosphor.lit.opacity(0.14)))
                context.stroke(Path(roundedRect: winRect, cornerRadius: 3), with: .color(Phosphor.dim), lineWidth: 1)

                // Split ticks.
                for boundary in plan.boundaries {
                    let bx = CGFloat(boundary / waveform.duration) * size.width
                    context.fill(
                        Path(CGRect(x: bx - 0.75, y: 0, width: 1.5, height: size.height)),
                        with: .color(themeService.accentColor)
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let waveform else { return }
                        if !isDragging { prepareScrubHaptics() }
                        isDragging = true
                        let newTime = clampTime(Double(value.location.x / geo.size.width) * waveform.duration)
                        // Coarse detents: ~120 across the whole strip, so the
                        // tick rate tracks finger travel regardless of duration.
                        scrubHaptics(from: centerTime, to: newTime, interval: max(1, waveform.duration / 120))
                        centerTime = newTime
                    }
                    .onEnded { _ in
                        isDragging = false
                        if isPreviewing { previewPlayer?.currentTime = centerTime }
                    }
            )
        }
    }

    /// Start / playhead / total readouts above the window.
    private var timeRow: some View {
        HStack {
            Text(timeLabel(max(0, centerTime - windowDuration / 2)))
                .font(.readout(10))
                .foregroundStyle(Phosphor.ghost)
            Spacer()
            Text(timeLabel(centerTime))
                .font(.readout(16))
                .foregroundStyle(Phosphor.lit)
            Spacer()
            Text(timeLabel(waveform?.duration ?? 0))
                .font(.readout(10))
                .foregroundStyle(Phosphor.ghost)
        }
    }

    /// The main event: a 1-minute sliding window with the playhead fixed at
    /// center, split markers with removable chips, and the neighboring
    /// segment names on either side of every split line.
    private var waveformWindow: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let pointsPerSecond = width / windowDuration
            let bandTop = labelDeckHeight
            let bandHeight = geo.size.height - labelDeckHeight

            ZStack(alignment: .topLeading) {
                // Waveform bars.
                Canvas { context, size in
                    guard let waveform else { return }
                    let samples = waveform.samples
                    let sps = waveform.samplesPerSecond
                    let midY = bandTop + bandHeight / 2

                    // Baseline trace through silence and beyond the file edges.
                    let t0 = clampTime(centerTime - windowDuration / 2)
                    let t1 = clampTime(centerTime + windowDuration / 2)
                    let x0 = size.width / 2 + (t0 - centerTime) * pointsPerSecond
                    let x1 = size.width / 2 + (t1 - centerTime) * pointsPerSecond
                    context.fill(
                        Path(CGRect(x: x0, y: midY - 0.5, width: max(0, x1 - x0), height: 1)),
                        with: .color(Phosphor.ghost.opacity(0.6))
                    )

                    // Anchor each bar to a fixed range of audio buckets (not to
                    // a screen column) so bars keep their own height and slide
                    // horizontally as the window scrolls. `step` buckets per bar
                    // yields ~`pitch` points of spacing at this zoom.
                    let pitch: CGFloat = 3.5
                    let barWidth: CGFloat = 2
                    let step = max(1, Int((Double(pitch) / Double(pointsPerSecond)) * sps))

                    // Only walk the buckets in (or just past) the visible window,
                    // aligned to absolute `step` boundaries so the grouping stays
                    // stable — bars translate rather than re-bin as you scroll.
                    let firstTime = centerTime - windowDuration / 2 - Double(pitch) / Double(pointsPerSecond)
                    let lastTime = centerTime + windowDuration / 2 + Double(pitch) / Double(pointsPerSecond)
                    let startIndex = (max(0, Int(firstTime * sps)) / step) * step
                    let endIndex = min(samples.count, Int(lastTime * sps) + 1)

                    var i = startIndex
                    while i < endIndex {
                        let time = Double(i) / sps
                        let x = size.width / 2 + (time - centerTime) * pointsPerSecond
                        let peak = samples[i..<min(i + step, samples.count)].max() ?? 0
                        let h = max(2.5, CGFloat(peak) * bandHeight * 0.88)
                        let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 1),
                            with: .color(Phosphor.dim)
                        )
                        i += step
                    }
                }

                // Split markers (accent line + remove chip).
                ForEach(Array(plan.boundaries.enumerated()), id: \.element) { boundaryIndex, boundary in
                    let x = width / 2 + CGFloat(boundary - centerTime) * pointsPerSecond
                    if x > -20, x < width + 20 {
                        splitMarker(boundaryIndex: boundaryIndex, at: x, bandTop: bandTop, bandHeight: bandHeight)
                    }
                }

                // Segment names: each capsule gravitates to the screen center
                // but is penned between its own split lines — an approaching
                // split pushes the current name out of center while towing
                // the next segment's name in behind it.
                ForEach(plan.segments) { segment in
                    if let x = nameLabelX(for: segment, width: width, pointsPerSecond: pointsPerSecond) {
                        segmentNameLabel(segment)
                            .position(x: x, y: bandTop - 22)
                    }
                }

                // Fixed center playhead: notch + line through the wave band.
                Triangle()
                    .fill(Phosphor.lit)
                    .frame(width: 11, height: 7)
                    .position(x: width / 2, y: bandTop - 5)
                Rectangle()
                    .fill(Phosphor.lit)
                    .frame(width: 2, height: bandHeight)
                    .position(x: width / 2, y: bandTop + bandHeight / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartCenterTime == nil {
                            dragStartCenterTime = centerTime
                            isDragging = true
                            prepareScrubHaptics()
                        }
                        guard let origin = dragStartCenterTime else { return }
                        let newTime = clampTime(origin - Double(value.translation.width / pointsPerSecond))
                        scrubHaptics(from: centerTime, to: newTime, interval: 1)
                        centerTime = newTime
                    }
                    .onEnded { _ in
                        isDragging = false
                        dragStartCenterTime = nil
                        if isPreviewing {
                            // Scrub-seek: keep playing from the new position.
                            previewPlayer?.currentTime = centerTime
                        }
                    }
            )
        }
    }

    /// One split line: accent rule through the wave band with a removable
    /// chip hanging at its foot. (Names live in their own layer — see
    /// `nameLabelX`.)
    @ViewBuilder
    private func splitMarker(
        boundaryIndex: Int,
        at x: CGFloat,
        bandTop: CGFloat,
        bandHeight: CGFloat
    ) -> some View {
        let accent = themeService.accentColor

        // Line spans the deck bottom through the wave band.
        Rectangle()
            .fill(accent)
            .frame(width: 2, height: bandHeight + 14)
            .position(x: x, y: bandTop + bandHeight / 2 - 7)

        // Remove chip, below the split mark.
        Button {
            withAnimation(.snappy(duration: 0.18)) {
                plan.removeBoundary(at: boundaryIndex)
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(accent, in: Circle())
        }
        .buttonStyle(.plain)
        .position(x: x, y: bandTop + bandHeight - 12)
    }

    /// Where a segment's name capsule sits, or nil when it shouldn't render.
    /// The capsule wants the screen center but is penned between its own
    /// split lines (file edges don't pen), so a line scrolling past first
    /// pushes the centered name away, then hands the center to the next
    /// name it towed in. `nil` = segment too narrow on screen or fully
    /// off-screen.
    private func nameLabelX(for segment: SplitSegment, width: CGFloat, pointsPerSecond: CGFloat) -> CGFloat? {
        // Half the capsule plus a gap, so the push starts the moment the
        // line touches the capsule's edge.
        let half = (labelWidths[segment.id] ?? 100) / 2 + 6
        var lo = -CGFloat.infinity
        var hi = CGFloat.infinity
        if segment.start > 0 {
            lo = width / 2 + CGFloat(segment.start - centerTime) * pointsPerSecond + half
        }
        if segment.end < plan.duration {
            hi = width / 2 + CGFloat(segment.end - centerTime) * pointsPerSecond - half
        }
        guard lo <= hi else { return nil }
        let x = min(max(width / 2, lo), hi)
        guard x > -half, x < width + half else { return nil }
        return x
    }

    private func segmentNameLabel(_ segment: SplitSegment) -> some View {
        Button {
            beginRename(segment)
        } label: {
            Text(plan.displayName(for: segment))
                .font(.uiCaption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(segment.customName == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(uiColor: .systemBackground).opacity(0.85), in: Capsule())
                .frame(maxWidth: 170)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { measured in
            labelWidths[segment.id] = measured
        }
    }

    private var controls: some View {
        HStack(alignment: .top) {
            VStack(spacing: 10) {
                Button {
                    togglePreview()
                } label: {
                    Image(systemName: isPreviewing ? "pause.fill" : "play.fill")
                        .foregroundStyle(.primary)
                }
                .buttonStyle(TactileButtonStyle(diameter: 48))
                Text("PREVIEW")
                    .font(.readout(9))
                    .foregroundStyle(.secondary)
                    .engraved()
            }
            .frame(width: 72)

            Spacer()

            VStack(spacing: 10) {
                Button {
                    addSplit()
                } label: {
                    Image(systemName: "scissors")
                        .foregroundStyle(themeService.accentColor)
                }
                .buttonStyle(TactileButtonStyle(diameter: 62))
                .disabled(!plan.canSplit(at: centerTime))
                .opacity(plan.canSplit(at: centerTime) ? 1 : 0.45)
                Text("ADD SPLIT")
                    .font(.readout(9))
                    .foregroundStyle(.secondary)
                    .engraved()
            }

            Spacer()

            VStack(spacing: 10) {
                Text("\(plan.boundaries.count)")
                    .font(.readout(20))
                    .foregroundStyle(Phosphor.lit)
                    .frame(width: 48, height: 48)
                Text(plan.boundaries.count == 1 ? "SPLIT" : "SPLITS")
                    .font(.readout(9))
                    .foregroundStyle(.secondary)
                    .engraved()
            }
            .frame(width: 72)
        }
    }

    private var savingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .tint(themeService.accentColor)
                Text(saveStatus)
                    .font(.uiSubheadline)
                    .foregroundStyle(.primary)
                Text("Keep Addit open while tracks are saved.")
                    .font(.uiCaption)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: Preparation

    private func prepare() async {
        do {
            phase = .loading("Preparing audio…")
            var url: URL
            if let local = track.localFileURL, FileManager.default.fileExists(atPath: local.path) {
                url = local
            } else if let cached = cacheService.cachedFileURL(for: track) {
                url = cached
            } else {
                phase = .loading("Downloading track…")
                url = try await cacheService.cacheTrack(track)
            }

            // Formats AVAudioFile can't read (and video containers) get a
            // one-off AAC conversion into temp — same approach as playback's
            // convert-on-failure, but private to this session.
            if (try? AVAudioFile(forReading: url)) == nil {
                phase = .loading("Converting audio…")
                let converted = FileManager.default.temporaryDirectory
                    .appendingPathComponent("split-convert-\(UUID().uuidString).m4a")
                try await TrackSplitEngine.exportAudio(from: url, to: converted, allowPassthrough: false)
                convertedTempURL = converted
                url = converted
            }
            sourceURL = url

            phase = .loading("Analyzing waveform…")
            analysisProgress = 0
            let loaded = try await TrackSplitEngine.loadWaveform(from: url) { fraction in
                Task { @MainActor in analysisProgress = fraction }
            }
            analysisProgress = nil

            guard loaded.duration >= 2 * SplitPlan.minimumSegmentLength else {
                phase = .failed("This track is too short to split.")
                return
            }

            waveform = loaded
            plan = SplitPlan(duration: loaded.duration)
            centerTime = 0
            phase = .ready
        } catch is CancellationError {
            // View dismissed mid-load.
        } catch {
            analysisProgress = nil
            phase = .failed(error.localizedDescription)
        }
    }

    private func teardown() {
        previewFollowTask?.cancel()
        previewPlayer?.stop()
        previewPlayer = nil
        if let convertedTempURL {
            try? FileManager.default.removeItem(at: convertedTempURL)
        }
        if let exportTempDir {
            try? FileManager.default.removeItem(at: exportTempDir)
        }
    }

    // MARK: Scrubbing

    private func clampTime(_ time: TimeInterval) -> TimeInterval {
        min(max(time, 0), waveform?.duration ?? 0)
    }

    // MARK: Scrub haptics

    private func prepareScrubHaptics() {
        tickHaptic.prepare()
        boundaryHaptic.prepare()
    }

    /// Detents for one scrub step: a firmer thump when the playhead crosses
    /// a split boundary, otherwise a selection tick each time it enters a new
    /// `interval`-second slot. Call only from active drag gestures — preview
    /// follow moves `centerTime` too and must stay silent.
    private func scrubHaptics(from oldTime: TimeInterval, to newTime: TimeInterval, interval: TimeInterval) {
        guard oldTime != newTime else { return }
        let lo = min(oldTime, newTime)
        let hi = max(oldTime, newTime)
        if plan.boundaries.contains(where: { $0 > lo && $0 <= hi }) {
            boundaryHaptic.impactOccurred()
            boundaryHaptic.prepare()
        } else if Int(oldTime / interval) != Int(newTime / interval) {
            tickHaptic.selectionChanged()
            tickHaptic.prepare()
        }
    }

    // MARK: Split actions

    private func addSplit() {
        guard plan.canSplit(at: centerTime) else { return }
        withAnimation(.snappy(duration: 0.18)) {
            plan.addSplit(at: centerTime)
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func beginRename(_ segment: SplitSegment) {
        renameText = plan.displayName(for: segment)
        renamingSegmentID = segment.id
    }

    private func attemptCancel() {
        stopPreview()
        if plan.hasSplits {
            showDiscardDialog = true
        } else {
            dismiss()
        }
    }

    // MARK: Preview

    private func togglePreview() {
        if isPreviewing {
            stopPreview()
            return
        }
        guard let sourceURL else { return }
        if previewPlayer == nil {
            previewPlayer = try? AVAudioPlayer(contentsOf: sourceURL)
        }
        guard let player = previewPlayer, let waveform else { return }

        // Never play over the main engine.
        if playerService.isPlaying { playerService.pause() }
        try? AVAudioSession.sharedInstance().setActive(true)

        player.currentTime = min(centerTime, max(0, waveform.duration - 0.1))
        guard player.play() else { return }
        isPreviewing = true

        previewFollowTask?.cancel()
        previewFollowTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                if Task.isCancelled { return }
                guard let player = previewPlayer else { return }
                if !player.isPlaying {
                    isPreviewing = false
                    return
                }
                if !isDragging {
                    centerTime = clampTime(player.currentTime)
                }
            }
        }
    }

    private func stopPreview() {
        previewFollowTask?.cancel()
        previewFollowTask = nil
        previewPlayer?.pause()
        isPreviewing = false
    }

    // MARK: Save

    private func saveSplits() async {
        guard let sourceURL, plan.hasSplits, !isSaving else { return }
        stopPreview()
        isSaving = true
        defer { isSaving = false }

        let fileManager = FileManager.default
        let segments = plan.segments
        let total = segments.count

        let tempDir: URL
        if let exportTempDir {
            tempDir = exportTempDir
        } else {
            tempDir = fileManager.temporaryDirectory
                .appendingPathComponent("track-split-\(UUID().uuidString)", isDirectory: true)
            try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            exportTempDir = tempDir
        }

        var existingNames = Set(album.tracks.map(\.name))

        do {
            for (index, segment) in segments.enumerated() {
                if savedSegmentIndices.contains(index) { continue }

                saveStatus = "Exporting track \(index + 1) of \(total)…"
                let base = TrackSplitEngine.sanitizedFileName(plan.displayName(for: segment))
                let fileName = TrackSplitEngine.uniqueFileName(base: base, ext: "m4a", existing: existingNames)
                let exportURL = tempDir.appendingPathComponent(fileName)
                try await TrackSplitEngine.exportAudio(
                    from: sourceURL, to: exportURL,
                    start: segment.start, end: segment.end
                )
                let fileSize = (try? exportURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    .map { Int64($0) }

                let newTrack: Track
                if album.isLocal {
                    let dirName = album.googleFolderId.hasPrefix("local_")
                        ? String(album.googleFolderId.dropFirst("local_".count))
                        : album.googleFolderId
                    let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let albumDir = documents.appendingPathComponent("LocalAlbums/\(dirName)", isDirectory: true)
                    try fileManager.createDirectory(at: albumDir, withIntermediateDirectories: true)
                    let destination = albumDir.appendingPathComponent(fileName)
                    try? fileManager.removeItem(at: destination)
                    try fileManager.copyItem(at: exportURL, to: destination)
                    newTrack = Track(
                        googleFileId: "local_\(UUID().uuidString)",
                        name: fileName,
                        album: album,
                        durationSeconds: segment.length,
                        mimeType: "audio/x-m4a",
                        fileSize: fileSize,
                        trackNumber: track.trackNumber + index + 1,
                        localFilePath: "LocalAlbums/\(dirName)/\(fileName)"
                    )
                } else {
                    saveStatus = "Uploading track \(index + 1) of \(total)…"
                    let data = try Data(contentsOf: exportURL)
                    let item = try await driveService.createFile(
                        name: fileName,
                        mimeType: "audio/x-m4a",
                        inFolder: album.googleFolderId,
                        data: data
                    )
                    newTrack = Track(
                        googleFileId: item.id,
                        name: item.name,
                        album: album,
                        durationSeconds: segment.length,
                        mimeType: item.mimeType,
                        fileSize: item.fileSizeBytes ?? fileSize,
                        trackNumber: track.trackNumber + index + 1,
                        modifiedTime: item.modifiedTime
                    )
                    // Seed the cache with the bytes we just uploaded so the
                    // new track plays without an immediate re-download.
                    try? cacheService.storeCachedFile(for: newTrack, from: exportURL)
                }

                modelContext.insert(newTrack)
                album.trackCount += 1
                try? modelContext.save()
                savedSegmentIndices.insert(index)
                savedNamesByIndex[index] = newTrack.name
                existingNames.insert(newTrack.name)
            }
        } catch {
            let done = savedSegmentIndices.count
            saveError = done > 0
                ? "Saved \(done) of \(total) tracks — \(error.localizedDescription) Tap Save Splits again to retry the rest."
                : error.localizedDescription
            return
        }

        saveStatus = "Updating track order…"
        let orderedNewNames = savedNamesByIndex.sorted { $0.key < $1.key }.map(\.value)
        await updateOrdering(newNames: orderedNewNames)
        try? modelContext.save()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }

    /// Places the new tracks right after the master in the album ordering
    /// (`.addit-data` for cloud albums, `cachedTracklist` for local) and
    /// renumbers. Cloud persistence is best-effort: on failure the local
    /// order is still correct and the next metadata save re-syncs it.
    private func updateOrdering(newNames: [String]) async {
        let newNameSet = Set(newNames)
        let allTracks = album.tracks.sorted { $0.trackNumber < $1.trackNumber }

        var baseList = album.cachedTracklist
        var remoteArtist: String?
        var additDataFileId = album.additDataFileId

        if !album.isLocal {
            // Prefer the remote list so a collaborator's recent reorder
            // isn't clobbered by a stale local mirror.
            if additDataFileId == nil {
                additDataFileId = try? await driveService
                    .findFile(named: ".addit-data", inFolder: album.googleFolderId)?.id
            }
            if let fileId = additDataFileId,
               let data = try? await driveService.downloadFileData(fileId: fileId),
               let metadata = try? JSONDecoder().decode(AdditMetadata.self, from: data) {
                if let remoteList = metadata.tracklist { baseList = remoteList }
                remoteArtist = metadata.artist
            }
        }
        if baseList.isEmpty {
            baseList = allTracks.map(\.name).filter { !newNameSet.contains($0) }
        } else {
            baseList.removeAll { newNameSet.contains($0) }
        }

        let updatedList = TrackSplitEngine.inserting(names: newNames, after: track.name, into: baseList)
        TrackSplitEngine.renumber(tracks: allTracks, accordingTo: updatedList)
        album.cachedTracklist = updatedList

        guard !album.isLocal else { return }
        let metadata = AdditMetadata(tracklist: updatedList, artist: remoteArtist ?? album.artistName)
        guard let payload = try? JSONEncoder().encode(metadata) else { return }
        do {
            if let fileId = additDataFileId {
                _ = try await driveService.updateFileData(
                    fileId: fileId, data: payload, mimeType: "application/json"
                )
            } else {
                let created = try await driveService.createFile(
                    name: ".addit-data", mimeType: "application/json",
                    inFolder: album.googleFolderId, data: payload
                )
                album.additDataFileId = created.id
            }
        } catch {
            // Best-effort — order already applied locally.
        }
    }

    // MARK: Helpers

    private func timeLabel(_ seconds: TimeInterval) -> String {
        TrackSplitEngine.timestamp(seconds, includeHours: (waveform?.duration ?? 0) >= 3600)
    }
}

/// Downward-pointing playhead notch.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
