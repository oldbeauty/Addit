---
name: audio-playback
description: Deep internals of Addit's AudioPlayerService — the two-phase gapless pipeline, PlaybackAnchor atomic snapshot, user-queue splicing, the cancellable-Task pattern, how a failed load reports why (PlaybackFailure), the NowPlayingView UIKit pager, and PixelSortCoverView. READ THIS before editing playback, queue, gapless transitions, or now-playing UI; these invariants are subtle and easy to revert.
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

## Two counters, two questions (do not conflate)

- **`scheduleGeneration`** — "are the engine's queued completions still
  valid?" Bumped by everything that touches the node: pause, seek,
  interruption, route change, `replaceCurrentScheduling`, `forget`.
- **`loadToken`** — "is this still the load anybody wants?" Bumped **only** by
  `beginLoadAndPlay`.

A load's staleness must be keyed on `loadToken`. Keying it on
`scheduleGeneration` means a pause *during a download* abandons the load, and
`currentIndex` is then left naming a track whose audio was never anchored.

Corollary that cost a silent stop: **stamp the generation for a segment
*after* the suspensions that precede scheduling it, not before.** `loadAndPlay`
used to capture `gen` at the top and hand it to the completion handler it
registered after the download. Any bump in between — one interruption, one
route change — orphaned that completion permanently, so the track played to its
end and nothing advanced. No error, no log; just silence at a boundary.

## `beginLoadAndPlay` is the only way in

Every transport entry point (`playAlbum`, `playTrack`, `next`, `previous`) calls
`beginLoadAndPlay()`. **Never `Task { await loadAndPlay() }` directly.** The
three statements it runs *synchronously*, before the Task body, are the point:

- `loadTask?.cancel()` — one load at a time. Two concurrent loads each schedule
  a segment, so the superseded track plays through *before* the requested one
  while `currentIndex` names the latter.
- `scheduleGeneration &+= 1` and `isLoadingTrack = true` — the outgoing track's
  completion is still armed until these run. A track that ends in the gap calls
  `handleTrackEnd` → `next()` and advances a second time (press next as a track
  ends, skip two).

Inside the load, bail on `token != loadToken` **without touching `isLoading` /
`isLoadingTrack`** — the live load owns them. Same in the `catch`, or every skip
through a downloading track raises a failure alert.

## `desiredNextTrack()` is the single definition of "next"

`scheduleNextTrackGapless` stages what it returns; `rebuildGaplessIfNeeded`
compares against it. They were once two hand-kept copies of the same branch and
had already drifted (`queue.first` vs `queue[0]` — same track, different
behaviour on an empty queue).

The comparison is on **`(trackID, fromUserQueue)`**, not the ID alone.
Provenance is half the staged identity: the same track can be next both as the
album's following track and as the head of `userQueue`, and only the latter
makes `handleTrackEnd` splice it in and pop the queue. ID-only comparison
no-op'd exactly there — queue the track already up next and it played twice,
with the queue entry never consumed. `nextIsFromUserQueue` is therefore staked
out beside `nextScheduledTrackID` when the load *starts*, not when it stages.

A provenance-only change on an already-staged track takes neither rebuild path.
The audio is the same file either way, so `rebuildGaplessIfNeeded` re-stamps
`nextIsFromUserQueue` / `nextTrackIndex` in place and returns — **engine
untouched**. Falling through to `replaceCurrentScheduling` would stop the node
to re-arm the segment already on it, costing the current track a buffer flush
in its last half second to change nothing but a `Bool`. The test is *staged*
(`nextAudioFile` and `nextTrackIndex` both set), not *armed*: past that point
the preload Task has left its staging block for the arm poll and can no longer
clobber these from the values it captured.

## Cancellable async `Task` pattern (mandatory for new async work)

Four `@ObservationIgnored private var task: Task<Void, Never>?` fields —
`loadTask`, `gaplessLoadTask`, `artworkTask`, `prefetchTask` — follow: `task?.cancel()`
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
vertical drag that closes the player. The UIKit pan's delegate sets
`gestureRecognizerShouldBegin` to refuse vertical motion, letting that drag
through unblocked. Do not "simplify" this back to SwiftUI gestures.

The dismiss recognizer this defers to used to be a sheet's; the player is now
`NowPlayingPill` — one glass card that is both the mini bar and the full player
— so it's `NowPlayingPill`'s own `DragGesture` instead. Same requirement on the
pager, different thing on the receiving end.

## Interruptions — stop the node, NOT the engine

`.began` calls `suspendPlayback(stopEngine: false)`. Both halves matter, and
they were each learned from a failed call test.

**Stop the node.** iOS does not reliably stop playback for you: through a call
the node goes on rendering into a dead session. Leave it and the sample clock
advances for the whole call, so the position jumps by the call's length when the
display link returns — and `play()` afterwards is a no-op on a node that was
never stopped, so the resume is silent while `isPlaying` is true, the button
shows "pause" over silence, the next tap pauses for real, and only the one after
that plays.

