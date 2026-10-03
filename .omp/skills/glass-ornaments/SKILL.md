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
