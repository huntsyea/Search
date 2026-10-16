---
type: guide
title: Quickstart
description: Start here — what Search is (a small, quiet WebKit browser for macOS in one dependency-free SwiftPM target), how to build, run and test it without touching your real browser, how the source is laid out, and a task-routing map to every page in this wiki.
tags: [quickstart, overview, onboarding, build, navigation]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-8a2e26d4137b8250f68bb869
    resource: repo://build.sh
  - id: openwiki-source-f317ee207e1653d2033c81a4
    resource: repo://CONTRIBUTING.md
  - id: openwiki-source-16a6a536c0a5303df5e05c6c
    resource: repo://Package.swift
  - id: openwiki-source-23775c3de52f3ab95a13cb8b
    resource: repo://README.md
  - id: openwiki-source-443ae6faac7b0d18ff3addda
    resource: repo://Sources/Search/App.swift
  - id: openwiki-source-dc828845e05bae729f2bad99
    resource: repo://Sources/Search/Store.swift
  - id: openwiki-source-94e7bca26bc3525581ff6cdf
    resource: repo://VERSION
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# Quickstart

**Search** is a small, fast, quiet web browser for the Mac by Office Commun: a row of tabs (across the top or down a side) and the page, with one field for addresses and searches. It runs on **WebKit** (the engine in macOS) through `WKWebView`, so the app is a few megabytes. It has a built-in ad blocker, persistent element hiding, reading mode, a floating video window, keychain passwords and passkeys, and Chrome extensions on `WKWebExtension`. There's no sync, account or telemetry. Version **1.0.5** (`VERSION`), MIT licensed.

## Build and run

Requirements: macOS 14+, Xcode 16 / Swift 6 toolchain. No package dependencies.

```bash
swift build && .build/debug/Search      # runs from SwiftPM; always a *test run* (own folder/settings/cookies)
./build.sh                             # build/Search.app, ad-hoc signed (or Developer ID if present)
./fresh.sh                             # wipe and open the "test" world as a first launch
swift test                             # XCTest suite
```

<!-- openwiki: broken internal link [/openwiki/architecture/persistence.md] link "/openwiki/architecture/persistence.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
<!-- openwiki: broken internal link [/openwiki/testing/bench-and-test-worlds.md] link "/openwiki/testing/bench-and-test-worlds.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
Anything run from `.build/` or with `SEARCH_PROBE` set is a **test run** that never touches your real browser's data: a separate folder, defaults suite, WebKit store and keychain labels. See [Persistence](/openwiki/architecture/persistence.md) and [bench and test worlds](/openwiki/testing/bench-and-test-worlds.md).

Drive a running instance from the shell with `./bench` (enable Settings › General › *Let a script drive Search*, or `defaults write com.officecommun.search.test bench -bool true` for a test world):

```bash
id=$(./bench --test open https://example.com); ./bench --test wait "$id"; ./bench --test text "$id"
```

## Layout

```
Sources/Search/     one Swift file per concern (~51k lines), single executable target
Tests/SearchTests/  XCTest; Tests/*.py probe tests; Tests/HistoryRegression/, PageFindHarness.swift
Engine/, engine.sh  on-device AI engine (llama.cpp) — add-on not shipped
Icon/, Installer/   drawn app icon, DMG background and layout
build.sh publish.sh tap.sh   build/sign/notarise, publish to site, update Homebrew tap
bench fresh.sh test-find ideas   bench CLI, test-world launcher, find harness, roadmap tool
skill/search-bench/ agent skill for driving the app
```

Key files: `App.swift` (entry, menus, key monitor), `Windows.swift` (multiple windows), `Browser.swift` (per-window state and WebKit delegates), `Tab.swift` (lazy web view), `Store.swift` (where data lives), `Prefs.swift` (settings), `Design.swift` (colours, metrics).

## Conventions to know first

<!-- openwiki: broken internal link [/openwiki/workflows/contributing.md] link "/openwiki/workflows/contributing.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- **Features ship off by default** behind a Settings switch, and What's New offers them after an update ([Contributing](/openwiki/workflows/contributing.md)).
<!-- openwiki: broken internal link [/openwiki/architecture/browser-and-tabs.md] link "/openwiki/architecture/browser-and-tabs.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- **Search's own page scripts run in a private content world** (`Web.world`), invisible to pages ([tabs](/openwiki/architecture/browser-and-tabs.md)).
- **Private WebKit API is probed with `responds(to:)`** before use, so it degrades instead of crashing.
- **Nothing phones home** except pages, favicons and the hourly signed update check.
- Comments explain *why*, often citing an issue number, a measurement or a date.
- The **AI add-on** is in the code but disabled by `AI.shipped = false`.

## Where to look

