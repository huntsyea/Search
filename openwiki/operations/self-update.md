---
type: subsystem
title: Self-update
description: How Search updates itself without a framework or daemon — the per-architecture signed appcast, hourly checks, the stages from found to ready, ZIP hash and Developer ID verification of the new bundle, the two-rename swap beside the running app, the DMG fallback, relaunch, what it never touches, and the tests.
tags: [updater, security, code-signing, appcast, release]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-155f858ec9b80172d6bbb9eb
    resource: repo://Sources/Search/Updater.swift
  - id: openwiki-source-3eb60176080332a8d148f21e
    resource: repo://Tests/SearchTests/VaultAndUpdaterTests.swift
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# Self-update

`Sources/Search/Updater.swift`. There's no update framework or background daemon: one small signed JSON file is read at launch, every hour, and on demand. If it names a newer build, the ZIP is fetched, checked, and **swapped into the app's place for the next launch**. Nothing relaunches on its own.

**What it never touches**: `~/Library/Application Support/Search`, the defaults, and the keychain. Only the bundle changes. It keeps its bundle id and signing identity, so keychain items made by the old build open for the new one. The only things it ever deletes are its own scratch folder and the `.old` bundle it set aside.

## The feed

- `Updater.feed` is `https://officecommun.com/search/appcast.json`, or `…/search/intel/appcast.json` on an Intel build (`#if arch(x86_64)`), so neither kind of Mac is offered the other's build.
- `SEARCH_FEED` overrides it **only in a test run** (`Store.testing`), and that's the only case where plain http is accepted.
- `fetch()` downloads **`appcast.json.zip`** (≤ 1 MB, 12 s timeout), never the plain JSON (that's for pre-1.0.4 builds). `opened(_:)` unzips it with `ditto`, requires `appcast.json` to be a regular file (not a symlink, ≤ 1 MB), and validates its **code signature** (kept in extended attributes) against the Developer ID requirement for team `7BYKA895MC` and identifier `com.officecommun.search.appcast`. A feed made up by a server or a hijacked DNS answer is "no feed at all". The key that signs the app signs the feed, so there is no separate key.
<!-- openwiki: broken internal link [/openwiki/ai/assistant.md] link "/openwiki/ai/assistant.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- Fields: `version`, `build`, `url` (ZIP), `dmg`, `sha256`, `dmgSha256`, `notes`, `minimumSystemVersion`, optional `ai.engine` (see [AI add-on](/openwiki/ai/assistant.md)). `link(_:)` accepts URLs only if https (or http with a test feed) **and on the feed's own host**, so even a valid feed can't send the "is out" line to another site.
- A release whose `minimumSystemVersion` is above this macOS is not offered (`runsHere`); unreadable parts count as 0.

<!-- openwiki: broken internal link [/openwiki/operations/build-and-release.md] link "/openwiki/operations/build-and-release.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
`build.sh` produces both files, and `publish.sh` refuses to publish a signed feed that doesn't verify (see [Build and release](/openwiki/operations/build-and-release.md)).

## Schedule and stages

`checkIfDue(then:)` (called at launch with a function to show messages in the window's status line) sweeps any leftover `.old`, starts an hourly timer (5 min tolerance), and checks immediately. Hourly ticks check only if more than 50 minutes have passed since `update.checked` (test feeds always check). **Search › Check for Updates…** (`checkByHand`) reports "up to date", "downloading", or "ready".

A found release is newer only if its `build` (a timestamp from `build.sh`) is greater than this bundle's `CFBundleVersion`.

```
none ──found──▶ fetching ──swap ok──▶ ready      ("ready — it's there the next time you open it")
  │                └────swap failed──▶ offered   ("choose Download Update")
  └─(Install updates off)──▶ waiting ──Install Update──▶ fetching
```

- **Settings › About › Install updates on its own** (`update.install`, on by default). Off, a found release becomes `waiting`, and **Install Update** appears in the Search menu.
- Once `fetching` or `ready`, no second swap happens in the same run, since it would pull the bundle out from under the running process.
- `ready` survives later checks whatever the feed says.

## Installing (`Swap.install`, off the main thread)

1. **The running app must be Developer ID signed** (it must have a Team ID). An ad-hoc build is never updated, since nothing could be told apart from it.
2. The app's folder must be writable (not someone else's `/Applications`, not a disk image), otherwise → `offered`.
3. A scratch folder on the **same volume** (`itemReplacementDirectory`), removed whatever happens.
4. Download the ZIP; **its SHA-256 must equal the feed's** (a missing hash is refused like a wrong one).
5. Extract with `ditto -x -k`. The app declares no `LSFileQuarantineEnabled`, so nothing it downloads is quarantined; the checking is done here, not by Gatekeeper later.
6. `verify`: the new bundle's `CFBundleIdentifier` equals this one's, its `CFBundleVersion` is greater, and its signature passes a **strict check for all architectures and nested code** against the Developer ID requirement (Apple anchor, Developer ID intermediate `1.2.840.113635.100.6.2.6`, Developer ID Application leaf `…6.1.13`, team OU, this bundle id), and the Team ID matches the running app's. A Team ID read from a certificate alone isn't trusted, because anyone can make a certificate that says it.
7. `swap`: two renames — current bundle → `Search.app.old`, new bundle → `Search.app`; if the second fails, the first is undone. The running process keeps running from `.old` (the kernel follows the rename) and still validates as itself for the keychain. `sweep()` removes `.old` at quit and at the next launch, and only if it really is this app.

## Fallback: the disk image

If the swap can't happen (`offered`), **Download Update** (`openDisk`) fetches the DMG **inside Search**, never through a web page. It requires the DMG's SHA-256 to equal the signed feed's `dmgSha256` and its signature to meet the team's Developer ID requirement, then opens it. Otherwise the user is told to get Search from the website.

## Relaunch

`relaunch()` starts `/bin/sh` that waits for this PID to exit, then `exec /usr/bin/open <bundle>` (passing `SEARCH_PROBE`/`SEARCH_FEED` through for test runs, since `open` starts with a fresh environment), and quits via `NSApp.terminate` so everything written at quit is written.

## Shared verification

`Updater.developerID(team:identifier:)` is reused by the AI engine check (`AIEngine.trusted`), so the engine is held to the same standard as a release.

## Tests

`Tests/SearchTests/VaultAndUpdaterTests.swift` covers the updater's pure parts: releases without a minimum run here; a release needing a newer Mac isn't offered; one needing an older Mac is; an unreadable minimum counts as zero; garbage isn't a feed; and **an unsigned feed inside a valid ZIP is refused**. A bench `update` command exercises the flow against a test feed (`SEARCH_FEED`) in a test world.
