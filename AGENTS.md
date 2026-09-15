# AGENTS.md — Addit

Always-on working context for this repo. Human setup/feature docs live in
`README.md` (not auto-loaded — length is free there). **Deep playback internals
live in `skill://audio-playback`; read it before touching playback, queue,
gapless, or now-playing UI — those invariants are subtle and easy to revert.**

Native iOS music player (iOS 26+, Xcode 26+, SwiftUI + SwiftData) backed by
Google Drive + OneDrive + local iPhone storage.

## Build & verify

No test target — verify changes by **building** (ideally running on a sim/device).
Say so in any verification claim; don't imply tests ran.

```bash
xcodebuild -project Addit.xcodeproj -scheme Addit \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Signing check (device builds): append
`-showBuildSettings | grep -E "PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM"`.

## Hard rules

- Signing lives in **gitignored `Addit/Local.xcconfig`** (copy from
  `Local.xcconfig.example`). NEVER commit `DEVELOPMENT_TEAM` into
  `Addit.xcodeproj/project.pbxproj`; if Xcode re-stamps it, strip with
  `sed -i '' '/DEVELOPMENT_TEAM = /d' Addit.xcodeproj/project.pbxproj`. Each
  contributor uses a **unique** `PRODUCT_BUNDLE_IDENTIFIER` (free Apple personal
  teams can't share IDs).
- Google OAuth client ID is duplicated in `Constants.swift` + `Info.plist`
  (`GIDClientID` + the `com.googleusercontent.apps.*` URL scheme) — keep in sync.
- OAuth uses the **full `drive` scope** (settled — collaborative editing of
  shared folders needs it; not `drive.file`). App Store/external distribution
  needs a CASA Tier 2 assessment; internal TestFlight does not.
- Microsoft auth is **hand-rolled PKCE over ASWebAuthenticationSession**
  (`MicrosoftAuthService`), NOT MSAL — fixed redirect `addit-msauth://callback`
  works for every contributor's bundle ID with one Azure registration. No
  Info.plist URL scheme needed. Don't "upgrade" to MSAL without re-solving that.
- OneDrive file/folder IDs are composite **`driveId|itemId`** (Graph IDs are
  per-drive). Only `OneDriveService` may split them; everywhere else they're
  opaque. The `|` is also the provider discriminator in
  `CloudServiceRouter.service(forFileId:)` — Google IDs can never contain it.
- Background audio depends on `UIBackgroundModes: audio` in `Info.plist` — keep it.
- **Album share links are a two-sided handshake.** `Addit.entitlements`
  (`applinks:hollowpoint.tv`) and `~/HollowpointTv/.well-known/apple-app-site-association`
  (`WU764N7X65.tv.hollowpoint.addit`) must agree — neither half does anything
  alone, and a mismatch fails silently by opening Safari. The AASA has **no file
  extension**, so `deploy.sh`'s rsync allow-list needs its explicit `--include`.
  iOS fetches it at *install*, so publish the site before shipping a build.
  The `addit://` scheme in `Info.plist` is a Simulator testing shim only —
  Messages doesn't linkify custom schemes, which is the whole reason the
  shipping format is `https`.

## Architecture (one-liners)

- **Services** are `@Observable`, constructed once in `AdditApp` (its `init()`)
  as `@State`, injected via `.environment(...)`, read with `@Environment(X.self)`.
  NEVER instantiate a service inside a view. Under `Services/`: GoogleAuth,
  MicrosoftAuth, CloudAuthCoordinator (unified session facade — views use this,
  not the concrete auth services), GoogleDrive, OneDrive, CloudDriveService
  (protocol + CloudServiceRouter), AudioPlayer, AudioCache, AudioAnalyzer
  (FFT/EQ), AlbumArt, AccountManager, Theme.
- **Provider routing**: views never hold a concrete drive client. Album-scoped
  views compute `driveService` = `cloudRouter.service(for: album)` (routes on
  `Album.storageSource`); account-scoped flows (browse/add/create/import) use
  `cloudRouter.activeService`. Albums are stamped with
  `authService.activeProvider.storageSource` at creation — that stamp routes
  everything afterward. Provider gaps are capability flags on the protocol
  (`supportsComments`/`supportsStarred`/`supportsCommenterRole`), not provider
  checks in views. Chat is Google-only: `ChatView` keeps the concrete
  `GoogleDriveService`.
- **SwiftData**: models `Album`, `Track`. **One shared `ModelContainer`**
  (`AccountContainerView.sharedContainer`, defined inside `AdditApp.swift`);
  per-account isolation is via `Album.accountId`, not separate stores. The audio
  **cache** directory *is* per-account.
