---
name: folder-tracking
description: How Addit's folder tracking works — the Tracking screen (the eyeball left of search pushes it, like an album), what counts as new and why snapshots only grow, baselines, when checks run, how each drive lists many folders at once (Drive's OR'd-parents batches, ListingQueue's splitting), attribution and "you added", and the per-account file. READ THIS before editing FolderWatch.swift, FolderWatchService, FolderWatchView, listWatchedChildren in either drive service, or TrackFolderPicker.
---

# Folder tracking (Addit)

"Tracking" in the UI, "watch" in code — a `Track` is a song, and
`TrackedFolder.tracks` would read as a folder's songs. Tracking tells you when
a subfolder or a track appears in a tracked folder. Every album in the viewed
cloud library is tracked automatically; the user can pin more, and what that's
most for is a **folder of albums** ("Good Music") that isn't an album itself:
a friend who tracks it sees each album added to it, and can add one to their
library from the event.

**It's pushed, like an album.** The eye pushes `LibraryRoute.tracking` onto
the library's navigation stack, so tracking arrives with the same flat slide
and back button as an album page, and an album opened from it is pushed on top
(back returns to tracking). The path is `[LibraryRoute]` — `.album` or
`.tracking` — for exactly that. It was a sheet first, then an in-place screen
the albums slid away from, then parted down the middle for (a UIKit snapshot
cut in two, the orb turning into a back chevron); all three were replaced, the
last on 2026-10-10 at the user's ask, by the push. "Opened" is the screen
appearing, which includes coming back to it from an album.

Inside, two panes — **Activity** and **Tracked** — a swipe apart (a paging
`TabView`) and switched as well by a floating Liquid Glass capsule at the
bottom (`TrackingPaneBar`): a hollow rounded triangle for Activity, a hollow
rounded square for Tracked, white for the pane on screen and grey for the
other, no labels and no selection blob — all asked for (2026-10-10), and all
things the system tab bar can't do, which it briefly was. A tap that changes
pane pops a haptic; a swipe doesn't (`tapSwitches` is the trigger, not the
selection). Each pane is its own list with its own large title (Activity's
carries the last-checked readout) and its own pull to check. The bar is a
bottom safe-area inset, so lists rest above it and scroll under its glass;
with a track playing it stands `NowPlayingPill.overlayHeight` up, on top of
the mini player, as the library's + button does. Activity is the left page,
so a drag from the screen's left edge there would bounce the pager instead of
going back: `FlatSlideCoordinator` makes any sideways scroller wait for its
edge swipe to fail (`shouldBeRequiredToFailBy`). Checked in the simulator:
paging, tapping and the bar's look; the edge swipe can't be synthesized there
(it doesn't fire on an album page either), so that one is the phone's to show.

Files: `Models/FolderWatch.swift` (the model and every rule below that can be
checked away from the app), `Services/FolderWatchService.swift` (checks,
accounts, the file), `Views/FolderWatchView.swift` (button, the panel, when checks
run), `TrackFolderPicker` + `FolderBrowserView(onTrack:)` in `AddAlbumView.swift`,
and `listWatchedChildren` in each drive service.

## Why it lists folders rather than watching for changes

Nothing cheaper says something arrived. Drive doesn't touch a folder's
`modifiedTime` when a file lands in it (it only changes on the folder's own
rename or move), and `.addit-data` changes only when somebody opens the album
in Addit — never when they add to it in Drive itself, which was the first idea
and the reason it can't work. So a check lists each tracked folder and compares
the listing with the last one.

Drive's Changes API was considered and left for later: it's account-wide, so it
would still need these snapshots to tell "new to this folder" from "changed",
and whether it reports a file a friend adds to a folder shared with you — the
case tracking exists for — is something only a live account could confirm. If
checks ever get expensive, it's the optimisation to add *in front of* the
snapshots (to pick which folders to list), not a replacement for them.

## The rules (`FolderWatchBook.record`)

- **A folder's first complete listing is its baseline.** Nothing already there
  is news. That covers the library on the first check after install, every
  album added to the library since, and every pin (`track` lists it at once).
- **`seen` only grows.** A child is new the first time its ID appears and never
  again. A share revoked and restored lists as empty in between; if the
  snapshot followed the listing, the restore would replay the folder's whole
  contents as new. A deleted child's ID stays — cheap, and the cost of that
  guarantee.
- **Listings are complete or nothing.** Every page, and a batch either returns
  every folder in it or throws. A partial listing taken as a baseline would
  report the missing part as new next time. The browse listings
  (`listSubfolders`, `listAudioFiles`) read one page; never reuse them here.
- **A batch that fails because of its folders throws `.unlistable`**, and
  `ListingQueue` splits it in half and tries the halves first, down to one
  folder, which is then given up on for that check. Anything else (offline,
  signed out, rate limited) ends the check, keeping what earlier batches
  recorded; `lastChecked` only moves when a check gets all the way through.
- **A check belongs to its account.** `isCurrent` is re-asked after every
  await: still the account on screen *and* still the one its drive client is
  signed in as (a second Google account switched to mid-check would list the
  first one's folders with its own token and see nothing). An abandoned check
  writes nothing, which loses nothing — an unadvanced snapshot reports the same
  news next time.
- **Your own additions are listed, never unread.** `byMe` events say "You added
  …" and don't light the button, so an album filled from edit mode doesn't nag —
  but testing by adding a folder from Drive on a laptop still shows something.
  Attribution is the file's owner on Drive (a shared drive's files have no owner;
  `lastModifyingUser` stands in) and `createdBy` on OneDrive: whoever *made* the
  file, not whoever moved it in. Neither API says who moved a file.
  Each event shows that person's profile picture above its text — Drive's
  `photoLink` on the owner (re-sized from its `=s64` to the drawn size);
  Graph gives none, so OneDrive events, and events saved before pictures were
  kept (`photo` decodes as nil), show initials.
- **Deleted in Drive means trashed, and a trashed folder still answers.**
  `getFileMetadata` returns it normally (it now asks for `trashed`); only its
  listing comes back empty, since its contents are trashed with it. Adding a
  new folder from an event once took that emptiness for "a folder of albums"
  and offered to track an album that had been deleted (2026-10-07). So Add
  tells apart, in order: gone (404/403, or `trashed`), every track removed
  (no subfolders either), and only then a folder of albums. A folder found gone
  shows "Deleted" instead of Add.
- **A pinned folder that's gone** (`getFileMetadata` 404/403, or `trashed`, at
  the start of a check) is marked missing, kept, and not listed, so it can't be taken as having
  emptied. Unpinning drops its snapshot (a re-pin starts fresh) unless it's also
  a library album.

