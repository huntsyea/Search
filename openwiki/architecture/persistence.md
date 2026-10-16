---
type: architecture
title: Persistence and the Store
description: Where Search keeps its data — the Application Support folder and its JSON files, the Disk serial writer, quarantine of unreadable files, UserDefaults settings via Preferences, session and pins files, per-space WebKit stores — and how test worlds (SEARCH_PROBE) are kept completely apart from the real browser.
tags: [persistence, storage, session, settings, test-world, userdefaults, json]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-7f5c0d0b278c8be08d70452b
    resource: repo://fresh.sh
  - id: openwiki-source-443ae6faac7b0d18ff3addda
    resource: repo://Sources/Search/App.swift
  - id: openwiki-source-3fce78f1ecf9d16c3307e665
    resource: repo://Sources/Search/Bookmarks.swift
  - id: openwiki-source-daad62809913bcef84933e7b
    resource: repo://Sources/Search/Curtain.swift
  - id: openwiki-source-3fc03362e153f232f43d994b
    resource: repo://Sources/Search/History.swift
  - id: openwiki-source-534ae75d10a3d699fb8d4da3
    resource: repo://Sources/Search/Links.swift
  - id: openwiki-source-1c5bbbfd8e732117a4da40f7
    resource: repo://Sources/Search/Loot.swift
  - id: openwiki-source-b7b01e0296b054b7f8ddcb53
    resource: repo://Sources/Search/Pins.swift
  - id: openwiki-source-fc9b78c55ddd3ec773fb0af8
    resource: repo://Sources/Search/Prefs.swift
  - id: openwiki-source-39d9cf949dfc2307cd3fe3f1
    resource: repo://Sources/Search/Session.swift
  - id: openwiki-source-6da5ddf13b785492f9d97c10
    resource: repo://Sources/Search/SiteSearch.swift
  - id: openwiki-source-d8690cd873e110911612abf9
    resource: repo://Sources/Search/Spaces.swift
  - id: openwiki-source-dc828845e05bae729f2bad99
    resource: repo://Sources/Search/Store.swift
  - id: openwiki-source-03b20340300174c564de7568
    resource: repo://Sources/Search/Windows.swift
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# Persistence and the Store

Everything Search keeps is either a small JSON file in its own folder, a `UserDefaults` key, a WebKit data store, or a keychain item. `Sources/Search/Store.swift` decides where those live; the rule it exists to enforce is that **a test run never touches the folder, settings or website data of the browser somebody is actually using** (a shared folder once cost someone their pinned tabs).

## Store: real browser vs test world

