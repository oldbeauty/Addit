---
name: audio-playback
description: Deep internals of Addit's AudioPlayerService — the two-phase gapless pipeline, PlaybackAnchor atomic snapshot, user-queue splicing, the cancellable-Task pattern, the NowPlayingView UIKit pager, and PixelSortCoverView. READ THIS before editing playback, queue, gapless transitions, or now-playing UI; these invariants are subtle and easy to revert.
---

# Audio playback internals (Addit)

The most load-bearing, least-obvious code in the app. It is easy to "fix"
backwards. Read the relevant section here before changing
`Services/AudioPlayerService.swift` or the now-playing UI.

## Two-phase gapless pipeline

The design satisfies four constraints that fight each other:

1. Gapless transitions require **pre-scheduling** the next segment on
   `playerNode` before the current ends (the engine reads ahead).
2. The **user queue takes priority** over album order — a queue tap must
   override the next album track even if it's already pre-scheduled.
3. Background gapless must work **with the screen locked**.
4. Queue mutations must **not cause audible pauses** (`playerNode.stop()`
   buffer-flush is ~10–30ms of silence).

### The pipeline (two phases)

- **Phase 1 — Preload** (`scheduleNextTrackGapless`): loads the `AVAudioFile` +
  waveform into memory. **Does not touch the engine.** Runs at track start.
- **Phase 2 — Arm** (`armNextTrackOnEngineIfNeeded`): calls
  `playerNode.scheduleSegment`. Triggered by a **polling `Task`** (NOT
  `CADisplayLink`) watching `playerNode.lastRenderTime`, firing when the current
  track has `armLeadTime` (0.5s) remaining.

**Why polling, not CADisplayLink, for the arm trigger:** `CADisplayLink` stops
ticking when the screen is off. The audio engine keeps rendering in background
(`UIBackgroundModes = audio`), but the UI clock goes dark. Polling
`lastRenderTime` works because that timestamp is maintained on the **audio
thread** regardless of screen state.

### Queue mutations

`rebuildGaplessIfNeeded` branches on phase:
- **Still in Phase 1** (common — mutation >500ms before the boundary): cancel
  the load `Task` and re-preload. **Engine untouched, no pause.**
- **Already in Phase 2** (rare): fall back to `replaceCurrentScheduling`, which
  does the `stop()` rebuild dance with the brief audible pause.

## `PlaybackAnchor` — atomic snapshot (do not split)

`currentAudioFile`, `seekFrameOffset`, `playerTimeOffset` are bundled into one
`PlaybackAnchor` struct. Every mutation builds a new struct and swaps it in **one
statement**; every reader (esp. `updateCurrentTime`) captures the whole triple in
**one load**. DO NOT split these back into separate fields — the relationships
are now encoded in the type and partial-read races are eliminated by
construction.

- `playerTimeOffset` accumulates across gapless transitions (tracks
  `playerNode.sampleTime` cumulatively). Resets to 0 on `playerNode.stop()` and
  in `replaceCurrentScheduling`.
- `handleTrackEnd` uses the deterministic `framesJustPlayed = totalFrames -
  seekFrame` (NOT `lastRenderTime` at the boundary) because
  `playerTime(forNodeTime:)` can return `nil` exactly at segment boundaries.

## `nextIsFromUserQueue` + queue splicing

When the gapless target came from `userQueue`, `handleTrackEnd`'s gapless branch
splices `userQueue.removeFirst()` into `queue` at `nextIndex` before advancing
`currentIndex`, so `queue[currentIndex]` reports the now-playing track. The flag
is checked then cleared in the same branch. The UI's `currentTrack` and queue
display depend on this exact splice — change it and both break.

## Cancellable async `Task` pattern (mandatory for new async work)

Three `@ObservationIgnored private var task: Task<Void, Never>?` fields —
`gaplessLoadTask`, `artworkTask`, `prefetchTask` — follow: `task?.cancel()`
before kicking off a new one, `try Task.checkCancellation()` after each `await`,
and compare-at-write checks before mutating state. This stops stale Tasks from
clobbering current state after the user moves on. Any new async work in this
service MUST follow it — **no fire-and-forget bare `Task { … }`** for anything
touching Observable state.

## NowPlayingView — UIKit-bridged horizontal pager

The horizontal swipe between album cover and EQ visualizer uses
`HorizontalPagerGesture` (a `UIViewRepresentable` wrapping
`UIPanGestureRecognizer`), NOT SwiftUI `DragGesture`/`TabView`. SwiftUI gestures
(even via `.simultaneousGesture`) latch the touch in a way that blocks the
sheet's swipe-down-to-dismiss UIKit recognizer. The UIKit pan's delegate sets
`gestureRecognizerShouldBegin` to refuse vertical motion, letting the sheet's
recognizer handle vertical drags unblocked. Do not "simplify" this back to
SwiftUI gestures.

## PixelSortCoverView — design intent

Shear-sort over a 96×96 luminance grid. Every swap is recorded into a flat array;
tapping the sorted state replays the log **in reverse** for the un-sort
animation — the swap log is the cheap reverse mechanism (no recursion, no
recomputation). Tap states: `idle → sorting → pausedMidSort → reverting →
pausedMidRevert → idle`. Throttled to ~400 swaps/frame.

## Outstanding / verification queue

- The three audit suspects (queue race, artwork race, `handleTrackEnd` field
  race) are addressed via `PlaybackAnchor` + the cancellable-Task pattern. Fixes
  are recent and want a long real-world listening session to confirm no
  regressions.
- No test target — verify by building (`xcodebuild … build`) and reading
  `[Q]`/`[NP]` logs during a repro.
