---
type: architecture
title: Browser model, tabs and web views
description: How a window's Browser object owns its tabs and acts as WebKit's navigation, UI and download delegate, and how each Tab lazily builds its WKWebView (PageView) with Search's own content world, relays, sleep/wake, crash recovery, mute and autoplay.
tags: [architecture, browser, tab, webkit, wkwebview, lifecycle, navigation, memory]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-50d9705ad83befb6a5230076
    resource: repo://Sources/Search/Browser.swift
  - id: openwiki-source-eb0cee777122274fb19fa231
    resource: repo://Sources/Search/Dialogs.swift
  - id: openwiki-source-e329201dd1541697e6c26a79
    resource: repo://Sources/Search/Sleep.swift
  - id: openwiki-source-0d28be6631230e6b9c6c913e
    resource: repo://Sources/Search/Stage.swift
  - id: openwiki-source-6e6b2e557229ef129b26e320
    resource: repo://Sources/Search/Tab.swift
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# Browser model, tabs and web views

Two classes hold almost all runtime state for pages:

- **`Browser`** (`Sources/Search/Browser.swift`, ~5,000 lines) — one per window. It owns the window's row of tabs, which tab is active, the address field, the panels drawn over the page, and it is the `WKNavigationDelegate`, `WKUIDelegate` and `WKDownloadDelegate` for every page in that window. Much of its behaviour is split across other files as `extension Browser` (Sleep, Spaces, Dialogs, Peek, Fold, Sharing, Inspector, ImageMenu, AIAssist…).
- **`Tab`** (`Sources/Search/Tab.swift`) — one per page. It owns a `WKWebViewConfiguration`, builds its `PageView` (a `WKWebView` subclass) the first time it is asked, and publishes the page's title, address, progress, loading state and so on for SwiftUI.

<!-- openwiki: broken internal link [/openwiki/architecture/overview.md] link "/openwiki/architecture/overview.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
What every window shares is in the `Shared` enum at the top of `Browser.swift`: `Preferences`, `Bookmarks`, `History`, `Curtain` (hidden elements), `Loot` (downloads memory), `Float` (the one floating video) and `Fetches` (downloads under way). See [Architecture overview](/openwiki/architecture/overview.md) for windows and scenes.

## The tab row

`Browser.tabs` is the row in display order. Its `didSet` calls `arrangeGroupedTabs()`, so with tab groups on, any insertion (a link, a peek kept, Move to Space…) is put back into group order immediately. ⌘1–9, ⌃Tab and the extension tab indexes all read this array, so the row and what is drawn never disagree.

Related state on `Browser`:

| Property | Meaning |
|---|---|
| `activeID` | The selected tab. Its `didSet` presents dialogs that were held while the tab was in the background, resets find, marks the tab left as `touch()`ed (the sleep clock), updates split focus, and feeds the ⌃Tab switcher's most-recently-used order. |
<!-- openwiki: broken internal link [/openwiki/tabs/split-view.md] link "/openwiki/tabs/split-view.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| `splits` | Split View pairs (`TabSplit`); `displayedTabs` hides a pair's second tab, `visibleTabIDs` is the one or two tabs on screen. See [Split View](/openwiki/tabs/split-view.md). |
<!-- openwiki: broken internal link [/openwiki/tabs/spaces-pins-groups.md] link "/openwiki/tabs/spaces-pins-groups.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| `tabGroups` | Named groups in the current space. See [Spaces, pins and groups](/openwiki/tabs/spaces-pins-groups.md). |
| `parkedTabs` | Rows of other spaces, kept alive while not on screen. |

**Selecting** (`select(_:)`) closes a peek or AI panel, lands a floating video that belongs to the tab, sets `activeID`, then either `wake()`s a tab that has no page yet or `revive()`s one whose process may have died, and writes the session.

**Closing** (`close(_:)`): a **pinned** tab is never removed by ⌘W — it is put down with `tab.rest()` (view torn down, address kept) and selection moves to the most recently used non-pinned tab. Closing the last ordinary tab replaces it with a fresh blank tab; closing that blank tab closes the window. Closed tabs are remembered for ⇧⌘T (`remember`, `reopen`). `closeFront()` closes, in order, a peek, then a panel (Settings, History, …), then the tab — Escape uses the same order.

<!-- openwiki: broken internal link [/openwiki/testing/bench-and-test-worlds.md] link "/openwiki/testing/bench-and-test-worlds.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
`open(_:foreground:…)` is the common entry for new tabs; `benchOpen` makes a bench tab (see [bench](/openwiki/testing/bench-and-test-worlds.md)).

## Tab: a lazily built web view

