---
name: glass-ornaments
description: Addit's house style of raymarched 3D glass ornaments instead of glyphs — the shared GlassRoom lighting rig, PlasmaOrb/GlassLogo/AccessIcons, still-rendered UIMenu icons (MenuIcons.metal + MenuIconRenderer), scroll-driven motion via ScrollOffsetBox/ScrollTorque, and Liquid Glass that has to move every frame (GlassDisc). READ THIS before adding or changing an ornament, a menu icon, GlassRoom.h, anything reading the scroll offset, or Liquid Glass on something that moves every frame.
---

# Glass ornaments (Addit)

Where another app would use an SF Symbol, Addit usually uses a small raymarched
object. These are the rules that keep them a set and keep them cheap.

## Raymarched glass

**Raymarched glass** (`Shaders/`, auto-added by the synchronized file group):
`PlasmaOrb.metal` (toolbar bauble) and `GlassLogo.metal` (the three library
marks) share the lighting rig in `GlassRoom.h` — keep the room, film and tone
map there so the ornaments stay a set. Scroll-driven motion is shared too:
`ScrollTorque` owns the velocity-derived twist, each view derives its own
orientation from the offset. Brand marks *rock*, they don't spin —
`AccessIcons.metal` (globe / hazard plate / chrome chain, on the Access sheet)
follows that too, the turning globe being the deliberate exception.
`Eyeball.metal` (the tracking button, `EyeOrnament`) is the deliberate
exception to the glass look: an anatomical model, asked for as "medical grade"
(2026-10-07). Real proportions — a separate corneal sphere through the limbus
over a recessed iris disc seen *through* it, refracted, so the iris has
parallax — a blue stroma, meridional conjunctival vessels (ridged noise in
around-the-gaze coordinates; plain 3D ridges close into loops and read as
crazed porcelain), the optic nerve at the back, and a **neutral** studio room
rather than `GlassRoom`'s coloured ones, since colour cast reads as a toy. It
still takes `softbox` and `glassTonemap` (whites fed well over 1, or the roll-off
greys them). It has a home position, so it turns from `ScrollOffsetBox.scrolled`
— measured from the top of the content — not from `value`, which rests at minus
the top inset (~−140pt; turned the eye ~90° away). Rests ~10° right. Turns at a third
of the orb's rate; a flick tips it and widens the pupil. `renderEyeball` sits beside the
stitchable entry so it can be rendered on a Mac, as `tools/ripplepreview` does.

## 3D ornaments instead of glyphs

**3D ornaments instead of glyphs** is the house style, and it comes in two
deliveries. *Live* (a shader view under `TimelineView`) wherever the app draws
the surface itself — the Access sheet. *Still* wherever UIKit draws it: a `Menu`
becomes a `UIMenu`, whose icons are `UIImage`s with no SwiftUI host to run a
`colorEffect`, so a live shader in a menu is impossible, not merely slow.
`MenuIcons.metal` + `MenuIconRenderer` are that second path — one compute
kernel, rendered offscreen 3×3-supersampled into a `UIImage` the first time any
icon is asked for, all thirteen in one command buffer. Being still buys the
pose: each model is turned to the one angle that names it.

Two rules when extending the set: give `MenuIcon.label` the SF Symbol you
replaced as its `fallback` (it is what a device with no render shows), and mark
menu images `.alwaysOriginal` or `UIMenu` template-tints them flat. Provider
rows reuse `GlassLogo.metal`'s real brand marks through that file's own
`glassLogoKernel` — never model a second cloud. `tools/iconpreview` runs both
kernels on macOS and writes a contact sheet, including a row at the true 20pt
delivered size, which is the only row that decides whether a model works.

## Scroll-driven ornaments

The library's toolbar orb and brand mark follow the scroll through
`ScrollOffsetBox` (`ScrollTorque.swift`), an `@Observable` box, and **the screen
that owns the box must never read `value`**. As a `@State CGFloat` it made
`LibraryView.body` — two filtering passes over every album, each a SwiftData
read — a dependency of the scroll, re-run every frame. Reading it inside the
ornaments puts that dependency where the value is used. These two keep moving in
Low Power Mode — settled; they're small, they're the app's signature, and the
box is what made them cheap. `GlassRim`'s gyro highlight is the one that holds
still there (`PowerState.shared.isLowPower`), because there can be a screenful
of them — it was on every library cover until 2026-10-01, and is on every
folder tile still: it *doesn't read* the gravity in that state, so it stops
being invalidated rather than merely stopping moving. Covers now wear a still
hairline of their own (`AlbumArtworkThumbnail.edge`).

The **album page's bar** picks up from the scroll (`AlbumScrollChrome.swift`):
once the header's shuffle and play are under the bar, a cover thumbnail on the
bar's glass (as the library's centre menu is) appears, which scrolls back to
the top. **Anything that appears in a bar mid-scroll has to cost nothing on
the frame it arrives** — the album title in the bar once, and this cover at
first, both lagged there. Two rules make it free: the flag lives in an
`@Observable` object (`AlbumChrome`) that only the button reads, never in
`@State` on the page, whose body is the whole List; and the toolbar item is
always present at a fixed size with only its content fading in — adding an
item reconfigures the bar (~120 ms, per the folder zoom). And it's drawn,
at 1.1% opacity, from just after the page settles: at 0 a layer isn't drawn at
all, so its glass and its texture were set up on the frame it first appeared —
which lagged the first arrival only. The threshold is
computed in `onScrollGeometryChange`'s transform. Tried and reverted
(2026-10-09): folding the header away as the page scrolled (a List row
changing height every frame was choppy), copies of shuffle and play in the
bar, and the button rebuilt in UIKit (`UIGlassEffect`, shown by a Core
Animation spring, its flag observed by no view). Profiled in the simulator,
that version took the first arrival's extra main-thread work from +28 ms to
nothing — a SwiftUI update in a bar item's hosting view makes the bar
re-measure itself (`_layoutHeightsForNavigationItem`) and the navigation
controller recompute the page's insets — but it was reverted at the user's
ask, so the remaining first-arrival lag is known and lives there.

## Liquid Glass that moves

SwiftUI's `glassEffect` is re-resolved — shape bounds, its container's, the
material — on every frame its transform changes; counter-rotating a jiggling
badge back upright, so only a translation was left, cost just as much. One
moving glass button is nothing; a screenful of them, moving every frame, is
not: the library's arrange-mode delete badges ride each card's jiggle and were
a third of that mode's main-thread time. Glass that has to move with
per-frame motion is UIKit's (`UIGlassEffect` in a `UIVisualEffectView`, see
`GlassDisc` in `LibraryArrange.swift`): moved by a transform, it's a layer
moving, and the glass is the render server's business. It renders and fades
like SwiftUI's; it just doesn't respond to touches it doesn't receive, so give
its button a press style.
