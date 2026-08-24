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
- **Raymarched glass** (`Shaders/`, auto-added by the synchronized file group):
  `PlasmaOrb.metal` (toolbar bauble) and `GlassLogo.metal` (the three library
  marks) share the lighting rig in `GlassRoom.h` — keep the room, film and tone
  map there so the ornaments stay a set. Scroll-driven motion is shared too:
  `ScrollTorque` owns the velocity-derived twist, each view derives its own
  orientation from the offset. Brand marks *rock*, they don't spin —
  `AccessIcons.metal` (globe / hazard plate / chrome chain, on the Access
  sheet) follows that too, the turning globe being the deliberate exception.
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
  does this when **`og:type` is `music.song`**, which is why album pages claim
  that too. `LPLinkMetadata` has no subtitle field, so a hand-built one can
  never carry the artist; `AlbumLinkShareItem` therefore *fetches* the page's
  metadata and swaps only `imageProvider` for the on-device cover. That is what
  gets both — the artist Apple resolved, and art the unauthenticated fetcher
  could never see inside a restricted folder (or on OneDrive at all). The
  `?c=` Drive id and `/cover` only serve `og:image`, i.e. links someone *pastes*
  elsewhere; `/cover` sits outside the AASA's `/a/*` claim deliberately.
- **Navigation**: `ContentView` is the auth gate → `LibraryView` in a
  `NavigationStack`. `NowPlayingBar` mini-player overlays; `NowPlayingView` is a
  sheet. Accent color is scheme-aware (bridged into `ThemeService.currentScheme`).

## Conventions

- SwiftUI + Observation (`@Observable`) — not Combine/`ObservableObject`.
- Unsupported audio formats convert via AVAssetExportSession/AVAssetReader in
  `AudioCacheService`; a hard failure surfaces through `playerService.failedTrack`
  (alert in `ContentView`). MIME allow-list in `Constants.audioMimeTypes`.
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
