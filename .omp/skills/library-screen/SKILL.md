---
name: library-screen
description: The library screen's internals — the Cosmos-tight grid whose labels appear only on rows scrolled up to a line (LibraryLabelReveal.swift), Home Screen–style folders and hold-to-arrange (LibraryArrange.swift, LibraryView+Arrange.swift, LibraryFolder), the FolderZoom open animation and its performance rules, Sort by Color (ColorSort.swift, tools/colorsortpreview), and cover thumbnails fetched at their drawn size (AlbumArtService). READ THIS before editing LibraryView, the grid's spacing or labels, arrange mode, folders, colour sort, GlassRim, or cover loading.
---

# Library screen internals (Addit)

The library is a grid (or list) of albums that the user can arrange like the
Home Screen. Most of what's here is a behaviour that UIKit or SwiftUI fights,
and the specific way around it.

## The grid, and labels above the line

The grid is Cosmos's, measured off a screenshot of it (2026-09-30): 12pt
margins, column gaps and bare-row gaps (`gridGutter`) around 183pt tiles on a
402pt phone, and a continuous 3¼pt corner (`AlbumArtworkThumbnail
.defaultCornerRadius`) that every cover in the library shares — grid, list,
open folder, the card in hand — with folder tiles matching and their minis
scaled from it.

Covers wear a still hairline, `AlbumArtworkThumbnail.edge` — `GlassRim`'s own
base line (white at 12%), so covers and folder tiles share an edge and only the
tiles add the gyro lobe. It started at 8% and went up on 2026-10-02 at the
user's ask. White because what it has to find is a dark sleeve on the dark
ground, which light mode's 7% black line (kept for that scheme) can't. The gyro-lit `GlassRim` is on folder tiles
only. It came off covers on 2026-10-01, first to see the grid without it, and
it was also a GPU-drawn layer per cover that every tilt redrew, under the grids
that arranging and folders animate.

A card's title and artist show only on rows scrolled up to **a line**: where the
second row's labels sit at rest (`LibraryLabelLine.labelledAtRest` = 2, so the
top two rows are labelled when the library opens; it was the top one at first,
which also works, and every rule below holds for any count). A row below it is
bare; as it rises to the line
its label fades in and the gap under it opens by `AlbumCard.labelBlock`, and
scrolled back down the gap closes again. It's all a function of the scroll, so
it scrubs with the finger, both ways. `LibraryLabelLine` (`LibraryLabelReveal
.swift`) is the one definition:

- **One function, two readers.** The cards draw from it (through
  `LibraryLabelReveal`) and `LibraryGridGeometry` (`revealsLabels`) places
  slots with it. Change the curve anywhere else and a drag lands a row away
  from what's drawn.
- **Cards read two numbers, never the offset.** `edgeRow` moves once a row;
  `edgeProgress` moves every frame and only the edge row's cards read it, so a
  scroll frame invalidates two cards. Same trap as `ScrollOffsetBox`.
- **The reveal lives exactly as long as its scroll view** (`@State` in
  `LibraryLabelRevealHost`): a rebuilt grid (library switch, list → grid)
  starts at rest, and a push/pop keeps it. The arranger keeps its own
  unobserved copy (`grid.scrolled`), because `LibraryView.body` asks where a
  folder's tile is and must never depend on the scroll; auto-scroll bumps it
  alongside `grid.origin`.
- **Only the row at the line is ever part-way** (`travel` < a bare row), which
  keeps `rowTop` closed-form. Every height change happens on screen — rows above
  the line are always labelled, rows below always bare — so the lazy grid never
  holds a stale row. `travel` must stay well over 1.5 labels, or the rows below
  the opening gap stall under the finger, then run backwards.
- **`gridRunway`** is the empty room after the last row so it can reach the
  line. Without it the last screenful of covers, including every newly added
  album, never shows a name.
- **Hidden labels are clipped, not removed.** `.contentShape(Rectangle())` stops
  one catching taps below its cover, and cards name themselves for VoiceOver
  (`accessibilityLabel` + `.contentShape(.accessibility, …)`), since the text is
  hidden on most rows. `ArrangeChrome` scales a merge target about the cover's
  centre from the top (`anchor: .top` + offset), since card height varies by row.

Verified on the iPhone 17 sim by logging each card's measured top against
`coverCenter`: exact at rest, within 0.9pt while dragging. During a fling, the
first layout pass of a frame still has the previous frame's labels; SwiftUI
lays out again at the same offset before drawing.

