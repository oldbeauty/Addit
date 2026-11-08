---
name: library-screen
description: The library screen's internals — the Cosmos-tight grid whose labels come and go with the way it's scrolled (LibraryLabelReveal.swift), Home Screen–style folders and hold-to-arrange (LibraryArrange.swift, LibraryView+Arrange.swift, LibraryFolder), the FolderZoom open animation and its performance rules, Sort by Color (ColorSort.swift, tools/colorsortpreview), the endless colour-sorted canvas and the layout menu (LibraryCanvas.swift, CanvasGrid), and cover thumbnails fetched at their drawn size (AlbumArtService). READ THIS before editing LibraryView, the grid's spacing or labels, arrange mode, folders, colour sort, the canvas, GlassRim, or cover loading.
---

# Library screen internals (Addit)

The library is a grid (or list) of albums that the user can arrange like the
Home Screen. Most of what's here is a behaviour that UIKit or SwiftUI fights,
and the specific way around it.

## The grid, and labels that come and go

The grid is Cosmos's, measured off a screenshot of it (2026-09-30): 12pt
margins, column gaps and bare-row gaps (`gridGutter`) around 183pt tiles on a
402pt phone, and a continuous 3¼pt corner (`AlbumArtworkThumbnail
.defaultCornerRadius`) that every cover in the library shares — grid, list,
open folder, the card in hand — with folder tiles matching and their minis
scaled from it.

Covers wear a still hairline, `AlbumArtworkThumbnail.edge` — `GlassRim`'s own
base line (white at 12%). It started at 8% and went up on 2026-10-02 at the
user's ask. White because what it has to find is a dark sleeve on the dark
ground, which light mode's 7% black line (kept for that scheme) can't. The gyro-lit `GlassRim` is on no cover or
tile. It came off covers on 2026-10-01, first to see the grid without it, and
it was also a GPU-drawn layer per cover that every tilt redrew, under the grids
that arranging and folders animate.