- **Enum fields**: store a raw `String?` + computed wrapper — see
  `Album.storageSource` over `storageSourceRaw`. Follow this for new enum fields.
- **On-device paths**: persist **relative-to-Documents**, never absolute (the
  container UUID changes between installs). Reuse the resolution logic in
  `Track.localFileURL` / `Album.resolvedLocalCoverPath`.
- **Track ordering / disc markers**: `.addit-data` JSON in the Drive folder
  (collaborative) or `Album.cachedTracklist` (local). Schema in `AdditMetadata`.
- **The wordmark is geometry, not type, and false colour, not a material.**
  `Wordmark.metal` draws "ADDIT" as hand-authored polygons — the coordinates
  *are* the typeface, terminals all flat at cap and baseline — extruded along a
  sheared axis and raymarched; `AdditWordmark.swift` only sizes it and supplies
  the clock. The surface is a **readout** — each point's reflected elevation
  looked up in a palette — and which palette is `kMarkPalettes` picked by
  `kMarkColorway`, in three structures: `kModeZones` measures (three colours
  keyed to elevation with black between them, so the *gaps* draw the
  letterforms), `kModeRoom` lights (borrowing `GlassRoom.h`'s rig, which makes
  the mark one of the glass ornaments instead of an instrument — this file
  pointedly used not to include that header), and `kModeRamp` borrows the
  launch field's own `spectrum`. **7 · field** ships, which is the last of
  those: the letters and the water end up on one palette by construction
  rather than by eye, and changing `kColorway` moves both. Its **halo** is the
  one part that was never the mark's own — those two colours come from
  `Colorways.h`, below. Two things are load-bearing and were each got wrong
  first. The
  face is a **dome with a circular cross-section**, because a flat face
  measures one direction across a whole letter and comes back as a plate of one
  colour, and a smoothstep dome is flat at *both* ends so it only bends in a
  ring near the edge. And every perturbation — texture especially — has to stay
  small against the palette's bands: a tilt lands twice over in the reflection,
  so anything moving elevation further than a band is wide drags the zones over
  each other and the mark turns to mush. Detail reads because the sweep is
  steep, not because the texture is strong. Turn the ramp up, not the flaws.
- **The launch screen's colour is a table.** `Shaders/Colorways.h` holds nine
  palettes — six ramp stops for the water, the rim light on its leading edges,
  and the wordmark halo's two colours — and `kColorway` picks the one that
  ships (**1, Readout**: blue → green → amber → red, the wordmark's own signal
  palette run along the water's height, so both surfaces say elevation is
  colour). One table across both shaders because the mark sits *on* the field
  and the halo is what makes them look lit by one light; split up, they drift.
  Three things constrain a new one. The breakpoints in `spectrum()` are shared
  tuning, not part of a colorway — `level` is bent down hard, so the first two
  stops are most of the screen most of the time and have to stay near-black.
  The rim lands on calm cells as well as crests, so it has to be a colour that
  survives being faint: white is *grey* at a tenth strength and speckles the
  dark half of the field with what look like dead pixels. And `kBackdrop`
  deliberately isn't per-colorway, because `LoadingSplashView` carries the same
  value in Swift. The glow is a **thresholded second pass** of the same surface
  sampled per pixel instead of per cell (`kBleed`, `kBleedFloor`) — which is
  what lets light cross cell boundaries, where a falloff inside one cell only
  squares off against its neighbours. The threshold is load-bearing: `kWaveNumber`
  puts more ripples across the screen than there are cells, so an unthresholded
  bloom is a *second picture* of the water at a finer scale than the grid can
  show, and the field comes back as a bright wash with smooth arcs crossing the
  dots out of register. Only crests glow, so the body stays near-black and the
  bloom's fine detail only ever lands where the dots are already big enough to
  hide it.
- **The wordmark stands on a `.clear` Liquid Glass plaque** on the splash (not
  on the sign-in screen, which has a flat panel to stand out from). It is
  **raked to the letters' angle by handing Apple's glass a sheared `Shape`**
  (`SlantedPlaque`, in `AdditWordmark.swift`, whose `slant` must match
  `kSlant`) — `.glassEffect(_:in:)` lenses whatever outline it is given, so
  there is no reason to transform the view or to hand-roll a lookalike glass.
  `.clear`
  rather than the `.regular` the rest of the app uses: over a field this dark
  `.regular`'s frost lightens the plaque into a grey slab, where clear glass
  stays a lens and the water visibly refracts through it. It fades with the
  **field**, not with the mark — glass is only the water seen through
  something, so a plaque outliving the ripples is a slab on black, and the beat
  this screen ends on is the app's name alone. And no `GlassRim` on it: that
  hairline is for floating surfaces the kit draws itself out of a material, and
  real glass brings its own specular edge. Compare them with `tools/ripplepreview`, which `#include`s
  both shipping shaders and draws the real launch screen at the phone's own
  size — `renderRipple` and `renderWordmark` exist as plain functions beside
  their `[[stitchable]]` entry points so a tool can pass a colorway where the
  app passes a constant.
