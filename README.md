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

## Getting Started

1. Clone the repo and open `Addit.xcodeproj` in Xcode
2. Let Xcode resolve the **GoogleSignIn-iOS** SPM dependency (should happen automatically)
3. Select your target device or simulator and build & run

The Google OAuth client is already configured in the project — no additional setup is needed.

## Architecture

```
Addit/
├── AdditApp.swift                 # Entry point, service wiring, SwiftData container
├── AccountContainerView.swift     # Per-account SwiftData container management
├── ContentView.swift              # Auth gate + root navigation
├── LaunchScreen.storyboard        # Launch screen
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
│   ├── NowPlayingView.swift       # Full-screen player with EQ visualizer
│   ├── NowPlayingBar.swift        # Mini player overlay
│   ├── AudioVisualizerView.swift  # Real-time frequency spectrum display
│   ├── QueueView.swift            # Playback queue display
│   ├── ChatView.swift             # Per-album group chat (Drive comments)
│   ├── SettingsView.swift         # Settings + theme picker
│   ├── ImageCropperView.swift     # Cover art crop tool
│   └── SharingSheet.swift         # Drive permissions management
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

## License

This project is provided as-is for personal use.