A card's title and artist **come and go with the way the grid scrolls, a row
at a time, from the bottom up** (2026-10-19, at the user's ask; a trial). The
library opens with its top two rows labelled
(`LibraryLabelLine.labelledAtRest`). Scrolling down takes labels away and
scrolling up gives them back, in a **run** over the rows on screen, both ways
from the bottom up: each row's label gone, or back, before the one above it
starts ("as if one needs to collapse to be able to collapse the one above
it"; reveals were top-down for an hour until the user asked for bottom first
too). A label going closes its gap and pulls the rows under it up; one coming
back pushes them down. **Only the rows on screen at the turn take turns**:
rows that scroll on while hiding come on bare, so the grid goes on cover to
cover for as long as it's scrolled down, and rows that come down while
revealing come on named, with nothing to watch (2026-10-20, at the user's
ask: "only the visible album titles are sequentially revealed, everything
above should appear already revealed", then "once the user has seen the
animation for what's in sight, all of them above become revealed"). That
last is an illusion done with the scroll offset — see "Rows above the run
come down named", below. A step is
`stepTravel` of scroll (0.35 of a bare row; a screenful's run of five ≈ 1.75
rows), and none of it is timed, so it follows the finger. The opening hide
(second row, then first) is just the first run, two rows long.
`LibraryLabelLine` (`LibraryLabelReveal.swift`) is the one definition:

- **One function, two readers.** The cards draw from it (through
  `LibraryLabelReveal`) and `LibraryGridGeometry` (`revealsLabels`) places
  slots with it. Change the curve anywhere else and a drag lands a row away
  from what's drawn.
- **It depends on the way there, not just where.** `LibraryLabelState` is the
  scroll plus the run plus the rows above it: `firstRow`, `startingLabels`
  (each of its rows' label as the run found it, top first), `hiding` (which
  way), `progress` (scroll since it started), `above` (the label of each row
  above the run that has one — a row off the top keeps what it had, so they
  can be anything) and `top` (how far above where the grid rests the screen
  starts). Steps go from the run's bottom row up to its top; a row already
  where the run is taking it has no step, and one part of the way has a
  shorter one (`activeStep`). Rows above the run take no steps; rows past it
  are bare. Rows above used to take steps too, after the run's own, so the
  first rows down from under the bar came on bare and then opened one by one
  under the finger — the choppiness that was taken out; and then they opened
  as they crossed the line, under the bar, which still showed ("the top row
  still reveals sequentially"), so now they come down named. What's left by
  design: the run's top row — the first whose label shows below the bars —
  goes last, while the row above it, under the bars, is named from the turn,
  so a named row sits over a bare one until the run gets there (the harness
  counts it: about a run's length of scroll per reveal). There's no line ease
  any more (`travel`, a row's label following its covers across where the
  grid rests): it was what still showed. `progress`
  isn't capped at the run's length: worked out as one product, the cap came a
  rounding error short of the steps subtracted one at a time, and a run whose
  last row started part-way never finished (stuck at 0.9999…).
- **Every turn starts a new run** (`run(onScreenIn:)`), partway through the
  last or not: bottom-first both ways can't be played back. Its rows are the
  ones whose labels show: from the first whose covers' bottom is at or below
  where the grid rests — its label below the bars — down to the last whose *label* is on screen (the label's
  top above the screen's bottom — a step for a row whose label is off screen
  would be a stretch of scroll where nothing visible happens, first in line),
  capped at the grid's last row (`rows`). `visible` is the scroll view's whole
  height less its top inset and the grid's top `inset` — and **`ScrollGeometry
  .containerSize` is not that height**: it's the scroll view *less its
  insets* (652pt of an 874pt scroll view under 116pt of bars and the 106pt
  band the + button and mini player float in, logged on the phone,
  2026-10-21), so the height is `containerSize` plus both insets, and the
  scroll's end `contentSize − containerSize`. Read as the whole height, the
  screen ended 222pt short: runs left out the rows whose labels showed in that
  stretch, a turn down took their labels at once ("the lowest revealed cover
  snaps into hide mode"), and the end ran 222pt long, so the bounce off the
  bottom counted. The harness used the true height, which is why it never
  showed. Each row starts from
  the label it has, so nothing moves as a run starts; a row the turn caught
  part of the way waits there until its step comes round. Rows dropped off
  the bottom are bare from then on — their labels are off screen, so that
  only moves rows below the screen.
- **Only scrolling by hand moves them** (`onScrollPhaseChange`: interacting or
  decelerating), not a drag's auto-scroll, Add Existing's scroll or the offset
  shifting as the content resizes; **and only within the content**: deltas are
  clamped to 0…end, the same end for both sides of a step, so a pull past
  either end and the bounce back mean no direction (the bounce off the bottom
  would otherwise bring labels in), and content shrinking under a still
  offset is no movement at all — a moving end would feed back.
- **Nothing seen snaps.** A label changes a frame's worth at a time, never at
  once — under the bars too: they show what's under them. The first cut of
  the illusion (2026-10-20) labelled rows under the bars at a turn up, and took
  labels back there at a turn down once they cleared where the grid rests,
  each all at once; held down and wiggled slowly, titles snapped away in plain
  sight (the 12pt under the bar isn't under it at all). So: hiding, the rows
  above the run keep what they have, and one off the top keeps it while it's
  off; revealing, they grow (below). Every label change on screen moves the
  rows below it the way the grid is already going, so nothing stalls under
  the finger; a short step only makes them lurch ahead.
- **A row the grid hasn't laid out never changes.** Rows above the screen
  aren't laid out, and a lazy grid places what's on screen by the heights it
  last measured: change one and the screen stays put, placed by its old
  height, then jumps when the grid lays it out. Measured in a probe app on the
  iOS 27 sim (2026-10-20): every row above the screen labelled at once — nothing
  moved, the layout 1160pt off the model, content size unchanged; then jumps
  of up to 379pt scrolling back up; moving the offset to match only jumped the
  screen 1160pt at once. So a row of the run going off the top keeps the label
  it was last laid out with — the one before this frame's step, which the
  frame doesn't lay out (`settleExits`; taking it after the step changed a row
  in the frame it left, which the harness caught) — and is a row above the
  run from then on. Rows below the screen only change as a run starts, and
  nothing on screen is placed by them.
- **Rows above the run come down named.** Revealing by hand, each row above
  the run that the grid has laid out and isn't named grows its label a step's
  worth of scroll (`growAbove`: a whole label in `stepTravel`), and the scroll
  view is moved by however much it grew, so every row below it stays where it
  is on screen and only the growing row moves, a little behind the scroll,
  under the bars. A row coming on at the top edge is named well before it's
  out from under them; one under them at the turn fills in there. Only rows
  laid out before the move and after (on the screen by `laidOut`, 2pt).
- **The move goes in the same action as the labels.** The label host sets
  `contentOffset` in its `onScrollGeometryChange` action, where it works out
  the labels: SwiftUI lays the frame out again with both before drawing it. A
  frame later, the push shows for a frame (probe: rows 40pt off, then back).
  Checked on pixels, not reports — `onGeometryChange` can report a row a pass
  behind what's drawn (it said 516pt where the screenshot had 476): a
  recording of the probe cut to a 1-px column with ffmpeg, every cover below
  the bar moving by the scroll's step, frame after frame, 0 off. Dragging and
  decelerating both carry on from a moved offset (UIKit's are incremental, as
  in WWDC 2011's StreetScroller). And the move must never read as a scroll:
  the host feeds the ornaments' `ScrollOffsetBox` itself in the grid (in place
  of `tracksScrollOffset`, so the order of two observers can't matter),
  holding the moves out of `value` and handing them back a quarter of the
  scroll's pace (`follow(_:shifted:)`); otherwise the orb snaps ~25° per label
  and its twist reads a flick. Only by hand, and only with the scroll view to
  hand (`canShift`); otherwise nothing above the run changes. **A turn has to
  be more than a hair** (`turnSlop`, 0.5pt): the scroll view's report of the
  move comes back a rounding off (sums in another order, or UIKit's own
  rounding), and the first build took a rounding the other way for a turn —
  a new run, its own move, its own rounding, and back: the whole grid
  stuttered on the phone.
- **Cards read a few numbers, never the offset.** `stepRow` moves once a step;
  `stepProgress` every frame of a step, read only by the row taking it;
  `above` every frame a row above the run grows, read only by the rows above
  it; `firstRow` and `startingLabels` once a run, and as a row of it goes off
  the top; `bottomRow` and `target` once a run. Same trap as
  `ScrollOffsetBox`.
- **The reveal lives exactly as long as its scroll view** (`@State` in
  `LibraryLabelRevealHost`): a rebuilt grid (library switch, list → grid)
  starts at rest, and a push/pop keeps it. The arranger keeps its own
  unobserved copy (`grid.labels`), because `LibraryView.body` asks where a
  folder's tile is and must never depend on the scroll; auto-scroll bumps its
  `scrolled` alongside `grid.origin` (and moves no labels, as above).
- **Only one row of a run is ever moving**, which keeps `rowTop` cheap and
  free of the scroll: the rows above the run (summed from `above`), then the
  run's own as it found them (added up), the one taking its step, the done
  ones (counted), and none past the run.
- **`gridRunway`** is the empty room after the last row, so the last rows can
  scroll up to where the top rows rest. Labels need scrolling now, so without
  it a library that fits on a screen could never name more than its top rows.
- **Scrolling the grid to a row is arithmetic**
  (`LibraryLabelLine.scrollShowing`), as Add Existing does to take you to the
  album it added: every label from the top of the screen down is brought in
  first (`showingAllOn:` — a done run from there to the grid's last row, since
  the scroll isn't by hand; the rows above stay as they are, not laid out),
  and the row lands where the top row rests. Exact, in one go: nothing
  changes on the way, rows going off the top keeping their labels; the
  content's end is moved by the labels brought in.
- **The dock** (`dock`, 2026-10-27, at the user's ask): layout, +, search,
  left to right, at the bottom where + stood alone; layout and search left
  the top bar for it. Three discs of interactive glass in one
  `GlassEffectContainer` whose spacing (16) is wider than the gap between
  them (2), so the glass melts into one shape at rest — Apple's "blend
  together at rest" — and the + disc (56pt, the sides 44) rises out of it as
  a hump, bottoms aligned. Glass on a `Menu`'s label joins the blend; seen
  on the iOS 27 sim before it shipped. The reserve below the grid is sized
  off the hump (`bottomOverlayInset`), the side discs centered where + was.
  **Search lives in it** (same day): the + disc's glass becomes the field
  (`glassEffectID("add")`), the layout disc melts into it, and the search
  disc turns into the × (symbol replace) and moves to the far right, its
  gap widened past the container's spacing so it pulls clear. With the
  keyboard up the dock stands 8pt off it, not above the mini player, which
  stays behind the keyboard (`ContentView`). Keyed on the keyboard's own
  show/hide notifications (`isKeyboardShown`), never the field's focus:
  focus outlasts the keyboard (back from an album, from the background), and
  keyed on it the dock sank under the mini player — search with no field and
  no way out (reported 2026-10-28, not reproduced; this is the path found). Closing drops focus first and
  removes the field a turn later (`closeSearch`): removed in the same
  transaction, its responder vanishes and the keyboard inset can fail to
  unwind, which is how the pill once got stuck mid-screen.
- **The search field is glass with nothing behind it** (`searchField`), in
  the dock since 2026-10-27. For a day it was a capsule under the top bar,
  in a top `safeAreaInset`; before that a grey field on a band of background
  above the grid, which stopped at its edge. The grid's label host and
  scrolls read the scroll view's insets, so a bar coming or going at either
  edge is never a scroll by hand to them.
- **Hidden labels are clipped, not removed.** `.contentShape(Rectangle())` stops
  one catching taps below its cover, and cards name themselves for VoiceOver
  (`accessibilityLabel` + `.contentShape(.accessibility, …)`), since the text is
  hidden on most rows. `ArrangeChrome` scales a merge target about the cover's
  centre from the top (`anchor: .top` + offset), since card height varies by row.

History: the first cut of this (same day) brought every label in or out at
once over a row of scroll — "instead of all at once, make them sequential";
the second revealed top-down and played a run back on a turn; "they should
reveal bottom first". The third (2026-10-20) stopped rows above the screen
taking turns; the fourth (same day) had them come down named instead of
opening at the line, but with labels flipped at once under the bars, which
showed, and turned on roundings, which stuttered; the fifth made every change
gradual and dropped the line's ease. Before that, labels showed only on rows scrolled up to a fixed line where the
second row's labels rest, kept on every row above it — a pure function of the
offset, verified on the iPhone 17 sim by logging each card's measured top
against `coverCenter` (exact at rest, within 0.9pt dragging). The run
arithmetic is checked off-device by a script that compiles the shipping
`LibraryLabelLine`, `LibraryLabelState` and `LibraryLabelReveal` (cut out of
the file with `awk`, the SwiftUI parts left behind, `AlbumCard` stubbed)
against a harness whose scroll view is moved by each shift (the script must
stop if the cut finds nothing — once it ran the last build's binary and
passed): rows add up to `rowTop` in every state; runs go bottom-up both
ways, one row moving at a time, a caught row finishing in its turn after a
turn, every run finishing; no label whose room shows on screen changes by
more than a frame of a step at the scroll's speed — across a slow wiggle of
the finger held down, twelve turns of a few points a frame, and a fling;
every label that changes belongs to a row laid out then, or one below the
screen; the shift is exactly what the rows above the run grew by, and the
scroll view's report of it changes nothing, nor does a rounding the other
way; rows above the screen never move; revealing, a row come on from above
is named by the time its label is out from under the bars; scrolled to the
top by hand, every row there is named; with no scroll view to move, nothing
shifts; the cards' numbers agree with the line, stepped
together; `scrollShowing` lands exactly. The on-screen measurement in the
app hasn't been redone (the probe's was of the mechanism). On the phone,
`[Labels]` (DEBUG) logs each turn — the run, the geometry, the scroll view's
frame in the window — and any label whose room shows changing by more than a
frame of a step allows; `./deploy`, then `xcrun devicectl device process
launch --console --terminate-existing` streams it (it's how the
`containerSize` mistake was found). During a fling, the
first layout pass of a frame still has the previous frame's labels; SwiftUI
lays out again at the same offset before drawing.

## The canvas

The third layout, beside Icons and List (`LibraryLayout`, under
`libraryLayout`; the old `libraryViewMode` Bool is migrated at launch). The
layout menu is the dock's left disc; Settings has the same three. Asked for
on 2026-10-27 after Cosmos's canvas.

- **Three across, the grid's gutter and corner** (`(width − 4 × gridGutter)
  / 3`, `defaultCornerRadius` unscaled), no labels, every album once,
  foldered or not.
- **One round field, finite** (2026-10-28, at the user's ask; it was an
  endless mirrored tiling until then). `ColorSort.canvas` grows a disc of
  grid cells from the middle a ring at a time until there's one per cover,
  a partly needed ring giving cells spaced evenly round it, cropped to the
  cells used (`CanvasDisc`). The colour sequence is poured into its columns
  left to right, each re-laid lightest at the top: hue across, lightness
  down. Opens centred (`defaultScrollAnchor(.center)`), bounces past every
  edge (`scrollBounceBehavior(.always)`), and builds only the cells on
  screen plus one all round (`CanvasWindow`).
- **Tones** are measured once a session per cover (`CoverToneCache`, held by
  `LibraryView`); nothing is drawn until every cover has one, then it fades in.
- **A cover opens its album and has the album menu**; Arrange is the grid's.
  Add Existing's "take me to it" scrolls to the album (`CanvasReveal`).

**The colour order** (both Sort by Color and the canvas, since 2026-10-28 at
the user's ask): greys first, light to dark; then the spectrum violet, blue,
green, yellow, orange, red, pink, cut between violet and pink at the widest
gap; no-art last. Within a row, lightest left, greys ahead of colours.

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

**Arranging can't wedge.** While `isBusy`, no card lifts and Done does nothing,
so nothing it waits on may hang on a single callback. A drag ends on its
recognizer's end, and the auto-scroll's per-frame tick also checks that
recognizer (`putDownIfAbandoned`): one carrying nothing for a quarter second
lands the card as a cancelled drag. The way found to lose that end is lifting
a card out of a folder as it closes, whose layer then comes down under the
drag — so a panel only lifts cards while `isFolderExpanded`. Lost, it leaves
the card floating where the finger let go. A landing ends on its animation's
completion or a second later, whichever comes first (`land`). Build 12's tester
got stuck with every card jiggling and none floating (the landing's
signature, not the drag's), stuck until the app was killed, and that is
what the deadline is for.

**Into a folder, the card drifts onto the cover it becomes** (`drop`,
2026-10-28, at the user's ask: it "snaps into place"). It used to shrink to a
third at the tile's middle and fade, on the snappy home landing, while the
tile already showed it. Now it flies on a soft spring (`settle`) to its own
mini's frame (`FolderTile.miniFrame` at its slot, which `merge` returns; a
dropped album goes after the folder's highest order, not at its count,
since orders can have gaps) at that mini's size, and the mini waits unseen
(`arrivingAlbums` → `FolderTile.hidden`) until the landing swaps them, same
picture in the same place. Past the tile's four it still goes into the
middle and fades. Making a folder, the target album draws back from its
place into its corner the same way (`SettlingCover`, drawn by
`LiftedItemLayer` and set off on appear, since a view put up and moved in
one update has no first frame), its `FormingPlate` thinning to nothing at
the tile's middle. The drop is two halves: `formFolder` at once (a new folder
takes the target's slot — instant, since a target faded out in place was a
second copy of it behind the drifting one), then a turn later `admit` on the
same spring (the dragged album into the folder, its hole closed, the covers
after it drifting up into the gap). Closing the hole in the swap's own
update, which mustn't animate, snapped it shut (asked about 2026-10-28).
Every landing also fades the lift's shadow on the way down.

**A cover draws its placeholder only while it has no art** (2026-10-28).
The "white border flickering" opening and closing a folder was the tinted
placeholder fill under the art showing through it: an opacity on a view is
applied to each of its layers, not to the flattened picture, so a cover
part-way through a fade — every one at the folder's hand-overs between the
travelling covers and the panel's — showed the fill through its own art,
pale, most of all at the edge. Found by recording the sim and probing one
pixel per frame (`ffmpeg … crop=2:2:x:y,format=rgb24 -f rawvideo`): the
cover's `1f5889` went to `3b6c97` for three frames opening and its edge to
`51718f` closing, and stayed put once the fill was gone. The first guess,
the hairline, changed nothing the user could see; it's still faded while a
folder moves the covers (`coverEdgeOpacity`), since a scaled 1pt line comes
out 2pt on a tile's cover flown out and changes width at the hand-over. The
panel's hairlines come and go with its titles (`areFolderLabelsShown`), the
travelling covers' are on at the tile, off as they lift, and back as they
land (`FolderMotion.edgeOff`/`edgeOn`). Any group fade of covers is safe now.

**The open folder runs to the screen's foot** (same day, at the user's
ask): the panel sits where a centred one would, but its frame reaches the
bottom of the screen, so covers are only cut off at its top edge, the one a
cover is dragged past to leave. Leaving is only over the top now; the sides
and foot are the screen's. The empty reach under the covers closes the
folder on a tap, as the blurred library does; without that the scroll view
took the tap and a short folder had no way out below.

**Arranging's leading button is an ellipsis menu** (2026-10-28): Sort by
Color (or Undo Sort), and in an open folder Disband Folder
(`disbandOpenFolder`), which closes the folder into its tile first, then
sets its albums loose in the folder's slot, in its order, and deletes it.

**A folder's tile is its four covers and nothing else** (`FolderTile`): no
plate, no rim. The 2×2 reaches the tile's edges, a small gap between, so the
four together have a cover's outline (plate removed 2026-10-12 at the user's
ask). The minis round at the covers' own 3¼pt, not scaled down with them. The
open folder has no plate either — no fill, hairline or glass rim; its shape is
only the clip that grows the panel out of the tile. With no plate to sit on, the
open panel is laid out by the library's own `gridLayout(for:)` at the screen's
width, its gutter at the edges and between rows: a cover in a folder is the
same size and the same distance from its neighbours as one in the library. `miniFrame` is shared with
`FolderZoom`'s travelling covers, which are drawn at mini size and scaled, so
their corners grow on the way out and meet the panel's slightly round before
they fade.

**A folder opens as the Home Screen's do** (`FolderZoom`): the layer mounts
collapsed, pixel for pixel over its tile (`FolderCard.tileHidden`), then springs
open — the tile's covers fly to the panel's first four, the panel grows out of
them, the library blurs across the whole opening. `openFolderID` says the layer is up;
`isFolderExpanded` is the spring, read only by `FolderZoom`. The panel's titles and
artists fade on their own (`areFolderLabelsShown` → `folderLabelOpacity`), in
once the covers land and out *before* a close: the panel itself goes within a
few hundredths of the close starting, so `closeFolder` fades the labels and
waits `labelsOutLead` (0.1s) before the spring (2026-10-12). Every one of
these timings runs on `FolderMotion.pace` (0.7 since 2026-10-28, when the
user asked for it faster: opening 0.29s, closing 0.25s). Change the pace,
not single values: the hand-overs are timed against the spring, and one
slipped is covers cross-fading over nothing.

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
(the plate had a plain hairline edge and fixed rims; since 2026-10-12 it draws
nothing), `GlassRim` renders through `.drawingGroup()` (GPU), and
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