- **Raymarched glass** (`Shaders/`, auto-added by the synchronized file group):
  `PlasmaOrb.metal` (toolbar bauble) and `GlassLogo.metal` (the three library
  marks) share the lighting rig in `GlassRoom.h` — keep the room, film and tone
  map there so the ornaments stay a set. Scroll-driven motion is shared too:
  `ScrollTorque` owns the velocity-derived twist, each view derives its own
  orientation from the offset. Brand marks *rock*, they don't spin —
  `AccessIcons.metal` (globe / hazard plate / chrome chain, on the Access
  sheet) follows that too, the turning globe being the deliberate exception.
- **3D ornaments instead of glyphs** is the house style, and it comes in two
  deliveries. *Live* (a shader view under `TimelineView`) wherever the app
  draws the surface itself — the Access sheet. *Still* wherever UIKit draws it:
  a `Menu` becomes a `UIMenu`, whose icons are `UIImage`s with no SwiftUI host
  to run a `colorEffect`, so a live shader in a menu is impossible, not merely
  slow. `MenuIcons.metal` + `MenuIconRenderer` are that second path — one
  compute kernel, rendered offscreen 3×3-supersampled into a `UIImage` the
  first time any icon is asked for, all thirteen in one command buffer. Being
  still buys the pose: each model is turned to the one angle that names it.
  Two rules when extending the set: give `MenuIcon.label` the SF Symbol you
  replaced as its `fallback` (it is what a device with no render shows), and
  mark menu images `.alwaysOriginal` or `UIMenu` template-tints them flat.
  Provider rows reuse `GlassLogo.metal`'s real brand marks through that file's
  own `glassLogoKernel` — never model a second cloud. `tools/iconpreview` runs
  both kernels on macOS and writes a contact sheet, including a row at the true
  20pt delivered size, which is the only row that decides whether a model works.
- **Share links**: `AlbumShareLink` owns the URL format
  (`https://hollowpoint.tv/a/<g|m>/<folderId>?n=`); those provider codes are a
  published format and must not follow enum renames. `.onOpenURL` in `AdditApp`
  branches share link vs Google OAuth callback — order matters, GIDSignIn
  swallows what it's handed. A link parks in `ShareLinkService` until
  `ContentView` has an account and a store to drain it into, which is what makes
  tap-link → sign-in → album work. Both the picker and links import through
  `AlbumImporter`; keep it that way or the two drift. A `?t=` on the same URL
  makes it a *song* link — the album still travels, since a track is only
  reachable through its folder, and `t` just says where to start. The preview card is
  built twice on purpose: `AlbumLinkShareItem` (`LPLinkMetadata`) uses the
  cover already in memory for the share sheet, and the site's `og:` tags +
  `/cover/<id>` carry the card. Two non-obvious rules, both established by
  rendering real `LPLinkView`s: the artist line comes from **`music:musician`**,
  which Apple *fetches* and whose page `<title>` it shows — `og:description`,
  `og:site_name` and `music:musician_description` are all ignored — and it only
  does this when **`og:type` is `music.song`**. **Only song links take that
  card.** Albums used to claim `music.song` for the same second line, but
  iMessage reads the type literally and presented the album as a track, so an
  album page is `music.album` and gets the plain title+domain card, with its
  whole billing in `og:title`: `<name> - Album by <artist>`. Don't "fix" the
  duplication by putting the artist back in an album's `og:description` — it is
  ignored here and only doubles up on Slack. `LPLinkMetadata` has no subtitle
  field, so a hand-built one can carry neither the artist nor the resolved
  title; `AlbumLinkShareItem` therefore *fetches* the page's metadata for both
  kinds of link and swaps only `imageProvider` for the on-device cover. That is
  what gets both — the line Apple resolved, and art the unauthenticated fetcher
  could never see inside a restricted folder (or on OneDrive at all). The
  `?c=` Drive id and `/cover` only serve `og:image`, i.e. links someone *pastes*
  elsewhere; `/cover` sits outside the AASA's `/a/*` claim deliberately.