| If you want to… | Read |
|---|---|
<!-- openwiki: broken internal link [/openwiki/architecture/overview.md] link "/openwiki/architecture/overview.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Understand how the app is assembled | [Architecture overview](/openwiki/architecture/overview.md) |
<!-- openwiki: broken internal link [/openwiki/architecture/browser-and-tabs.md] link "/openwiki/architecture/browser-and-tabs.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Change tab/page lifecycle, navigation policy, sleeping, crashes | [Browser model, tabs and web views](/openwiki/architecture/browser-and-tabs.md) |
<!-- openwiki: broken internal link [/openwiki/architecture/persistence.md] link "/openwiki/architecture/persistence.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Know where something is stored, or add a setting | [Persistence and the Store](/openwiki/architecture/persistence.md) |
<!-- openwiki: broken internal link [/openwiki/interface/window-chrome.md] link "/openwiki/interface/window-chrome.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Change the tab strip, sidebar, colours, panels, Settings, shortcuts | [Window chrome, design system and panels](/openwiki/interface/window-chrome.md) |
<!-- openwiki: broken internal link [/openwiki/tabs/spaces-pins-groups.md] link "/openwiki/tabs/spaces-pins-groups.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Work on Spaces, pins, tab groups, ⌃Tab | [Spaces, pins, tab groups and the tab switcher](/openwiki/tabs/spaces-pins-groups.md) |
<!-- openwiki: broken internal link [/openwiki/tabs/split-view.md] link "/openwiki/tabs/split-view.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Work on two pages side by side | [Split View](/openwiki/tabs/split-view.md) |
<!-- openwiki: broken internal link [/openwiki/navigation/address-field.md] link "/openwiki/navigation/address-field.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Change the address field, completion, search engines, site search | [Address field, suggestions and search](/openwiki/navigation/address-field.md) |
<!-- openwiki: broken internal link [/openwiki/features/history-bookmarks-downloads.md] link "/openwiki/features/history-bookmarks-downloads.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Touch history, bookmarks, downloads, favicons | [History, bookmarks and downloads](/openwiki/features/history-bookmarks-downloads.md) |
<!-- openwiki: broken internal link [/openwiki/privacy/blocking-and-hiding.md] link "/openwiki/privacy/blocking-and-hiding.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Change the ad blocker or element hiding | [Ad blocking and hidden elements](/openwiki/privacy/blocking-and-hiding.md) |
<!-- openwiki: broken internal link [/openwiki/passwords/vault-and-autofill.md] link "/openwiki/passwords/vault-and-autofill.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Work on saved passwords and autofill | [Passwords: keychain vault and sign-in autofill](/openwiki/passwords/vault-and-autofill.md) |
<!-- openwiki: broken internal link [/openwiki/passwords/passkeys.md] link "/openwiki/passwords/passkeys.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Work on passkeys / WebAuthn | [Passkeys and security keys](/openwiki/passwords/passkeys.md) |
<!-- openwiki: broken internal link [/openwiki/import/browser-import.md] link "/openwiki/import/browser-import.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Import from Chrome, Arc, Firefox, Safari files | [Importing from other browsers](/openwiki/import/browser-import.md) |
<!-- openwiki: broken internal link [/openwiki/extensions/architecture.md] link "/openwiki/extensions/architecture.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Understand Chrome extension support | [Chrome extensions on WKWebExtension](/openwiki/extensions/architecture.md) |
<!-- openwiki: broken internal link [/openwiki/extensions/installation.md] link "/openwiki/extensions/installation.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Install/update extensions, CRX verification | [Installing extensions](/openwiki/extensions/installation.md) |
<!-- openwiki: broken internal link [/openwiki/extensions/chrome-api-shims.md] link "/openwiki/extensions/chrome-api-shims.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Add or fix a missing Chrome API | [Chrome API shims](/openwiki/extensions/chrome-api-shims.md) |
<!-- openwiki: broken internal link [/openwiki/extensions/native-bridges-and-capture.md] link "/openwiki/extensions/native-bridges-and-capture.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Native messaging, sockets, offscreen docs, screen recording | [Extension native bridges](/openwiki/extensions/native-bridges-and-capture.md) |
<!-- openwiki: broken internal link [/openwiki/page/media.md] link "/openwiki/page/media.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Floating video, live streams, 120 Hz, sound | [Video and audio](/openwiki/page/media.md) |
<!-- openwiki: broken internal link [/openwiki/page/permissions-and-dialogs.md] link "/openwiki/page/permissions-and-dialogs.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Page dialogs, camera/mic/location, notifications, pop-ups | [Page dialogs, permissions and notifications](/openwiki/page/permissions-and-dialogs.md) |
<!-- openwiki: broken internal link [/openwiki/page/page-tools.md] link "/openwiki/page/page-tools.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Reader, Find, Peek, swipe, inspector, image menu | [Page tools](/openwiki/page/page-tools.md) |
<!-- openwiki: broken internal link [/openwiki/ai/assistant.md] link "/openwiki/ai/assistant.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| The (unshipped) AI summarize/ask feature | [AI add-on](/openwiki/ai/assistant.md) |
<!-- openwiki: broken internal link [/openwiki/integrations/macos.md] link "/openwiki/integrations/macos.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Links from other apps, default browser, AppleScript, entitlements | [macOS integration](/openwiki/integrations/macos.md) |
<!-- openwiki: broken internal link [/openwiki/operations/build-and-release.md] link "/openwiki/operations/build-and-release.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Build, sign, notarise, publish, Homebrew, CI | [Build, sign and release](/openwiki/operations/build-and-release.md) |
<!-- openwiki: broken internal link [/openwiki/operations/self-update.md] link "/openwiki/operations/self-update.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| How the app updates itself securely | [Self-update](/openwiki/operations/self-update.md) |
<!-- openwiki: broken internal link [/openwiki/testing/bench-and-test-worlds.md] link "/openwiki/testing/bench-and-test-worlds.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Drive the app from scripts; test worlds | [Driving Search with ./bench and test worlds](/openwiki/testing/bench-and-test-worlds.md) |
<!-- openwiki: broken internal link [/openwiki/testing/test-suites.md] link "/openwiki/testing/test-suites.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Run or add tests | [Test suites](/openwiki/testing/test-suites.md) |
<!-- openwiki: broken internal link [/openwiki/workflows/contributing.md] link "/openwiki/workflows/contributing.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Contribute, changelog, roadmap, security reports | [Contributing conventions and roadmap workflow](/openwiki/workflows/contributing.md) |
