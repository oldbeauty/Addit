---
name: launch-screen
description: The launch screen's internals — the ADDIT wordmark (hand-authored geometry, raymarched as a false-colour readout), the pixel-ripple field and its colorway table, the pattern-recognition overlay that measures the water, the per-launch seed, and the Liquid Glass plaque. READ THIS before editing anything in Shaders/ for the splash, AdditWordmark.swift, PixelRippleField, FieldAnalysis*, LoadingSplashView, or tools/ripplepreview and tools/fieldprobe.
---

# Launch screen internals (Addit)

The splash is three layers that have to agree: the ripple field
(`PixelRipple.metal`), the ADDIT wordmark raymarched on a glass plaque over it
(`Wordmark.metal`), and an analysis overlay measuring the water
(`FieldAnalysis`). Nearly every rule below was learned by getting it wrong
first; read the section for what you're changing.

## The wordmark is geometry, not type, and false colour, not a material

`Wordmark.metal` draws "ADDIT" as hand-authored polygons — the coordinates *are*
the typeface, terminals all flat at cap and baseline — extruded along a sheared
axis and raymarched; `AdditWordmark.swift` only sizes it and supplies the clock.
The surface is a **readout** — each point's reflected elevation looked up in a
palette — and which palette is `kMarkPalettes` picked by `kMarkColorway`, in
three structures: `kModeZones` measures (three colours keyed to elevation with
black between them, so the *gaps* draw the letterforms), `kModeRoom` lights
(borrowing `GlassRoom.h`'s rig, which makes the mark one of the glass ornaments
instead of an instrument — this file pointedly used not to include that header),
and `kModeRamp` borrows the launch field's own `spectrum`. **7 · field** ships,
which is the last of those: the letters and the water end up on one palette by
construction rather than by eye, and changing `kColorway` moves both. Its
**halo** is the one part that was never the mark's own — those two colours come
from `Colorways.h`, below.

Two things are load-bearing and were each got wrong first. The face is a **dome
with a circular cross-section**, because a flat face measures one direction
across a whole letter and comes back as a plate of one colour, and a smoothstep
dome is flat at *both* ends so it only bends in a ring near the edge. And every
perturbation — texture especially — has to stay small against the palette's
bands: a tilt lands twice over in the reflection, so anything moving elevation
further than a band is wide drags the zones over each other and the mark turns
to mush. Detail reads because the sweep is steep, not because the texture is
strong. Turn the ramp up, not the flaws.

## The colour is a table

`Shaders/Colorways.h` holds nine palettes — six ramp stops for the water, the
rim light on its leading edges, and the wordmark halo's two colours — and
`kColorway` picks the one that ships (**1, Readout**: blue → green → amber →
red, the wordmark's own signal palette run along the water's height, so both
surfaces say elevation is colour). One table across both shaders because the
mark sits *on* the field and the halo is what makes them look lit by one light;
split up, they drift.

Three things constrain a new one. The breakpoints in `spectrum()` are shared
tuning, not part of a colorway — `level` is bent down hard, so the first two
stops are most of the screen most of the time and have to stay near-black. The
rim lands on calm cells as well as crests, so it has to be a colour that
survives being faint: white is *grey* at a tenth strength and speckles the dark
half of the field with what look like dead pixels. And `kBackdrop` deliberately
isn't per-colorway, because `LoadingSplashView` carries the same value in Swift.

The glow is a **thresholded second pass** of the same surface sampled per pixel
instead of per cell (`kBleed`, `kBleedFloor`) — which is what lets light cross
cell boundaries, where a falloff inside one cell only squares off against its
neighbours. The threshold is load-bearing: `kWaveNumber` puts more ripples
across the screen than there are cells, so an unthresholded bloom is a *second
picture* of the water at a finer scale than the grid can show, and the field
comes back as a bright wash with smooth arcs crossing the dots out of register.
Only crests glow, so the body stays near-black and the bloom's fine detail only
ever lands where the dots are already big enough to hide it.

## The overlay: the launch screen is being watched

Over the water sits a pattern-recognition overlay — reticles, track IDs, a
correlation graph, a fitted epicentre, readouts — and the whole claim of it is
that none of it is staged. `Shaders/RippleSurface.h` holds the height field so
`PixelRipple.metal`, which draws it, and `FieldAnalysis.metal`, which samples it
once per cell, cannot be working from different water. The sampler reads the
**displayed**, palette-quantised level, so the analysis is looking at the
*screen* rather than at the wave underneath it — which is also what makes its
boxes land on dot boundaries and visibly contain whole emitters.
`Utilities/FieldAnalysis.swift` is the pipeline, and it is the ordinary one:
adaptive z-score threshold (floored, or the slow swell registers as structure),
8-connected components, weighted moments and a 2×2 covariance eigensolve for the
orientation and the class label, greedy gated association plus an alpha-beta
filter for the tracks, Pearson correlation between track level-histories for the
graph's edges, and a Kåsa circle fit for the model.

