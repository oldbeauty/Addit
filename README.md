# Addit

A native iOS music player backed by Google Drive and local iPhone storage. Browse your Drive folders as albums, import audio from your device, build a personal library, and stream with full playback controls — without downloading your entire collection.

## Features

- **Dual library: Google Drive + iPhone Storage** — Toggle between your Google Drive library and locally imported music from the nav bar dropdown
- **Multi-account Google Sign-In** — Sign in with multiple Gmail accounts and switch between them; each account has its own isolated library and data
- **Google Drive as your music library** — Sign in with Google and add any folder (owned or shared) as an album, or create new albums directly from the app
- **iPhone Storage library** — Import audio files or folders directly from your device; files are copied into the app for permanent offline access
- **Streaming with smart caching** — Drive tracks stream on demand and cache locally; upcoming tracks are prefetched for gapless playback
- **Gapless playback** — Seamless transitions between tracks with no gap, using pre-scheduled audio segments via AVAudioEngine
- **Full playback controls** — Play/pause, skip, shuffle, repeat, scrubbing, and queue management from both the in-app player and mini player bar
- **Cross-library queueing** — Queue and play tracks from both Google Drive and iPhone Storage libraries simultaneously
- **Lock screen & Control Center** — Background audio with Now Playing controls and album artwork
- **Live EQ visualizer** — Swipe left on the album cover in full player mode to see a real-time frequency spectrum analyzer (20 Hz–20 kHz, powered by AVAudioEngine + Accelerate FFT)
- **Album art** — Set cover images from your photo library or files, with cropping; artwork displays in the library, player, and lock screen
- **Collaborative track ordering** — Editors can reorder tracks and organize with disc markers; ordering is stored as `.addit-data` in the Drive folder so all users see the same layout
- **Sharing & permissions** — View and manage Google Drive folder permissions directly in the app — add people, change roles (viewer, commenter, editor), toggle link sharing
- **Group chat** — Real-time messaging per album via Google Drive comments, with liquid glass UI, member avatars, and inline navigation to sharing settings
- **Library modes** — Grid or list view with drag-to-arrange album ordering and search
- **Track management** — Per-track ellipsis menu with file info (date modified, file type), download/share via iOS share sheet, and offline access toggle
- **Album download** — Download an entire album as a zip file via the iOS share sheet
- **Broad format support** — Plays MP3, M4A, WAV, AAC, AIFF, FLAC, and more; automatically converts incompatible formats using AVAssetExportSession/AVAssetReader fallbacks
- **Theming** — Choose from a palette of accent colors
- **Auto-sync** — Album contents sync from Drive each time you open them

## Requirements

- iOS 26.0+
- Xcode 26.0+
- An Apple ID for code signing (free Apple Developer account is fine — no paid Developer Program enrollment required)

## Getting Started

The project intentionally keeps signing settings out of the shared `project.pbxproj`. Each developer supplies their own bundle identifier and team ID via a gitignored `Local.xcconfig` file. This avoids the constant tug-of-war that happens when multiple people on free Apple accounts try to sign the same app — Apple won't let two personal teams claim the same bundle ID.

### 1. Clone and open the project

```bash
git clone https://github.com/beautyville/Addit.git
cd Addit
open Addit.xcodeproj
```

Let Xcode resolve the **GoogleSignIn-iOS** SPM dependency (should happen automatically on first open).

### 2. Create your `Local.xcconfig`

A template is committed at `Addit/Local.xcconfig.example`. Copy it to `Local.xcconfig` (same folder) — this file is gitignored, so your values stay on your machine.

```bash
cp Addit/Local.xcconfig.example Addit/Local.xcconfig
```

Edit the new file:

```
PRODUCT_BUNDLE_IDENTIFIER = yourname.Addit
DEVELOPMENT_TEAM = ABCDE12345
```

