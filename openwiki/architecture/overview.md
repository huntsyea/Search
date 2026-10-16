---
type: architecture
title: Architecture overview
description: How Search is assembled as one SwiftPM executable — the SwiftUI app and its single scene, one Browser per window plus AppKit-made extra windows, shared cross-window state, the SwiftUI/AppKit/WebKit split, the key monitor, and the path from typing in the field to a page on screen.
tags: [architecture, overview, swiftui, appkit, webkit, windows, entrypoint]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-16a6a536c0a5303df5e05c6c
    resource: repo://Package.swift
  - id: openwiki-source-443ae6faac7b0d18ff3addda
    resource: repo://Sources/Search/App.swift
  - id: openwiki-source-50d9705ad83befb6a5230076
    resource: repo://Sources/Search/Browser.swift
  - id: openwiki-source-be90b0ea8a44a7e5dc3a8968
    resource: repo://Sources/Search/Engine.swift
  - id: openwiki-source-534ae75d10a3d699fb8d4da3
    resource: repo://Sources/Search/Links.swift
  - id: openwiki-source-03b20340300174c564de7568
    resource: repo://Sources/Search/Windows.swift
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# Architecture overview

Search is a macOS browser built as **one SwiftPM executable target** (`Sources/Search/`, Swift 5 language mode, macOS 14+) with **no third-party dependencies**. Every file is one concern — `Vault.swift` the keychain, `Shield.swift` the ad blocker, `Session.swift` what comes back at launch — so there is no in-house framework to learn first. `Package.swift` also declares a `SearchTests` XCTest target.

## Layers

| Layer | What it is used for |
|---|---|
| **SwiftUI** | Everything drawn: tab strip/sidebar, the address field, panels, cards (`ContentView`, `TabBar`, `SideBar`, `Plate`, `SettingsPanel`, …). |
| **AppKit** | What SwiftUI can't reach: window dressing and traffic-light placement (`Lights`), dragging the window by empty strip (`DragStrip`), extra windows (`Browsers.open`), the page stages (`StageView`, `PaneStage`), menus, sheets and alerts. |
| **WebKit** | `WKWebView` (subclassed as `PageView`) per tab, content rule lists for blocking, `WKWebExtension` for Chrome extensions (macOS 15.4+). |

All UI code is main-thread; strict Swift 6 isolation is turned off on purpose (`Package.swift`).

## Entry point and windows

<!-- openwiki: broken internal link [/openwiki/interface/window-chrome.md] link "/openwiki/interface/window-chrome.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- **`SearchApp`** (`App.swift`) is the `@main` SwiftUI `App`. Its only scene is a single `Window("Search", id: Browsers.sceneID)` with a hidden title bar, rooted at `SceneRoot` → `ContentView`. It defines all menus in `.commands { … }`; each command acts on `browser`, the front window's `Browser`, and uses a `.shortcut("…")` id so user-customised keys apply (see [window chrome](/openwiki/interface/window-chrome.md)).
<!-- openwiki: broken internal link [/openwiki/integrations/macos.md] link "/openwiki/integrations/macos.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- **`Links`** (`Links.swift`) is the `NSApplicationDelegate` (via `@NSApplicationDelegateAdaptor`). It installs the crash-log exception handler, handles `kAEGetURL` Apple Events for links from other apps, sweeps leftover import scratch files, waits up to 5 s for file imports to cancel on quit, and on termination flushes all windows (`Browsers.flush()`) and pending disk writes (`Disk.drain()`). See [macOS integration](/openwiki/integrations/macos.md).
- **Multiple windows** (`Windows.swift`): the first window is SwiftUI's scene (its `Browser` held by `SceneSlot`); every other window is an AppKit `NSWindow` built by `Browsers.open` around the same `ContentView` in an `NSHostingView`. `Browsers.all` lists every window's browser, oldest first; `Front.shared` tracks the browser of the key window so menus act on it. `Browsers.becameKey` also sets the current space and tells extensions which window is focused.
- `SceneRoot` calls `Browsers.restoreOnce()` when the first window appears, reopening the other windows recorded in `windows.json`.

## Per-window vs shared state

<!-- openwiki: broken internal link [/openwiki/architecture/browser-and-tabs.md] link "/openwiki/architecture/browser-and-tabs.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
<!-- openwiki: broken internal link [/openwiki/tabs/spaces-pins-groups.md] link "/openwiki/tabs/spaces-pins-groups.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
Each window has its own **`Browser`**: its tabs, active tab, space shown, address field and panels. State every window shares lives in **`Shared`** (`Browser.swift`): `Preferences`, `Bookmarks`, `History`, `Curtain` (hidden elements), `Loot` (downloads memory), `Float` (the one floating video) and `Fetches` (downloads in progress). Spaces and pins are also global: each window shows one space at a time, and a pin is the same in every window. Details in [Browser model, tabs and web views](/openwiki/architecture/browser-and-tabs.md) and [Spaces, pins and groups](/openwiki/tabs/spaces-pins-groups.md).