`Tab.web` builds the `PageView` on first access; `Tab.built` returns it only if it already exists, for callers that must not be the reason a page is built. A session of twenty restored tabs is twenty `Tab` objects and no web processes. A restored tab has `pending` set (`restore(url:title:)`) and loads only when selected (`wake()`).

### Configuration (`Web.configuration`)

Built per tab (often long before its view):

- **Website data store**: the persistent store for the tab's space (`Spaces.store(for:)`), or a `.nonPersistent()` store for a **private ("shy") tab**, which keeps no cookies, history or session entry. A link opened from a private page inherits that page's store.
- **One shared `WKProcessPool`** (`Web.pool`). Deprecated in name, but without it each view got its own pool and new tabs took 41–59 ms instead of 9–10 ms to start loading.
- **Extensions controller** attached for ordinary tabs (macOS 15.4+), and for private tabs only when Settings › Extensions allows it — it can't be added after the view is made.
- **User agent**: `Version/<installed Safari version> Safari/605.1.15`, read from the installed Safari bundle so Google and others serve their modern pages.
- Element fullscreen on, AirPlay on, **`javaScriptCanOpenWindowsAutomatically = false`** (pop-ups need a click), and `mediaTypesRequiringUserActionForPlayback` = audio, or all media when Settings › General › Videos wait for a click is on.
- Developer extras on via a private selector (`Web.inspector`), guarded by `responds(to:)`.

### Search's own content world

`Web.world` is `WKContentWorld.world(name: "Search")`. Search's scripts and message handlers run there, beside the page, so the page sees no `window.webkit` and none of Search's variables. Before 24 Sep 2026 they ran in the page world, and Google treated the browser as an embedded web view (CAPTCHAs, refused sign-ins). Only the passkey patch stands in the page's own world.

### Building the view (`Tab.build()`)

<!-- openwiki: broken internal link [/openwiki/page/page-tools.md] link "/openwiki/page/page-tools.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
`build()` applies the frame-rate setting, enables pinch magnification, disables WebKit's own back/forward swipe (Search draws its own, see [page tools](/openwiki/page/page-tools.md)), holds the view hidden until its first frame, sets the delegates, and registers the relays in `Web.world`: `ScrollRelay`, `VeilRelay`, `ImageRelay`, `StoreRelay`, `IconRelay`, `FormRelay`, `PasskeyRelay`, `MiddleRelay`, plus `HoveredLink` in `.defaultClient`. `Shield.shared.protect` adds the ad-block rule list. KVO observers mirror `title`, `url`, `estimatedProgress`, `isLoading`, `canGoBack/Forward` into published properties.

Invariants worth knowing:

- **Every handler name is removed before it is added** (`Web.release`), in both Search's world and the page world, because registering a name twice crashes.
- A tab opened by a page (`createWebViewWith`) gets a **new `WKUserContentController`**: sharing the opener's let the child claim, and on close remove, the opener's handlers.
- `about:blank` never overwrites `Tab.address` — it is how a pinned tab is put down, and losing the address used to drop the pin from the session.
- `address` moves as soon as a load starts; `committed` changes only when the new document commits. Connection info and which passwords to offer use `pageAddress` (`committed ?? address`).

## Navigation policy (`Browser.decide`)

Every navigation goes through `webView(_:decidePolicyFor:preferences:…)` → `decide`. In order:

1. `shouldPerformDownload` → `.download`.
2. Extension OAuth callbacks (`ExtensionAuth`) and the AI OpenRouter callback (`AISignIn`) are taken and **cancelled, never loaded**.
3. `0.0.0.0` dev-server addresses are rewritten to localhost (`Address.reachable`).
4. Website → extension page returns are routed by `ExtensionReturnNavigation` / `ExtensionRedirectPolicy`; an extension page navigating its own tab to the web gets its tab replaced (`replace(_:going:)`), because extension views and web views can't host each other's pages.
5. Middle-button link actions are cancelled (`MiddleRelay` already opened them); shift-click opens a **Peek** when enabled; ⌘-click opens a background tab, ⌘⇧-click a foreground one.
6. For main-frame loads, the next document is armed with the site's hidden-element stylesheet (`tab.arm(hiding:)`) and the ad blocker is tuned on/off for the destination host.
7. Schemes `http https file about data blob chrome-extension webkit-extension` are allowed; anything else is cancelled and handed off (`handOff`): `mailto:`/`tel:` from a click open directly, other apps are asked about with a sheet over the tab — but only for a main-frame target, a click, or a frame of the same registrable site.

When allowed in the main frame, `Autoplay.apply` sets the per-site autoplay policy on the page's preferences.