**Leave the engine running.** Stopping it as well costs the `.ended`
notification outright — it arrived while the engine kept running and stopped
arriving the moment we stopped it, so playback never resumed on its own again.
(iOS handing the session back, or suspending an app with no audio to render;
same remedy either way.) A running engine with a stopped node just renders
silence, so it costs nothing.

That combination is why `play()` keys off **`needsRescheduleOnPlay`** and not
`!engine.isRunning`. With the engine still up there is nothing in its state that
says the node was emptied. Every site that schedules the current segment
(`seek`, `replaceCurrentScheduling`, `loadAndPlay`, and `play()` itself) must
clear that flag — leave it set and the segment is queued twice, which plays the
track through and then plays it again from the top.

`pause()` is `suspendPlayback(stopEngine: true)` plus voiding the resume debt.
Only a *real* pause voids it; an interruption must not, because a call raises
`.began` twice (ring, then connect) and the second arrives with `isPlaying`
already false.

`.ended` goes through `resumeAfterInterruption()`, which retries (immediately,
+400 ms, +1200 ms) rather than trying once. The call is still tearing its session
down when the notification lands and the route is still settling, so
`engine.start()` throws on the first attempt — that's "it didn't come back on
its own, but pressing play worked", since a human takes longer than the hardware
to settle. Two deliberate choices in there: `.shouldResume` is **not** required
(it's an unreliable hint, and `setActive(true)` failing is the real gate on
whether we're allowed the session), and retrying is safe for the same reason.

`.AVAudioEngineConfigurationChange` is the second half of the same bug.
`setupEngine` connects with `format: nil`, so a call moving the route to the
receiver and back invalidates the connection; `engine.start()` then succeeds and
renders nothing. `handleEngineConfigurationChange` reconnects, and is written to
be correct in either delivery order relative to `.ended`.

**Nothing may activate the session while `isInterrupted` is set.** That flag
runs `.began` → `.ended`, and the reason it exists is that a configuration
change fires when the *call* takes the route — at the **start** of an
interruption, not only at the end. Resuming on it put music into a live call at
ducked volume, and cost us the `.ended` notification entirely: `setActive(true)`
mid-call tells the system the interruption is over, so there is nothing left for
it to end, and playback then never resumes on its own afterwards. A call also
raises `.began` more than once (ring, then connect), so the second one must find
the resume debt still standing rather than clearing it.

## PixelSortCoverView — design intent

Shear-sort over a 96×96 luminance grid. Every swap is recorded into a flat array;
tapping the sorted state replays the log **in reverse** for the un-sort
animation — the swap log is the cheap reverse mechanism (no recursion, no
recomputation). Tap states: `idle → sorting → pausedMidSort → reverting →
pausedMidRevert → idle`. Throttled to ~400 swaps/frame.

## A failed load says why (`PlaybackFailure`)

Every failure in `loadAndPlay` used to land in one `catch` that reported
"Unable to play this audio format". The commonest real cause was nothing of the
kind: play a track that isn't downloaded, lock the phone, and with nothing
playing yet iOS suspended the app mid-download; on unlocking, the dead
connection was announced as a codec problem (reported 2026-10-02).

- **Each stage throws its own reason**: fetching (`Reason(downloadError:
  suspended:)` — connection, sign-in, 404/403, 429/5xx), a missing local file,
  decoding after conversion (`Reason(decodeError:)` — the only path to
  `.unsupportedFormat`), and starting the session/engine (`.audioUnavailable`).
  Anything else falls through as `.other` in its own words. Never map a
  non-decode failure to the format.
- **`LoadKeepAlive`** holds a background task for the length of a load, so a
  download started just before the phone locks usually finishes and starts
  playing on the lock screen (after which playing audio keeps the app alive).
  Its expiry is the signal that iOS suspended the load: a dropped connection
  *then* is `.interruptedInBackground`, otherwise `.offline`.
- `failure` drives the alert (cleared when dismissed); `playbackError` is its
  `summary` on the player's subtitle until a track plays. Retryable reasons get
  **Try Again** → `retry(_:)`, which reloads only if the queue is still on that
  track.
- The classification is checkable without a cloud account: run
  `PlaybackFailure.Reason(downloadError:suspended:)` over sample errors with
  Xcode's `RunCodeSnippet` (done 2026-10-02, all as intended).

## Outstanding / verification queue

- The three audit suspects (queue race, artwork race, `handleTrackEnd` field
  race) are addressed via `PlaybackAnchor` + the cancellable-Task pattern. Fixes
  are recent and want a long real-world listening session to confirm no
  regressions.
- No test target — verify by building (`xcodebuild … build`) and reading
  `[Q]`/`[NP]` logs during a repro.
