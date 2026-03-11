# Repository Guidelines

## Project Structure & Module Organization
`Addit/` contains the app source. `Views/` holds SwiftUI screens and player UI, `Services/` contains Google Drive, auth, caching, and playback logic, `Models/` defines SwiftData and API models, and `Utilities/` stores shared constants. App entry points live in `Addit/AdditApp.swift` and `Addit/ContentView.swift`. Assets are under `Addit/Assets.xcassets`. Project configuration is in `Addit.xcodeproj` and the root [`Info.plist`](/Users/log/proj/Addit/Info.plist).

## Build, Test, and Development Commands
Use Xcode for simulator runs, but these terminal commands cover the main workflows:

```zsh
open Addit.xcodeproj
xcodebuild -project Addit.xcodeproj -scheme Addit -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -project Addit.xcodeproj -scheme Addit clean
```

`open` launches the project in Xcode. `xcodebuild ... build` performs a CLI build for the `Addit` app target. `clean` clears derived build artifacts when Xcode gets stuck.

## Coding Style & Naming Conventions
Follow standard Swift style: 4-space indentation, one type per file, and descriptive names. Use `UpperCamelCase` for types (`GoogleDriveService`), `lowerCamelCase` for properties and functions, and keep view names aligned with screen purpose (`LibraryView`, `NowPlayingView`). Prefer small service methods and keep Drive/API constants centralized in `Addit/Utilities/Constants.swift`. No formatter or linter is configured in this repo, so match the surrounding file style.

## Feature Conventions
Album artwork source-of-truth is the JPEG in the album's root Google Drive folder. Persisted `Album.coverFileId` is only a cache of that lookup, and user-selected replacements should be uploaded as `cover.jpg`.
Use Drive `capabilities.canEdit` to gate album file edits; `canAddChildren` is only relevant when creating new files or folders.

## Testing Guidelines
There is currently no XCTest target in the project. New features should add focused tests when practical, ideally in a future `AdditTests/` target using XCTest. Until then, validate changes with simulator builds and manual checks for sign-in, album sync, playback controls, and track ordering.

## Commit & Pull Request Guidelines
Recent commits use short, plain-English subjects (`edit artist name`). Keep commit messages concise, imperative, and specific to one change. For pull requests, include:
- a brief summary of user-visible behavior
- any OAuth, plist, or simulator setup needed to verify
- screenshots or screen recordings for UI changes
- linked issue or task context when available

## Security & Configuration Tips
Do not commit real Google OAuth credentials. Local setup requires updates to `Addit/Utilities/Constants.swift` and `Info.plist`; use placeholder values in source control and keep production client IDs out of commits.
