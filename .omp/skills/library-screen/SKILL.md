---
name: library-screen
description: The library screen's internals — Home Screen–style folders and hold-to-arrange (LibraryArrange.swift, LibraryView+Arrange.swift, LibraryFolder), the FolderZoom open animation and its performance rules, Sort by Color (ColorSort.swift, tools/colorsortpreview), and cover thumbnails fetched at their drawn size (AlbumArtService). READ THIS before editing LibraryView, arrange mode, folders, colour sort, GlassRim, or cover loading.
---

# Library screen internals (Addit)

The library is a grid (or list) of albums that the user can arrange like the
Home Screen. Most of what's here is a behaviour that UIKit or SwiftUI fights,
and the specific way around it.

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
into. The blur is a paused `UIViewPropertyAnimator` *scrubbed* frame by frame:
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

**Sort by Color** (`ColorSort.swift`) has its own measure on purpose —
`CoverColor` hunts the most vibrant swatch, so a black sleeve with a red logo
reads red — and lays out in 2D: rows are hue bands, each row lightest→darkest,
neutrals then no-art after the spectrum, folders pinned first.
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
`gridLayout(for:)` refuses a non-positive width rather than clamping it to a 1pt
cover — a `GeometryReader` reports zero on the pass that builds it, which is
every library switch. Local covers are rewritten *in place*, so their cache
identity carries the file's mtime and the edit path calls
`invalidateThumbnails(atPath:)` + `bumpRefreshToken`.