`Store.testing` is true when `SEARCH_PROBE` is set **or** the executable path contains `/.build/` (running straight out of SwiftPM's build folder). The second condition is deliberate: a development build launched from a terminal once overwrote a real session.

`Store.world` names the test world: `SEARCH_PROBE=1`, `test`, empty, or a `.build` run → `"test"`; `SEARCH_PROBE=<name>` → `<name>` (lowercased, letters/digits/hyphens only). It is `nil` for the real browser.

| | Real browser | Test world `test` | Named world `x` |
|---|---|---|---|
| Folder (`Store.folder`) | `~/Library/Application Support/Search/` | `…/Search (test)/` | `…/Search (x)/` |
| Settings (`Store.settings`) | `UserDefaults.standard` | suite `com.officecommun.search.test` | suite `com.officecommun.search.test.x` |
| Website data (`Store.websites`) | `WKWebsiteDataStore.default()` | store id `5E4C0000-0000-4000-8000-000000000001` | `5E4C<FNV-1a hash>-…-000000000001` |

WebKit keeps its default store per bundle, not per folder, so before this a test run was signed in everywhere and "sign out of everything" in a test signed out the real browser. Store kind `2` is used for extensions. A test copy built under a different bundle id (`Store.ownContainer`) has its own WebKit container and uses the default stores.

`Store.measuring` (`SEARCH_MEASURE` beside `SEARCH_PROBE`) keeps shipped behaviour (WebKit's hidden-page throttling, App Nap) so measurements reflect what people get.

<!-- openwiki: broken internal link [/openwiki/testing/bench-and-test-worlds.md] link "/openwiki/testing/bench-and-test-worlds.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
`fresh.sh` wipes a world — its folder, defaults suite and website data store (computing the same FNV-1a id as `Store.probeStore`) — and opens `build/Search.app` with `SEARCH_PROBE`, hidden if the world's bench switch is on. `./fresh.sh again` reopens without wiping. See [bench and test worlds](/openwiki/testing/bench-and-test-worlds.md).

### Migration from "Office Browser"

The app was called Office Browser until September 2026. On first run of the real browser, `~/Library/Application Support/Office Browser` is moved to `Search` if `Search` doesn't exist, and the old `com.driceroland.officebrowser` defaults are copied (once, flagged by `carried`) along with the window frame.

## Disk: one serial writer

`Disk.write(file, now:encode)` puts every save on one serial utility queue and **drops a write that a newer write of the same file has overtaken**. Before, concurrent saves could land out of order and the session written at quit could be replaced by an older one. `now: true` writes on the calling thread (used when quitting); `Disk.drain()` waits for the queue and is called from `applicationWillTerminate`. Files are written atomically.

`Store.quarantine(file)` moves a file that exists but fails to decode to `<name>.unreadable-<timestamp>.json` instead of letting the next save overwrite it.

## Files in the folder

| File | Owner | Contents |
|---|---|---|
| `session.json` | `Session` | First space's tab row of the oldest window |
| `session-<space-uuid>.json` | `Session` | Each other space's row |
| `windows.json` | `Browsers` (`Windows.swift`) | One `WindowRecord` per window: id, frame, space, rows of non-oldest windows |
| `pins.json` | `Pins` | Pin definitions by space |
| `spaces.json` | `Spaces` | The list of spaces (first is always "Personal" with `Space.firstID`) |
| `history.json` | `History` | Visit history for completion |
| `bookmarks.json` | `Bookmarks` | Bookmark tree |
| `downloads.json` | `Loot` | Memory of past downloads |
| `hidden.json` | `Curtain` | Per-site hidden-element selectors |
| `search-sites.json` | `SiteSearch` | Sites learned via OpenSearch |
| `icons/` | `Favicons` | Cached favicons as PNG |
| `Extensions/` | `Extensions` | Unpacked extensions and `installed.json` |
| `AI/` | `AIEngine` | Downloaded engine and model (add-on not shipped) |
| `bench.sock` | `Bench` | Unix socket when scripting is on |
| `crash.log` | `Links` | Uncaught exceptions, appended, never sent |

<!-- openwiki: broken internal link [/openwiki/passwords/vault-and-autofill.md] link "/openwiki/passwords/vault-and-autofill.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
Passwords are not here: they are keychain items (see [Passwords](/openwiki/passwords/vault-and-autofill.md)). Cookies and site data are in WebKit's stores.

## Settings: `Preferences`

`Preferences` (`Prefs.swift`, `Shared.prefs`) is one `ObservableObject` whose `@Published` properties each write one key to `Store.settings` in `didSet` (e.g. `sidebar`, `search.engine`, `tabs.sleep`, `spaces`, `splitView`, `links.peek`). It exists so panels can bind to settings and the window redraws when one changes. Defaults are chosen so an unconfigured browser behaves as it always did; most new features default **off**. Some settings also push a static flag the moment they load (e.g. `HoveredLink.on`, `FrameRate.fast`, `AutoScroll.on`) and some must be told to WebKit before the first web view exists (`tellWebKit(autocorrect:)` writes to `UserDefaults.standard`, which WebKit reads).

Other code reads per-site keys straight from `Store.settings`: `zoom.<host>`, `autoplay.<host>`, `capture.*` permission answers, `ai.told.<provider>`, `import.records`, `sleep.after`. Keys are stored in plain defaults, so they are not secrets.

Turning `bench` on also grants a launch-time consent mark (`Bench.Consent`); a `bench` key set without it is reset to off.

## Session restore

`Session.Shape` is `{tabs: [Entry], active, groups?, splits}`; an `Entry` is `url`, `title`, and optional `pin`, `name`, `home`, `groupID`, `pinID`, `listed`. Only addresses and names are kept — page state lives in the page, visits in history. `Session.Split` stores tab indices, axis, sizes and the focused index.

Decoding is **lenient** for the parts versions may disagree on: an undecodable `groups`, `groupID`, `pinID`, `listed`, `axis` is treated as absent rather than failing the whole file (which would quarantine it and restore no tabs). Older split records (`left`/`right`/`fraction`) still read. Groups and splits are written whether or not their feature is on, so turning a feature off loses nothing.

<!-- openwiki: broken internal link [/openwiki/architecture/browser-and-tabs.md] link "/openwiki/architecture/browser-and-tabs.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
Restored tabs get `restore(url:title:)` and load only when selected (see [tabs](/openwiki/architecture/browser-and-tabs.md)). Private and bench tabs are never written.

**Start with a fresh window** (`Preferences.freshKey`): at launch, before any window reads its row, `Session.startFresh` rewrites each space's file to its pins only with `active = -1`, and `Browsers.startFresh` trims `windows.json`.

## Pins across windows

<!-- openwiki: broken internal link [/openwiki/tabs/spaces-pins-groups.md] link "/openwiki/tabs/spaces-pins-groups.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
Pins are shared by every window, per space. `Pins` keeps `bySpace: [UUID: [PinDef]]` in `pins.json` (`id`, `letter`, `home`, `title`, `name`, `listed`). Each window holds its own `Tab` per pin; when one window changes its pins, `Pins.set` saves and posts `SearchPinsChanged` so the others reconcile. If `pins.json` doesn't exist yet, pins are migrated from the oldest window's session files, which keep writing pins so version 1.0.3 can still read them. See [Spaces, pins and groups](/openwiki/tabs/spaces-pins-groups.md).

## WebKit stores per space

`Spaces.store(for:)` returns `Store.websites` for the first space (and spaces set to share its sign-ins), otherwise a `WKWebsiteDataStore(forIdentifier: spaceID)` created once and cached; deleting a space removes its store. Private tabs use `.nonPersistent()` stores and are not in this list. `Store.keepsSignIns` toggles WebKit's tracking prevention (Safari's "Prevent cross-site tracking") on every store through the private `_setResourceLoadStatisticsEnabled:`, guarded by `responds(to:)`; private-tab stores keep it on.
