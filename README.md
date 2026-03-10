# Addit

A native iOS music player for Google Drive. Browse your Drive folders as albums, build a personal library, and listen with full playback controls — all without downloading your entire collection.

## Features

- **Google Drive as your music library** — Sign in with Google and add any folder (owned or shared) as an album
- **Streaming with smart caching** — Tracks are downloaded on demand and cached locally; the next 2 tracks are prefetched for near-gapless playback
- **Full playback controls** — Play/pause, next/previous, shuffle, repeat (off/all/one), and scrubbing from both the full player and mini player
- **Lock screen & background audio** — Control playback from the lock screen and Control Center via Now Playing integration
- **Auto-sync** — Album contents sync from Drive every time you open them — new tracks appear, deleted tracks disappear
- **Collaborative track ordering** — Editors can drag-to-reorder tracks; the order is saved as a `.addit-tracklist` file in the Drive folder so all users see the same sequence
- **Shared folder support** — Works with folders on Shared Drives and folders shared with you; permissions are refreshed on each sync

## Requirements

- iOS 26.0+
- Xcode 26.0+
- A Google Cloud project with the Google Drive API enabled

## Setup

### 1. Google Cloud Console

1. Go to [Google Cloud Console](https://console.cloud.google.com/) and create a new project (or use an existing one)
2. Enable the **Google Drive API** under APIs & Services
3. Create an **OAuth 2.0 Client ID** for iOS:
   - Application type: iOS
   - Bundle ID: your app's bundle identifier
4. Copy the generated **Client ID**

### 2. Configure the App

1. Clone this repo and open `Addit.xcodeproj` in Xcode
2. Update `Addit/Utilities/Constants.swift` with your Client ID:
   ```swift
   static let googleClientID = "YOUR_CLIENT_ID.apps.googleusercontent.com"
   ```
3. Update `Info.plist`:
   - Set `GIDClientID` to your Client ID
   - Set the URL scheme under `CFBundleURLSchemes` to your **reversed** Client ID (e.g., `com.googleusercontent.apps.YOUR_CLIENT_ID`)
4. The GoogleSignIn-iOS SPM package should resolve automatically. If not, add it via File → Add Package Dependencies with URL: `https://github.com/google/GoogleSignIn-iOS`

### 3. OAuth Consent Screen

1. In Google Cloud Console, configure the **OAuth consent screen**
2. Add the scope: `https://www.googleapis.com/auth/drive`
3. While in **Testing** mode, add your Google account as a test user
4. For public distribution, submit the app for Google verification

## Architecture

```
Addit/
├── AdditApp.swift              # App entry point, service wiring, SwiftData container
├── ContentView.swift           # Root view — auth gate + navigation
├── Models/
│   ├── Album.swift             # SwiftData model — folder as album
│   ├── Track.swift             # SwiftData model — audio file as track
│   └── DriveModels.swift       # Codable structs for Drive API responses
├── Services/
│   ├── GoogleAuthService.swift # Google Sign-In wrapper (OAuth 2.0)
│   ├── GoogleDriveService.swift# Drive API v3 REST client
│   ├── AudioCacheService.swift # Download-to-cache manager
│   └── AudioPlayerService.swift# AVPlayer engine, queue, lock screen controls
├── Views/
│   ├── SignInView.swift        # Sign-in screen
│   ├── LibraryView.swift       # Album grid with add/remove
│   ├── AddAlbumView.swift      # Folder browser + preview sheet
│   ├── AlbumDetailView.swift   # Track list, sync, reorder mode
│   ├── NowPlayingBar.swift     # Mini player overlay
│   └── NowPlayingView.swift    # Full-screen player sheet
└── Utilities/
    └── Constants.swift         # Client ID, API URLs, MIME types
```

**Key technologies:** SwiftUI, SwiftData, AVFoundation, Google Drive API v3 (REST), GoogleSignIn-iOS SDK

## How Track Ordering Works

When an editor reorders tracks in an album, a plain-text file called `.addit-tracklist` is written to the Drive folder. Each line is a filename, and line order equals track order. When any user opens the album, the app downloads this file and applies the ordering. Tracks not listed in the file are appended alphabetically at the end.

## License

This project is provided as-is for personal use.