- **Background work**: album transfers (duplicate / save-to-device) run through
  `TransferService` — serial, because two uploads to one account fight for the
  same rate limit. Progress for those *and* for offline downloads
  (`AudioCacheService.albumCacheProgress`) lives on the service, not the view,
  and both draw through one `ActivityRing` placed in **both** the library's and
  an album's toolbar. That second placement is the whole point: the work always
  outlived the screen (unstructured `Task`s), but the ring used to exist only in
  the album's toolbar, so leaving made a running job look stopped. Export is
  deliberately still modal — it ends in a share sheet.
- **Scroll-driven ornaments**: the library's toolbar orb and brand mark follow
  the scroll through `ScrollOffsetBox` (`ScrollTorque.swift`), an `@Observable`
  box, and **the screen that owns the box must never read `value`**. As a
  `@State CGFloat` it made `LibraryView.body` — two filtering passes over every
  album, each a SwiftData read — a dependency of the scroll, re-run every frame.
  Reading it inside the ornaments puts that dependency where the value is used.
  These two keep moving in Low Power Mode — settled; they're small, they're the
  app's signature, and the box is what made them cheap. `GlassRim`'s gyro
  highlight is the one that holds still there (`PowerState.shared.isLowPower`),
  because it's on every cover on screen: it *doesn't read* the gravity in that
  state, so it stops being invalidated rather than merely stopping moving.
- **Covers are fetched at the size they're drawn**: `AlbumArtService` keeps a
  second cache of `ImageIO` thumbnails (`thumbnail(for:pixelSize:)` /
  `thumbnail(atPath:pixelSize:)`), built off the main thread straight out of the
  file. Grid and list cells ask for their own drawn size; anything showing a
  cover large asks for `AlbumArtService.displayPixels`. Never
  `UIImage(contentsOfFile:)` on a view's `onAppear` — that's a full-resolution
  decode on the frame a row appears. **The drawn size is part of the artwork
  task's identity** (`AlbumArtworkThumbnail.artworkTaskID`): without it a cell
  laid out before its width is known keeps the thumbnail it fetched for the
  provisional size forever, and only scrolling it out of the grid and back ever
  fixes it. Relatedly, `gridLayout(for:)` refuses a non-positive width rather
  than clamping it to a 1pt cover — a `GeometryReader` reports zero on the pass
  that builds it, which is every library switch. Local covers are rewritten *in place*, so
  their cache identity carries the file's mtime and the edit path calls
  `invalidateThumbnails(atPath:)` + `bumpRefreshToken`.
- **Navigation**: `ContentView` is the auth gate → `LibraryView` in a
  `NavigationStack`. `NowPlayingBar` mini-player overlays; `NowPlayingView` is a
  sheet. Accent color is scheme-aware (bridged into `ThemeService.currentScheme`).

## Conventions

- SwiftUI + Observation (`@Observable`) — not Combine/`ObservableObject`.
- Unsupported audio formats convert via AVAssetExportSession/AVAssetReader in
  `AudioCacheService`; a hard failure surfaces through `playerService.failedTrack`
  (alert in `ContentView`). MIME allow-list in `Constants.audioMimeTypes`.
- Text entry in a popup goes through `.prompt(...)` (`Views/PromptPopup.swift`),
  **never `.alert` with a `TextField`** — alert buttons fire for a finger that
  drags onto them, so selecting text and sliding out of the field hits Cancel.
- Album blurbs are the **cloud folder's own `description` field** (Drive
  `files.description`; Graph's, which is OneDrive-Personal-only and so fine on
  the `/consumers` tenant), cached in `Album.albumDescription`. Not `.addit-data`
  — the point is that it's the same text the provider's own UI shows.
- Debug logging gated `#if DEBUG`, with filterable prefixes: **`[Q]`**
  (queue/playback decisions in `AudioPlayerService` — detailed enough to
  reconstruct the whole playback timeline) and **`[NP]`** (Now Playing artwork).

## Large files — never whole-read

Use `search` + targeted ranges: `Services/AudioPlayerService.swift` (~70KB),
`Views/LibraryView.swift` (~51KB), `Views/AlbumDetailView.swift` (~54KB),
`Views/AlbumDetailView+EditMode.swift` (~56KB — inline edit mode lives here
as an `extension AlbumDetailView`; its `@State` stays in the main file).

## Docs layout

- `README.md` — human-facing; base64-toggle via `./encode` / `./decode`
  (**README only — never encode `AGENTS.md`; it is auto-loaded every session**).
- `AGENTS.md` (this file) — slim always-on context. Keep it terse.
- `CLAUDE.md` — symlink to this file (vanilla Claude Code compatibility).
- `.omp/skills/audio-playback/SKILL.md` — deep playback internals, loaded on
  demand via `skill://audio-playback`.