**Two measured numbers are the point**: `v̂` regresses the fitted radius against
time and `λ̂` transforms the radial profile about the epicentre, and they land
on `kWaveSpeed` (0.42) and `kWaveNumber` (7.32 cycles/width) — the constants
that generated the water — having never been told either. They are no longer
*shown*: the screen is now only the marks that sit on the water, so
`tools/fieldprobe` — which compiles the shipping pipeline against the shipping
kernel and prints every tick of a launch — is the only place they can be read,
and the place to check they still land.

Four things are load-bearing and were each got wrong first. Morphological
closing before labelling bridges arcs belonging to *different* drops (one
245-cell blob across half the screen), so the detector uses raw connectivity.
The speed regression has to reset on a gap, or the ticks where no crest was
actually followed average in and the wave reads at half speed. The published
hypothesis has to prefer a still-*advancing* front, because a spent ring goes on
collecting fits from its inner crests and otherwise pins the crosshair to the
first drop forever. And the row DFT this started with came back 40% low: a row
crosses a ring obliquely and the wave is barely one and a half cycles wide
inside its envelope, so what it measured was the envelope — radially there is no
obliquity.

It runs at **12 Hz against the field's 60** and nothing in it is animated or
interpolated; that mismatch is what reads as inference instead of ornament, and
smoothing the labels' travel is the one change that would make the whole thing
look fake. Drawn in `Phosphor.lit` with one **neon green** accent for state,
deliberately off `Colorways.h`: the palette lights the water and the mark as one
surface, and this layer is the *other* system in the picture. The accent has to
stay a *lime* green — the water's ramp climbs through an emerald at `high`, and
an accent near that hue stops reading as the instrument.

**Nothing on this layer is chrome.** It was a header block and a footer block
once — status line, counters, τ/μ/σ, a level histogram, the model line — and all
of it is gone: what is left is only what a measurement puts somewhere, so every
mark on screen is anchored to a number and there is no fixed furniture for the
eye to file as decoration. Deleting the histogram took its palette read-back
with it (`fieldPaletteKernel`, `FieldPalette`, and the runner's copy), since
colouring those bars in the field's own ramp was the only thing any of it ever
did. Everything is in cell units until `FieldAnalysisOverlay` draws it; only
labels are clamped on screen, never geometry — the band is the safe area now
that there are no readout blocks to collide with — and the whole layer gets one
dark shadow pass because a 9pt number lands on a blown-out crest sooner or
later.

## Every launch is a different field

`surfaceAt` takes a `seed` that offsets the placement hash, so the eight drops
land somewhere new each run while the choreography — the timing, the speed, the
ripple pitch, the shape of the fill — stays exactly as tuned.
`PixelRippleField.seed` owns the one copy and gives it to **both** the shader
and the analysis; different seeds there and the overlay is measuring water that
isn't on screen. It is kept under 4096 for a precision reason spelled out at
`surfaceAt`: as a `float`, a seed near 1e8 makes `cycle + 1` unrepresentable and
every slot stops recycling. Both tools pass **0**, the field this was tuned on —
`ripplepreview`'s contact sheet has to vary only the colorway, and `fieldprobe`
takes a seed argument so the measurements can be checked on fields nobody tuned
against (across five, v̂ lands within −17%…+1% and λ̂ within −7%…−2%).

## The glass plaque

**The wordmark stands on a `.clear` Liquid Glass plaque** on the splash (not on
the sign-in screen, which has a flat panel to stand out from). It is **raked to
the letters' angle by handing Apple's glass a sheared `Shape`**
(`SlantedPlaque`, in `AdditWordmark.swift`, whose `slant` must match `kSlant`) —
`.glassEffect(_:in:)` lenses whatever outline it is given, so there is no reason
to transform the view or to hand-roll a lookalike glass. `.clear` rather than
the `.regular` the rest of the app uses: over a field this dark `.regular`'s
frost lightens the plaque into a grey slab, where clear glass stays a lens and
the water visibly refracts through it. It fades with the **field**, not with the
mark — glass is only the water seen through something, so a plaque outliving the
ripples is a slab on black, and the beat this screen ends on is the app's name
alone. And no `GlassRim` on it: that hairline is for floating surfaces the kit
draws itself out of a material, and real glass brings its own specular edge.

Compare them with `tools/ripplepreview`, which `#include`s both shipping shaders
and draws the real launch screen at the phone's own size — `renderRipple` and
`renderWordmark` exist as plain functions beside their `[[stitchable]]` entry
points so a tool can pass a colorway where the app passes a constant.
