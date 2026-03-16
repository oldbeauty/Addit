# Addit

A native iOS music player backed by Google Drive. Browse your Drive folders as albums, build a personal library, and stream with full playback controls — without downloading your entire collection.

## Features

- **Google Drive as your music library** — Sign in with Google and add any folder (owned or shared) as an album, or create new albums directly from the app
- **Streaming with smart caching** — Tracks stream on demand and cache locally; upcoming tracks are prefetched for gapless playback
- **Full playback controls** — Play/pause, skip, shuffle, repeat, scrubbing, and queue management from both the in-app player and mini player bar
- **Lock screen & Control Center** — Background audio with Now Playing controls and album artwork
- **Album art** — Set cover images from your photo library or files, with cropping; artwork displays in the library, player, and lock screen
- **Collaborative track ordering** — Editors can reorder tracks and organize with disc markers; ordering is stored as `.addit-data` in the Drive folder so all users see the same layout
- **Sharing & permissions** — View and manage Google Drive folder permissions directly in the app — add people, change roles, toggle link sharing
- **Library modes** — Grid or list view with drag-to-arrange album ordering
- **Theming** — Choose from a palette of accent colors
- **Auto-sync** — Album contents sync from Drive each time you open them

## Requirements

- iOS 18.0+
- Xcode 16.0+

## Getting Started

1. Clone the repo and open `Addit.xcodeproj` in Xcode
2. Let Xcode resolve the **GoogleSignIn-iOS** SPM dependency (should happen automatically)
3. Select your target device or simulator and build & run

The Google OAuth client is already configured in the project — no additional setup is needed.

## Architecture

```
Addit/
├── AdditApp.swift                 # Entry point, service wiring, SwiftData container
├── ContentView.swift              # Auth gate + root navigation
├── LaunchScreen.storyboard        # Launch screen
│
├── Models/
│   ├── Album.swift                # SwiftData model — Drive folder as album
│   ├── Track.swift                # SwiftData model — audio file as track
│   ├── AdditMetadata.swift        # .addit-data JSON schema, disc markers
│   └── DriveModels.swift          # Drive API response types, permissions
│
├── Services/
│   ├── GoogleAuthService.swift    # Google Sign-In + token management
│   ├── GoogleDriveService.swift   # Drive API v3 REST client
│   ├── AudioPlayerService.swift   # AVPlayer engine, queue, remote commands
│   ├── AudioCacheService.swift    # On-device audio file cache
│   ├── AlbumArtService.swift      # Cover art memory + disk cache
│   └── ThemeService.swift         # Accent color persistence
│
├── Views/
│   ├── SignInView.swift           # Sign-in screen
│   ├── LibraryView.swift          # Album grid/list, arrange mode, metadata editor
│   ├── AlbumDetailView.swift      # Track list, disc markers, sync, playback
│   ├── AddAlbumView.swift         # Browse Drive folders to add existing albums
│   ├── CreateAlbumView.swift      # Pick location + create new album folder
│   ├── DriveAudioPickerView.swift # Browse Drive to add tracks to an album
│   ├── NowPlayingView.swift       # Full-screen player
│   ├── NowPlayingBar.swift        # Mini player overlay
│   ├── QueueView.swift            # Playback queue display
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
| **GoogleAuthService** | OAuth 2.0 sign-in, token refresh, user info |
| **GoogleDriveService** | All Drive API calls — files, folders, permissions, uploads |
| **AudioPlayerService** | AVPlayer queue, shuffle/repeat, Now Playing info center |
| **AudioCacheService** | Downloads and caches audio to disk, prefetches next tracks |
| **AlbumArtService** | Two-tier cover art cache (NSCache + disk), Drive download fallback |
| **ThemeService** | Persists selected accent color to UserDefaults |

### Data

Local persistence uses **SwiftData** with two models:

- **Album** — Maps to a Google Drive folder. Stores folder ID, display name, artist, cover art references, track count, ordering, and edit permissions.
- **Track** — Maps to an audio file in Drive. Stores file ID, name, MIME type, duration, and track number.

Track ordering and disc markers are stored in a `.addit-data` JSON file within each Drive folder, keeping the layout collaborative across devices and users.

## License

This project is provided as-is for personal use.
