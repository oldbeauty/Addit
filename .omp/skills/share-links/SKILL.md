---
name: share-links
description: How Addit's album and song share links work end to end — the https://hollowpoint.tv/a/<g|m>/<folderId> format, the AASA/entitlements handshake with the hollowpoint.tv site, link parking through sign-in, AlbumImporter, and the link-preview rules (og: tags, music:musician, LPLinkMetadata). READ THIS before changing AlbumShareLink, ShareLinkService, AlbumLinkShareItem, .onOpenURL, the AASA, or the site's /a/ pages and /cover.
---

# Share links (Addit)

A share link is one https URL that has to work three ways: open the app
(universal link), survive a sign-in in between, and render a good preview card
in Messages and elsewhere.

## The handshake with the site

`Addit.entitlements` (`applinks:hollowpoint.tv`) and
`~/HollowpointTv/.well-known/apple-app-site-association`
(`WU764N7X65.tv.hollowpoint.addit`) must agree — neither half does anything
alone, and a mismatch fails silently by opening Safari. The AASA has **no file
extension**, so `deploy.sh`'s rsync allow-list needs its explicit `--include`.
iOS fetches it at *install*, so publish the site before shipping a build. The
`addit://` scheme in `Info.plist` is a Simulator testing shim only — Messages
doesn't linkify custom schemes, which is the whole reason the shipping format is
`https`.

## Format, routing and previews

`AlbumShareLink` owns the URL format
(`https://hollowpoint.tv/a/<g|m>/<folderId>?n=`); those provider codes are a
published format and must not follow enum renames. `.onOpenURL` in `AdditApp`
branches share link vs Google OAuth callback — order matters, GIDSignIn swallows
what it's handed. A link parks in `ShareLinkService` until `ContentView` has an
account and a store to drain it into, which is what makes tap-link → sign-in →
album work. Both the picker and links import through `AlbumImporter`; keep it
that way or the two drift. A `?t=` on the same URL makes it a *song* link — the
album still travels, since a track is only reachable through its folder, and `t`
just says where to start.

The preview card is built twice on purpose: `AlbumLinkShareItem`
(`LPLinkMetadata`) uses the cover already in memory for the share sheet, and the
site's `og:` tags + `/cover/<id>` carry the card.

Two non-obvious rules, both established by rendering real `LPLinkView`s: the
artist line comes from **`music:musician`**, which Apple *fetches* and whose
page `<title>` it shows — `og:description`, `og:site_name` and
`music:musician_description` are all ignored — and it only does this when
**`og:type` is `music.song`**. **Only song links take that card.** Albums used
to claim `music.song` for the same second line, but iMessage reads the type
literally and presented the album as a track, so an album page is `music.album`
and gets the plain title+domain card, with its whole billing in `og:title`:
`<name> - Album by <artist>`. Don't "fix" the duplication by putting the artist
back in an album's `og:description` — it is ignored here and only doubles up on
Slack.

`LPLinkMetadata` has no subtitle field, so a hand-built one can carry neither
the artist nor the resolved title; `AlbumLinkShareItem` therefore *fetches* the
page's metadata for both kinds of link and swaps only `imageProvider` for the
on-device cover. That is what gets both — the line Apple resolved, and art the
unauthenticated fetcher could never see inside a restricted folder (or on
OneDrive at all). The `?c=` Drive id and `/cover` only serve `og:image`, i.e.
links someone *pastes* elsewhere; `/cover` sits outside the AASA's `/a/*` claim
deliberately.