- **`PRODUCT_BUNDLE_IDENTIFIER`**: pick a string unique to you (e.g. `yourname.Addit`, `com.yourname.addit`). Apple will refuse signing if another personal team has already claimed the same string.
- **`DEVELOPMENT_TEAM`**: your 10-character team ID. Find it in **Xcode → Settings → Accounts → click your Apple ID → "Personal Team" row → "Team ID" column**.

### 3. Trigger signing in Xcode

1. In the project navigator, select the project, then the `Addit` target.
2. Go to the **Signing & Capabilities** tab.
3. Confirm **Automatically manage signing** is checked.
4. Bundle Identifier should already read whatever you put in `Local.xcconfig`.
5. If **Team** shows "None", pick your Personal Team from the dropdown.

Picking a team in the UI may cause Xcode to re-stamp `DEVELOPMENT_TEAM` directly into `project.pbxproj`. If you plan to commit and push back, run this cleanup first so your team ID doesn't end up in the shared file:

```bash
sed -i '' '/DEVELOPMENT_TEAM = /d' Addit.xcodeproj/project.pbxproj
```

Then verify everything still resolves correctly from the xcconfig:

```bash
xcodebuild -project Addit.xcodeproj -scheme Addit -destination 'generic/platform=iOS' \
  -showBuildSettings 2>/dev/null | grep -E "PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM"
```

You should see your bundle ID and team ID, both sourced from `Local.xcconfig`.

### 4. Build and run

Plug in your iPhone (or pick a simulator), select it as the run destination, and hit ⌘R.

> **Free signing caveat**: provisioning profiles for free Apple accounts expire every **7 days**. You'll need to redeploy from Xcode roughly weekly. The paid Apple Developer Program ($99/year) extends this to a year, but isn't required to develop or test.

### Google OAuth

The Google OAuth client is provided separately by the project owner. No setup is needed on your end — sign-in works out of the box once the app is running.

### Working with collaborators

The xcconfig setup is what allows multiple developers on free Apple accounts to share this codebase without stepping on each other's signing settings. A few things to know:

- **Your `Local.xcconfig` never goes through git.** It's covered by the `*.xcconfig` rule in `.gitignore`. Pulls and pushes leave it untouched.
- **Don't edit signing settings in Xcode unless you have to.** Toggling auto-signing or changing team picks tends to make Xcode re-stamp `DEVELOPMENT_TEAM` into `project.pbxproj`. If that happens, run the `sed` line from step 3 above before committing.
- **Bundle IDs are claimed per Apple ID.** Whoever signs first with a given bundle ID locks it to their team. If you see "Failed Registering Bundle Identifier: cannot be registered to your development team," another collaborator (or someone else entirely) has already claimed that string. Just pick a more unique one in your `Local.xcconfig`.
- **First run on a device gives you an empty library.** Different bundle IDs are different apps to iOS — your old install lives in its own sandbox container with its own data. Either delete the old install via **Settings → General → iPhone Storage** or accept that you'll re-sign in to Drive on the new build.

## Architecture