## Folders and arrange mode

**Library folders + arrange mode** are the Home Screen's, for albums
(`LibraryArrange.swift` engine, `LibraryView+Arrange.swift` view side).
`LibraryFolder` is app-side only — never a provider folder — scoped per library
like albums; membership is `Album.libraryFolderID` + `libraryFolderOrder`, and a
foldered album's `displayOrder` mirrors its folder's slot so every "max
`displayOrder` + 1" still lands at the end. The drag rewrites `displayOrder`
live; `LibraryArranger.liftPoint` is per frame and read only by
`LiftedItemLayer`, never `LibraryView.body`. Slots are arithmetic
(`LibraryGridGeometry`) because a `LazyVGrid` can't report off-screen cells, so
a folder card must stay exactly `AlbumCard`'s height.

**Hold-to-arrange can't be a recognizer**: once the context menu fires, UIKit
makes every other recognizer ignore the touch, whatever the delegate says.
`LibraryHoldGesture` catches the touch in `shouldReceive` and watches the
`UITouch`'s phase, which stays live under the menu. It deliberately doesn't
carry the card on into a drag: the touch reads (0, 0) once the dismissed menu's
container view is gone, and keeping the menu up invisibly would leave "Remove
from Library" live under the finger. For the same reason the dismissed menu's
live copy of the card lingers over the real one until the finger lifts, so
`ArrangeChrome` sits *inside* `.contextMenu` and the preview shape is widened
(`menuPreviewShape`) — outside, or clipped, the held card's badge showed behind
or cut off. Empty folders are pruned only when nothing is in hand.

**A folder opens as the Home Screen's do** (`FolderZoom`): the layer mounts
collapsed, pixel for pixel over its tile (`FolderCard.tileHidden`), then springs
open — the tile's covers fly to the panel's first four, the plate stretches, the
library blurs across the whole opening. `openFolderID` says the layer is up;
`isFolderExpanded` is the spring, read only by `FolderZoom`.

Each of these was got wrong first: the toolbar keys on `openFolderID`, never the
spring — changing the bar costs ~120ms and stalled the first frame both ways —
and must never go *empty* (hence the clear principal placeholder), or the bar
collapses and the library jumps a bar's height, off the tile the folder closes
into. It reads `isLibraryBarCleared`, which is `openFolderID` with a fade
attached (set in its `didSet`): the layer's own change must not animate, and
the items used to blink off at the tap and back on as the folder landed. The blur is a paused `UIViewPropertyAnimator` *scrubbed* frame by frame:
SwiftUI updates representables with animations off, so a played UIKit animation
lands in one frame. It is scrubbed on its own eased curve, not the spring — the
spring front-loads, and the blur looked instant. It's rebuilt on foreground and
window re-entry, which both strip paused animations — a turn later whenever
UIKit has animations off (SwiftUI inserting the view), or the animator is born
finished and the blur lands at once. The folder itself is two poses SwiftUI
interpolates — transforms, opacities, an animatable `PlateShape` — so no body
re-runs per frame: the first version recomputed the stage every frame and
resized `GlassRim`s, and a profile put ~60% of the main thread in Core Graphics
rasterising their angular-gradient lobes. So rims never change size mid-flight
(the plate's moving edge is a plain hairline, its lobe two fixed rims
crossfaded), `GlassRim` renders through `.drawingGroup()` (GPU), and
`MotionShine.isHeld` stills the gyro while the folder moves. The lifted tile
hides with `.animation(nil)`: the press style's spring-back otherwise fades it,
a ghost behind the opening folder. Panel and blur stay a hundredth above zero
while up, so their first draw happens before anything moves.

**What a drag costs, frame to frame.** Profiled 2026-10-01 on the iPhone 17
sim with folder open/close bracketed by signposts (method in the memory note on
Xcode tools); each of these was a measured cost or a visible glitch:

- **The delete badge is UIKit's glass** (`GlassDisc`: a `UIVisualEffectView`
  with `UIGlassEffect`), not SwiftUI's `glassEffect`. The badges ride the
  jiggle, and SwiftUI re-resolves a glass effect on every frame it moves —
  shape bounds, container, material — which was a third of arrange mode's main
  thread (~195 → ~66 ms a second at rest). A badge held still costs nothing
  either way but reads as stuck on; one counter-rotated inside the jiggle still
  moves, and costs as much. `BadgePress` stands in for interactive glass's give,
  which UIKit's only shows to touches that reach the glass itself.
