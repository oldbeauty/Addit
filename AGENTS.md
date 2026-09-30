# AGENTS.md — Addit

Always-on working context: the rules that matter on any task. Depth on each
subsystem lives in a skill, loaded on demand — `skill://<name>` is
`.omp/skills/<name>/SKILL.md`. **Read the matching skill before touching its
area**; the invariants in them are subtle and easy to revert. Human
setup/feature docs live in `README.md`.

Native iOS music player (iOS 26+, Xcode 26+, SwiftUI + SwiftData) backed by
Google Drive + OneDrive + local iPhone storage.

## Skills — read before touching

| Area | Skill |
|---|---|
| Playback, queue, gapless, now-playing UI | `skill://audio-playback` |
| Launch screen: wordmark, ripple field, colorways, analysis overlay, plaque | `skill://launch-screen` |
| Glass ornaments, menu icons, anything reading the scroll offset | `skill://glass-ornaments` |
| Library: folders, arrange mode, folder zoom, Sort by Color, cover thumbnails | `skill://library-screen` |
| Share links, the site handshake, link previews | `skill://share-links` |
| Sign-in, drive requests and uploads, background transfers, album sync | `skill://cloud-services` |

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
- **A Google session is adopted only through `GoogleAuthService.adopt(_:)`**,
  which requires the `drive` scope — never assign `currentUser` directly.
  Consent shows Drive as an unticked checkbox, and a session without it is a
  library where nothing plays.
- Microsoft auth is **hand-rolled PKCE over ASWebAuthenticationSession**
  (`MicrosoftAuthService`), NOT MSAL — fixed redirect `addit-msauth://callback`
  works for every contributor's bundle ID with one Azure registration. No
  Info.plist URL scheme needed. Don't "upgrade" to MSAL without re-solving that.
- OneDrive file/folder IDs are composite **`driveId|itemId`** (Graph IDs are
  per-drive). Only `OneDriveService` may split them; everywhere else they're
  opaque. The `|` is also the provider discriminator in
  `CloudServiceRouter.service(forFileId:)` — Google IDs can never contain it.
- Background audio depends on `UIBackgroundModes: audio` in `Info.plist` — keep it.
- **Album share links are a two-sided handshake**: `Addit.entitlements`
  (`applinks:hollowpoint.tv`) and `~/HollowpointTv/.well-known/apple-app-site-association`
  must agree, or links silently open Safari. iOS fetches the AASA at install,
  so publish the site before shipping a build.
- **Drive services talk through `CloudSession`, and Drive uploads stay
  resumable** — never `URLSession.shared` in a drive service, never
  `uploadType=multipart`. Both are what keep a flaky network from stalling
  every request after one dead connection.

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
- **SwiftData**: models `Album`, `Track`, `LibraryFolder`. **One shared `ModelContainer`**
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
- **Background work** is `TransferService` jobs (serial), drawn by one
  `ActivityRing` in both the library's and an album's toolbar. A job outlives
  the screen that started it, so it never touches view state. Export is the one
  deliberately modal exception.
- **Covers are fetched at the size they're drawn** — `AlbumArtService`
  thumbnails, never `UIImage(contentsOfFile:)` in `onAppear`; the drawn size is
  part of the artwork task's identity.
- **Scroll offset** lives in a `ScrollOffsetBox`, and the screen that owns the
  box never reads `value` (it made `LibraryView.body` re-run every frame).
- **Ornaments, not glyphs**: raymarched glass shares `GlassRoom.h`'s rig; menu
  icons are pre-rendered stills (`MenuIcons.metal`), since `UIMenu` can't host a
  shader.
- **Navigation**: `ContentView` is the auth gate → `LibraryView` in a
  `NavigationStack`. `NowPlayingPill` overlays it and is both the mini player and
  the full player — one glass card at two heights, no sheet; `NowPlayingView` is
  its expanded content. Accent color is scheme-aware (bridged into
  `ThemeService.currentScheme`).

## Conventions

- SwiftUI + Observation (`@Observable`) — not Combine/`ObservableObject`.
- Unsupported audio formats convert via AVAssetExportSession/AVAssetReader in
  `AudioCacheService`; a hard failure surfaces through `playerService.failedTrack`
  (alert in `ContentView`). MIME allow-list in `Constants.audioMimeTypes`.
- **No scroll bars**: `.scrollIndicators(.hidden)` on the app root *and* on the
  content of every `.sheet` / `.fullScreenCover` — the environment doesn't
  cross a presentation.
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

Use `search` + targeted ranges: `Services/AudioPlayerService.swift` (~97KB),
`Views/AlbumDetailView.swift` (~96KB), `Views/NowPlayingView.swift` (~83KB),
`Views/LibraryView.swift` (~79KB), `Views/LibraryArrange.swift` (~42KB),
`Views/AlbumDetailView+EditMode.swift` (~83KB — inline edit mode lives here
as an `extension AlbumDetailView`; its `@State` stays in the main file),
`Utilities/FieldAnalysis.swift` (~48KB — the launch overlay's pipeline; the
stages are separable, so read the one you need).

## Docs layout

- `README.md` — human-facing; base64-toggle via `./encode` / `./decode`
  (**README only — never encode `AGENTS.md`; it is auto-loaded every session**).
- `AGENTS.md` (this file) — slim always-on context. Keep it terse: rules and
  pointers here, reasoning and history in a skill.
- `CLAUDE.md` — symlink to this file (vanilla Claude Code compatibility).
- `.omp/skills/<name>/SKILL.md` — the skills in the table above, loaded on
  demand via `skill://<name>`.