<!-- openwiki: broken internal link [/openwiki/architecture/persistence.md] link "/openwiki/architecture/persistence.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
Persistence follows the same split: the oldest window's rows are in `session.json` (and per-space files), every other window is a `WindowRecord` line in `windows.json` with its frame, space and rows. See [Persistence](/openwiki/architecture/persistence.md).

## Keyboard routing

A `WKWebView` keeps first responder, so `ContentView.watchKeys()` installs an `NSEvent` local monitor for key-down, flags-changed and left-mouse-down events. Each window's monitor handles only its own window's events (`mine`); `take(event)` decides in a fixed order: questions hanging from the window, the little window and extension popups, the Shortcuts recorder, the ⌃Tab switcher, Escape, peeks, Tab (left to the page for form fields), ⌃1–9 for spaces, user-customised shortcuts, extension shortcuts, ⌘Return in the field, and ⌘1–9 matched **by key code** so they work on AZERTY and other layouts. Menu items carry the same commands as key equivalents for discoverability.

## From typing to a page

1. The field is shown over a blank tab or raised by ⌘L (`Browser.editing`). Every change to `Browser.typed` re-runs `guess()`, which fills `offers` (open tabs, history, well-known sites, address commands) and the grey inline `ending`.
<!-- openwiki: broken internal link [/openwiki/navigation/address-field.md] link "/openwiki/navigation/address-field.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
2. Return calls `Browser.submit()`: an offer that is an open tab is switched to; an address command runs; otherwise the target is the picked offer, the completed text, or `destination(for:)`, which tries in order the site-search chip, `Address.url(from:)`, a keyword shortcut (`yt cats`), then the default search engine's template (`Engine`). If nothing results, the field shakes (`refusals`). See [Address field](/openwiki/navigation/address-field.md).
<!-- openwiki: broken internal link [/openwiki/architecture/browser-and-tabs.md] link "/openwiki/architecture/browser-and-tabs.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
3. `Tab.go(to:)` builds the tab's `PageView` if needed (lazy, see [tabs](/openwiki/architecture/browser-and-tabs.md)) and loads the URL.
4. `Browser.decide` (the navigation delegate) intercepts OAuth callbacks, routes modifier clicks, arms the site's hidden-element CSS and ad-block state for the next document, and hands non-web schemes to other apps.
5. On commit the tab's `committed` address, remembered zoom and failure state update; on finish the history entry and favicon are recorded.
6. `Page` / `WebStage` (`Stage.swift`) puts the active tab's view in the one stage view (or `PaneStage` with Split View on). Switching tabs swaps views in and out without reloading.

## Cross-cutting conventions

<!-- openwiki: broken internal link [/openwiki/workflows/contributing.md] link "/openwiki/workflows/contributing.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- **Off by default.** New behaviour ships behind a Settings switch, defaulting to how the browser always behaved; `Preferences` holds the switches and What's New lists them after an update. See [Contributing](/openwiki/workflows/contributing.md).
- **Private WebKit API is probed first.** Names outside the public framework (`_setPageMuted:`, `_setDeveloperExtrasEnabled:`, inspector calls) are called only after `responds(to:)`, so a WebKit without them degrades instead of crashing.
<!-- openwiki: broken internal link [/openwiki/testing/bench-and-test-worlds.md] link "/openwiki/testing/bench-and-test-worlds.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- **Test runs never touch the real browser.** `Store.testing` / `SEARCH_PROBE` give a separate folder, defaults suite and WebKit store; `./bench` drives a running instance over a Unix socket. See [bench and test worlds](/openwiki/testing/bench-and-test-worlds.md).
- **Nothing phones home** beyond pages, favicons and the daily update check; the crash log stays in `~/Library/Application Support/Search/crash.log`.

## Where to go next

<!-- openwiki: broken internal link [/openwiki/architecture/browser-and-tabs.md] link "/openwiki/architecture/browser-and-tabs.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- Tab and page lifecycle: [Browser model, tabs and web views](/openwiki/architecture/browser-and-tabs.md)
<!-- openwiki: broken internal link [/openwiki/architecture/persistence.md] link "/openwiki/architecture/persistence.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- Files on disk: [Persistence and the Store](/openwiki/architecture/persistence.md)
<!-- openwiki: broken internal link [/openwiki/interface/window-chrome.md] link "/openwiki/interface/window-chrome.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- What the window looks like: [Window chrome](/openwiki/interface/window-chrome.md)
<!-- openwiki: broken internal link [/openwiki/integrations/macos.md] link "/openwiki/integrations/macos.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- Links, AppleScript, default browser: [macOS integration](/openwiki/integrations/macos.md)