## When checks run

`folderWatchChecks` on the library: as it appears and when the viewed account
changes, then on every return to the foreground — each only if none got through
in `checkInterval` (15 min) and none failed in `retryInterval` (2 min). Opening
the window checks if the last is over a minute old; pull to refresh joins or
starts one. All in-app: nothing runs while Addit is closed, and nothing posts a
system notification (Background App Refresh + local notifications would be the
way, and would need the user's permission).

## Providers

- **Google** lists `watchBatchSize` (30) folders per query:
  `('a' in parents or 'b' in parents …) and trashed = false and (folder or
  audio)`, a child attributed to every tracked parent it has. Google publishes
  no limit on query length or complexity; 30 is under the 40 other code is
  known to use, and a 400 ("too complex") comes back `.unlistable` and is
  halved. A folder this account can't see lists as empty rather than failing —
  the grow-only snapshot is what makes that harmless. Pages are decoded off the
  main actor (`decodeWatchedPage`), since a check over a big library is
  thousands of entries.
- **OneDrive** lists one folder per request — Graph has no query across parents
  (`$batch` would be the next step for big OneDrive libraries). "Me" is the
  owner of `/me/drive`, the same kind of id as an item's `createdBy`, fetched
  once per account.
- What counts as a track is `DriveItem.isPlayableAudio`, the album listing's own
  rule, so a MIDI file never shows up as news. Shortcuts aren't followed —
  neither does the add-album browser.

## The file

`Application Support/FolderWatch/<account>.json`, one per account
(`AccountManager.storageIdentifier`), deleted on sign-out with the rest of the
account. Written on the service's serial `disk` queue so a slow write can't land
after a newer one; read through it too, so switching away and straight back
waits for the last write. `FolderWatchBook` decodes by hand with defaults, so a
file written before a field existed still opens (nested types are synthesized —
give a new field on one of them a default in a hand-written `init(from:)`). An
unreadable file is set aside as `.unreadable.json`, not overwritten. Every type
in `FolderWatch.swift`, nested ones included, is `nonisolated`: the project
defaults to MainActor, and the file is encoded on `disk`.

## Verifying

`tools/foldertrack/check.sh` compiles `FolderWatch.swift` as it ships and checks
baselines, the grow-only snapshot, grouping and wording, the unread count,
pruning, the file format, and `ListingQueue` against a simulated drive that
turns batches down. Run it after touching the model; then build. Neither has
been run against a live Drive or OneDrive account — the queries and fields are
written to the documented APIs. In the app, `[Watch]` logs every check, its
duration, and each event as it's found.