```
.
├── Addit.xcodeproj
├── Info.plist
├── README.md
└── Addit/
    ├── Local.xcconfig.example         # Template — copy to Local.xcconfig (gitignored)
    │
    ├── AdditApp.swift                 # Entry point, service wiring, SwiftData container
    ├── AccountContainerView.swift     # Per-account SwiftData container management
    ├── ContentView.swift              # Auth gate + root navigation
    ├── LaunchScreen.storyboard
    │
    ├── Models/
    │   ├── Album.swift                # SwiftData model — Drive folder or local album
    │   ├── Track.swift                # SwiftData model — audio file (Drive or local)
    │   ├── AdditMetadata.swift        # .addit-data JSON schema, disc markers
    │   ├── DriveModels.swift          # Drive API response types, permissions
    │   └── AccountManager.swift       # Multi-account storage and switching
    │
    ├── Services/
    │   ├── GoogleAuthService.swift    # Google Sign-In, multi-account, token management
    │   ├── GoogleDriveService.swift   # Drive API v3 REST client
    │   ├── AudioPlayerService.swift   # AVAudioEngine playback, gapless, queue, remote commands
    │   ├── AudioCacheService.swift    # On-device audio file cache with format conversion
    │   ├── AudioAnalyzerService.swift # Real-time FFT spectrum analysis for EQ visualizer
    │   ├── AlbumArtService.swift      # Cover art memory + disk cache
    │   └── ThemeService.swift         # Accent color persistence
    │
    ├── Views/
    │   ├── SignInView.swift           # Sign-in screen
    │   ├── LibraryView.swift          # Album grid/list, search, arrange mode, metadata editor, local import
    │   ├── AlbumDetailView.swift      # Track list, disc markers, sync, playback, track menus
    │   ├── AddAlbumView.swift         # Browse Drive folders to add existing albums
    │   ├── CreateAlbumView.swift      # Pick location + create new album folder
    │   ├── DriveAudioPickerView.swift # Browse Drive to add tracks to an album
    │   ├── NowPlayingView.swift       # Full-screen player with album-to-halo morph and EQ swipe
    │   ├── NowPlayingBar.swift        # Mini player overlay with waveform scrubber
    │   ├── EQVisualizerView.swift     # Real-time frequency spectrum display
    │   ├── QueueView.swift            # Playback queue display
    │   ├── ChatView.swift             # Per-album group chat (Drive comments)
    │   ├── SettingsView.swift         # Settings + theme picker
    │   ├── ImageCropperView.swift     # Cover art crop tool
    │   ├── SharingSheet.swift         # Drive permissions management
    │   ├── PixelSortCoverView.swift   # Tap-to-sort luminance visualizer for album covers
    │   └── FadingTruncation.swift     # Reusable text-fade-out modifier for clipped labels
    │
    └── Utilities/
        └── Constants.swift            # Client ID, API base URL, MIME types
```

### Services

All services use `@Observable` and are injected via SwiftUI's `@Environment`.

| Service | Role |
|---|---|
| **GoogleAuthService** | OAuth 2.0 sign-in, multi-account management, token refresh |
| **GoogleDriveService** | All Drive API calls — files, folders, permissions, comments, uploads |
| **AudioPlayerService** | AVAudioEngine queue, gapless playback, shuffle/repeat, Now Playing info center |
| **AudioCacheService** | Downloads and caches audio to disk, prefetches next tracks, format conversion |
| **AudioAnalyzerService** | Real-time FFT spectrum analysis via Accelerate framework |
| **AlbumArtService** | Two-tier cover art cache (NSCache + disk), Drive download fallback |
| **AccountManager** | Persists known accounts, handles per-account data isolation |
| **ThemeService** | Persists selected accent color to UserDefaults |

### Data

Local persistence uses **SwiftData** with two models:

- **Album** — Maps to a Google Drive folder or a locally imported album. Stores folder ID, display name, artist, cover art references, track count, ordering, edit permissions, and storage source (Google Drive or local).
- **Track** — Maps to an audio file in Drive or a local file on device. Stores file ID, name, MIME type, duration, track number, and optional local file path.

Track ordering and disc markers are stored in a `.addit-data` JSON file within each Drive folder (for Drive albums) or in the SwiftData `cachedTracklist` field (for local albums), keeping the layout collaborative across devices and users.

Each Google account gets its own SwiftData store and cache directory, ensuring complete data isolation between accounts.

## README encoding

The repo includes two helper scripts at the root for toggling the README between its plaintext form and a base64-encoded form:

```bash
./encode_readme    # plaintext → encoded
./decode_readme    # encoded → plaintext
```

When encoded, `README.md` is replaced with a short decode-instruction stub plus a base64 blob. Run `./decode_readme` to restore it byte-for-byte. Both scripts are **idempotent** — there are only two possible states (encoded and decoded), and running either script when the README is already in that state is a no-op. You can toggle as many times as you want without tracking how many; the result is always one of those two states.

The scripts are pure bash with no dependencies beyond `base64` and `awk`, both pre-installed on macOS and any standard Linux environment.

## License

This project is provided as-is for personal use.