- **The card in hand shrinks over a merge target** (`mergeScale`, against
  `liftScale`): at its lifted size, centred over a cover as a merge is aimed, it
  hid both the cover drawing back and the plate forming behind it, so nothing
  said a folder was coming.
- **A new copy of a cover draws its art on its first frame**: the card in hand,
  the covers flying out of an opening folder. `AlbumArtworkThumbnail` reads the
  memory cache in `body` (`memoryThumbnail`); `onAppear` is a frame late, and
  inside the lift's spring the art then crossfaded in over the grey placeholder
  — a flash at the start of every drag. `AlbumArtService.localIdentities` is
  `@ObservationIgnored` because of that read: observed, every cover finishing
  its load redrew every cover still waiting.
- **Auto-scroll runs on a display link** (`FrameTicker`), moving by elapsed
  time. It was a task sleeping 16ms between fixed steps, out of step with the
  frames.
- **Card labels are decided in layout** (`fadingTruncation`, `ViewThatFits`).
  Each line was a `UIScrollView` plus two `GeometryReader`s writing state —
  four of each per card, all built on an opening folder's first frames and laid
  out twice. That took the longest stall opening a folder from ~46 to ~26ms.
- **Jiggle is 60 Hz** (`.sixtyHertz`) while the rest runs at 120: it's
  self-clocked, and its swing doesn't need more.

What's left, measured the same way: opening a folder still stalls ~25–35ms on
the frame the layer mounts (the panel's cells, the bar), closing ~30–45ms as it
comes down — at rest, but there. A reorder mid-drag is ~15ms: SwiftUI's
reflow plus `@Query` refetching on the `displayOrder` writes. The arrangement
being rewritten live is by design; drawing the grid from the session's order
during a drag would be the next step.

**Sort by Color** (`ColorSort.swift`) has its own measure on purpose —
`CoverColor` hunts the most vibrant swatch, so a black sleeve with a red logo
reads red — and lays out in 2D: rows are hue bands, pink at the top down to
red (reversed from red-first on 2026-10-01, at the user's ask), each row
lightest→darkest, neutrals then no-art after the spectrum, folders pinned first.
`tools/colorsortpreview` compiles the shipping file against synthetic covers;
check a change there. Its undo (`ColorSortUndo`) is one level and dies the
moment anything else moves — restoring after a hand-made move would silently
revert that move too.

## Covers are fetched at the size they're drawn

`AlbumArtService` keeps a second cache of `ImageIO` thumbnails
(`thumbnail(for:pixelSize:)` / `thumbnail(atPath:pixelSize:)`), built off the
main thread straight out of the file. Grid and list cells ask for their own
drawn size; anything showing a cover large asks for
`AlbumArtService.displayPixels`. Never `UIImage(contentsOfFile:)` on a view's
`onAppear` — that's a full-resolution decode on the frame a row appears. **The
drawn size is part of the artwork task's identity**
(`AlbumArtworkThumbnail.artworkTaskID`): without it a cell laid out before its
width is known keeps the thumbnail it fetched for the provisional size forever,
and only scrolling it out of the grid and back ever fixes it. Relatedly,
`gridLayout(for:)` refuses any width narrower than one minimum cover rather than
laying covers out at it — the `GeometryReader`'s first pass, which is every
library switch (`ContentView` is keyed on the account), reported zero once and
reports a few points now; `> 0` let that through and the blurry-after-switching
bug came back (2026-10-02). `AlbumArtworkThumbnail` also fetches nothing below
`smallestRealSize`, so no container's provisional pass can cache a 64px cover. Local covers are rewritten *in place*, so their cache
identity carries the file's mtime and the edit path calls
`invalidateThumbnails(atPath:)` + `bumpRefreshToken`.

**A replaced artwork task must not assign its image.** The grid's first layout
can be a few points wide, so every cover first asks for a 64px thumbnail, then
for its real size; `.task(id:)` cancels the first, but its decode still
returns. Assigned unchecked, it landed over the sharp one whenever it finished
second, and covers came up blurry at random until the cell was rebuilt. Every
`image =` in `AlbumArtworkThumbnail`'s task is behind `!Task.isCancelled`.