<!-- openwiki: broken internal link [/openwiki/features/history-bookmarks-downloads.md] link "/openwiki/features/history-bookmarks-downloads.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
**Responses** (`decidePolicyFor response`): 3xx is always allowed (some servers label redirects as binary), `Content-Disposition: attachment` becomes a download, otherwise anything WebKit can't show becomes a download. See [History, bookmarks and downloads](/openwiki/features/history-bookmarks-downloads.md).

**After loads**: `didCommit` resets failure/typing, applies the site's remembered zoom, and removes the sleep picture shortly after. `didFinish` shows the first frame, settles a pending sign-in (save-password offer), fetches the favicon, and — for non-private, non-bench tabs — records history and, if enabled, learns the site's OpenSearch description.

**Failures** (`fail`): `NSURLErrorCancelled` and WebKit's 102 "frame load interrupted" (a page that became a download) are ignored; other errors set `tab.failure` to a short sentence ("No site at that address.", "No connection.", "The connection isn't secure."…) shown in place of the page by `Trouble` in `Stage.swift`.

`webViewDidClose` (a page calling `window.close()`, e.g. an OAuth pop-up) returns to the opener tab and closes the pop-up tab.

## Sleeping tabs (`Sleep.swift`)

A tab not looked at for **30 minutes** (`sleep.after` setting overrides, for bench/measurements) gives back its web view: `Tab.sleep(picture:)` keeps the back-forward state ("interaction state") and a compressed JPEG snapshot, then tears down the view. On wake the picture covers the stage while the page rebuilds at the same history entry and scroll position.

A timer runs every `min(60, max(5, sleepAfter/4))` seconds; a memory-pressure source shrinks the threshold to 5 minutes on warning and 0 on critical. Only active when Settings has `sleepsTabs` on.

`awake(because:)` lists why a tab stays awake: on screen, pinned, bench, blank, already asleep, no page, still loading, playing sound, its video floating, camera/mic in use, extension screen recording, downloading, a held dialog, or being the opener of the tab on screen (an OAuth window hands its answer back to it). `sleep(_:)` re-checks after each async step (`unsaved` form check → snapshot → sleep), and a tab holding unsent typed text never sleeps.

Pinned tabs are not slept by the timer; ⌘W puts them down (`rest()`), which tears the view down completely. Loading `about:blank` instead left the old document alive in the back-forward cache, and sites like x.com then stalled the next load.

## Crash and dead-page recovery

- `webViewWebContentProcessDidTerminate` (in `Dialogs.swift`) recovers the active tab at once and marks a background tab `stale`; `revive()` on selection calls `recoverFromCrash()`, which reloads from the address rather than relying on `reload()` (which needs state the dead process held), and tries twice.
- `revive()` also probes `document.readyState`; a `webContentProcessTerminated` error triggers recovery. A "hollow" view (address but no document) is reopened at its address.
- `loadAndVerify` waits (up to about a second) for the stage to take the view back before loading, so pages like x.com that wait to be visible don't boot hidden, and re-issues a load that silently didn't take.

## The stage

`Page` (in `Stage.swift`) observes the `Tab` directly — the window passes a class reference, so SwiftUI wouldn't otherwise redraw when it goes from blank to loaded. `WebStage`/`StageView` is "the one place a page is allowed to be": it holds one weak `wanted` view and re-asserts it on every layout, rather than reconciling "wanted" and "held" (which caused recurring white pages). It also restores the docked Web Inspector for a page coming back and stops unused keys from beeping. Split View replaces it with `PaneStage`.

## Audio, mute and autoplay

- `AudioWatch` sets `Tab.noisy`, which drives the speaker in the row.
- `Muter.set` toggles the low bit of WebKit's private `_mediaMutedState` via `_setPageMuted:`, muting page sound without pausing and leaving camera/mic bits alone. A sleeping tab is muted without waking and re-muted when rebuilt.
- `Autoplay` stores per-host `autoplay.<host>` (never from private tabs) and applies the private `_setAutoplayPolicy:` = 1 (allow) unless Videos wait for a click is on.

<!-- openwiki: broken internal link [/openwiki/page/media.md] link "/openwiki/page/media.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
All private selectors are checked with `responds(to:)` first, so a WebKit without them degrades rather than crashing. More in [Video and audio](/openwiki/page/media.md).

## Zoom

Page zoom (⌘+/⌘−) lays the page out again (`pageZoom`), clamped between 0.4× and 3×; pinch is WebKit's magnification. Zoom is remembered per host as `zoom.<host>` (never for private tabs); a site at the default zoom (Settings › General › Page zoom) stores nothing.
