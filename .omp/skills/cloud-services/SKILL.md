---
name: cloud-services
description: How Addit talks to Google Drive and OneDrive and keeps working when that goes badly — which Google sessions are accepted (the drive-scope gate and the Drive-access card), keeping the session through an offline launch, CloudSession (never reusing a dead connection), resumable Drive uploads, and background transfers (TransferService, ActivityRing, adding tracks from edit mode). READ THIS before editing GoogleAuthService, CloudAuthCoordinator, DriveAccessPrompt, the request or upload code in GoogleDriveService/OneDriveService, TransferService, or AlbumDetailView's sync.
---

# Cloud services (Addit)

Each rule here exists because of a specific failure in the field, named where
it's described. The pattern is the same throughout: the network or the
provider's SDK misbehaves quietly, and the app has to notice and say so rather
than leave a library that looks fine and does nothing.

## Which Google sessions are accepted

`GoogleAuthService.adopt(_:)` is the only way into a session, and it requires
the `drive` scope. Never assign `currentUser` directly.

Google's consent screen shows Drive as its own checkbox, unticked, and the
sign-in succeeds whether or not it gets ticked. Taking that session let people
into a library where nothing played and no cover loaded (2026-09-28, when the
move to production had everyone sign in again). So a session without Drive is
never adopted; it becomes `driveAccessRequest` (`.unticked`), and
`DriveAccessPrompt.swift` draws a card over whatever is on screen that sends
the user back to Google for that one permission (`addScopes`: same account, no
chooser).

The same card covers a registered account whose saved session is gone
(`.signedOut`): Google refusing the refresh token (`invalid_grant`: access
revoked, or one of the seven-day tokens issued while the OAuth app was in
Testing), or nothing in the keychain (a phone restored from a backup brings the
accounts list but not the keychain). **Never a network error**:
`isLostSession` is deliberately narrow, because being offline fails the same
calls. "Not now" keeps the session of an account that has a library here, so
the next launch asks again, but signs out a first sign-in abandoned half-way.

## An offline launch keeps the session

The SDK's `restorePreviousSignIn()` refreshes any token within ten minutes of
expiry, which is most launches, and offline that refresh fails the whole
restore. That signed Google users out of the albums they'd downloaded to play
offline. `restoreSavedSession()` catches the network failure and takes the
saved session unrefreshed; `validAccessToken()` refreshes it on the first
request once there's a connection, which is also where a session that turns out
to be dead raises the card. It reaches the SDK's private
`restorePreviousSignInNoRefresh` by selector, checked with `responds(to:)`:
**recheck it after any GoogleSignIn upgrade.** If it disappears the app
degrades to signing out offline, not to a crash.

## CloudSession: never reuse a dead connection

Both drive services talk through `CloudSession`, never `URLSession.shared`.
URLSession pools connections per host and keeps handing new requests to one
that has died without being torn down. From a phone's own log (2026-09-29, a
hotspot flapping between Wi-Fi and cellular): one dead QUIC connection timed
out an upload, stalled the next for two minutes, and made every album sync
after it wait out the full 60 seconds, which left the page's loaders spinning.
On a timeout or a lost connection, `CloudSession` retires the whole session and
the next request opens a fresh one. It never retries anything itself: whether a
request can be sent again is the caller's decision. It has `URLSession`'s method
names, so a service swaps the type and no call site changes.

## Drive uploads are resumable

`GoogleDriveService.createFile` uses Google's resumable protocol for every file
of every size. Don't go back to `uploadType=multipart`: it's one request, and
one dropped connection loses the whole file. The loop opens an upload session,
sends everything from a known offset in one `PUT`, and on a transient failure
(timeouts, a lost or missing connection, 5xx, 429) backs off 1, 2, 4, 8 s, asks
the session how much arrived (`Content-Range: bytes */total`, answered with 308
and a `Range` header), and sends the rest over a fresh connection. It gives up
after five tries in a row without the session confirming more bytes, and starts
over if Google forgets the session (404/410). Verified byte-identical, by size
and MD5, after killing a 24.7 MB upload part-way.

Progress comes from a per-task `URLSessionTaskDelegate`
(`createFile(…onProgress:)`). OneDrive's uploads go through `authorizedRequest`,
which has no progress hook, so they report once per file, and they don't resume.

## Background transfers

Album transfers (duplicate / save-to-device) run through `TransferService` —
serial, because two uploads to one account fight for the same rate limit.
Progress for those *and* for offline downloads
(`AudioCacheService.albumCacheProgress`) lives on the service, not the view, and
both draw through one `ActivityRing` placed in **both** the library's and an
album's toolbar. That second placement is the whole point: the work always
outlived the screen (unstructured `Task`s), but the ring used to exist only in
the album's toolbar, so leaving made a running job look stopped. Export is
deliberately still modal — it ends in a share sheet.

**Adding tracks is a job too** (`.addTracks`, `TransferService+AddTracks.swift`),
so + never becomes a spinner: the ring sits beside Save in edit mode, beside the
ellipsis after saving, and in the library once you leave. The rules:

- The job never touches page state; the page that started it may be gone. A
  finished track is posted as `.albumTrackAdded`, and whichever album page is up
  adopts it (into the edit copy mid-edit, otherwise by rebuilding the list).
- Failures wait in `transfers.failures[albumId]` and show the next time that
  album is on screen.
- `.addTracks` never drops a repeat: each pick is different files, so they queue.
- An add can land while a sync is listing the folder. `syncFromDrive` only
  removes tracks it knew *before* the listing, and reads the store, not just the
  relationship, before inserting, so no track is added twice.
  `Album.addUploadedTrack` checks for the track first for the same reason.
