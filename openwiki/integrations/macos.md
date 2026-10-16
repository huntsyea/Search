---
type: integration
title: "macOS integration: links, default browser, AppleScript"
description: How Search plugs into macOS — the Info.plist claims that make it a browser, receiving links and files from other apps (and holding them until a window exists), becoming the default browser, the Little window for outside links, Dock behaviour, read-only AppleScript via Search.sdef, File › Share, feedback mail, and the entitlements for camera, mic, location and passkeys.
tags: [macos, integration, applescript, default-browser, links, entitlements, info-plist]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-8a2e26d4137b8250f68bb869
    resource: repo://build.sh
  - id: openwiki-source-84da53372c78a5af56690884
    resource: repo://Search.entitlements
  - id: openwiki-source-02847f451c085472cf1aac1a
    resource: repo://Search.passkeys.entitlements
  - id: openwiki-source-12d815172289a6ea31f46b05
    resource: repo://Search.sdef
  - id: openwiki-source-534ae75d10a3d699fb8d4da3
    resource: repo://Sources/Search/Links.swift
  - id: openwiki-source-740097a8e6c4855bfe17899c
    resource: repo://Sources/Search/Little.swift
  - id: openwiki-source-77755c573285ce7dcf47f502
    resource: repo://Sources/Search/Scripting.swift
  - id: openwiki-source-c733d4af2b5cbbde05609b84
    resource: repo://Sources/Search/Sharing.swift
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# macOS integration: links, default browser, AppleScript

## What the bundle claims (`build.sh`)

`build.sh` writes `Info.plist` (bundle id `com.officecommun.search`). The parts that make Search a browser to macOS:

- **`CFBundleURLTypes`**: `http` and `https` — what sends a link clicked in Mail here.
- **`CFBundleDocumentTypes`**: `public.html`, `com.apple.web-internet-location`, and `public.xhtml`. macOS lists an app under Desktop & Dock › Default web browser only if it also claims `public.xhtml`.
<!-- openwiki: broken internal link [/openwiki/ai/assistant.md] link "/openwiki/ai/assistant.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- **`NSAppTransportSecurity` / `NSAllowsArbitraryLoads`**: a browser loads http sites and localhost. (Search's own requests that carry secrets do their own host checks, e.g. the [AI client](/openwiki/ai/assistant.md).)
- **Usage descriptions** for camera, microphone, location and the Downloads folder. Pages ask, not the app, but macOS needs a sentence and crashes without one.
- **`NSAppleScriptEnabled`** + **`OSAScriptingDefinition = Search.sdef`**.

## Entitlements

| File | Used when | Contents |
|---|---|---|
| `Search.entitlements` | Default signing | `device.camera`, `device.audio-input`, `personal-information.location`: the hardened runtime refuses these otherwise |
| `Search.passkeys.entitlements` | `Search.provisionprofile` is next to `build.sh` | The above plus `com.apple.developer.web-browser.public-key-credential` (Apple grants this to browsers on request) and the application/team identifiers that tie the app to the embedded Developer ID provisioning profile |

<!-- openwiki: broken internal link [/openwiki/passwords/passkeys.md] link "/openwiki/passwords/passkeys.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
<!-- openwiki: broken internal link [/openwiki/operations/build-and-release.md] link "/openwiki/operations/build-and-release.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
A restricted entitlement without its profile produces an app that won't open, so `build.sh` uses the passkeys file only when the profile is present. See [Passkeys](/openwiki/passwords/passkeys.md) and [Build and release](/openwiki/operations/build-and-release.md).

## Receiving links and files (`Links.swift`)

`Links` is the app delegate.

- **Apple Events.** `applicationWillFinishLaunching` registers a `kAEGetURL` handler directly with `NSAppleEventManager`. Handling events there instead of through SwiftUI avoids SwiftUI re-presenting the window for each URL (five URLs at launch meant five rebuilds). Only `http(s)` URLs are accepted.
- **Files.** `application(_:open:)` accepts file URLs (an `.html` double-clicked in Finder once Search is the default browser) and http(s).
- **Test runs ignore both**, so an outside link can't bring a probe window forward; the bench injects links with `Links.arrived`.
- **Before a window exists**, URLs wait in `waiting`. A launch caused by a link is treated by SwiftUI as "opening something" and it would open no window, so `summon()` asks for the untitled window explicitly (once). `hand(to:)` runs when the first browser is ready: after the window is actually visible (`onceShown`, giving up after ~1.2 s for hidden launches), the first URL goes into the existing blank tab and the rest open behind it 0.15 s apart, waiting to load.
- **Afterwards**, each link goes to the front window (or one brought back by `Browsers.ensureWindow`), de-miniaturises it, and brings Search forward. On macOS 14+ it calls `NSApp.activate()` and, if still not active 0.25 s later (Electron apps like Notion don't hand over activation), falls back to `activate(ignoringOtherApps:)`.
- **Little window** (`Little.swift`, off by default in Settings › General, #227 — Arc's "Little Arc"): an outside link opens in a small window showing the page with a thin line naming the site and **Open in Search**. The page is its own tab; keeping it (⌘O) moves it into the front window's row after the active tab, with that window's space and sign-ins, loaded as it is. Escape/⌘W close it.

## Dock and app lifecycle

- Clicking the Dock icon with no visible window brings one back (`applicationShouldHandleReopen`).
- Closing the last window **doesn't quit** (`applicationShouldTerminateAfterLastWindowClosed` → false), as in Safari and Chrome; its session is written as it closes.
- The Dock menu has **New Window**.
<!-- openwiki: broken internal link [/openwiki/features/history-bookmarks-downloads.md] link "/openwiki/features/history-bookmarks-downloads.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- Downloads publish progress on the file, which drives Finder's progress bar and the Dock's Downloads stack, and bounce the stack on completion (see [Downloads](/openwiki/features/history-bookmarks-downloads.md)).
- Quitting cancels background file imports (waiting up to 5 s), flushes every window's session and `windows.json`, and drains pending disk writes.

## Default browser

`Links.isDefault` checks whether `NSWorkspace.urlForApplication(toOpen: https://example.com)` is this bundle. `Links.becomeDefault` calls `setDefaultApplication(at:toOpenURLsWithScheme:)` for `http` and `https`; macOS shows its own confirmation, and the result comes back on the main thread. Offered in Settings and in the Welcome screens.

## AppleScript (`Scripting.swift`, `Search.sdef`)

**Read-only**, in Safari's terms and codes (#232): `windows`, each window's `id`, `tabs` and `current tab`, each tab's `URL` and `name`, plus `count` (needed for `repeat with t in tabs`). Nothing can be changed, run in a page, opened or closed.

- Only apps allowed under System Settings › Privacy & Security › Automation get this far.
- **Private tabs are never shown**: they're left out of `tabs`, and a window whose front tab is private has no `current tab` (missing value).
- `URL` is the page actually on screen (`Tab.pageAddress`), with any `user:password@` removed; `name` is that page's title, kept until the next page commits.
- Tabs are addressed as `tab N of window id …` (`objectSpecifier`), where N counts only non-private tabs.

## Share and feedback

- **File › Share…** (`Sharing.swift`) shows `NSSharingServicePicker` for the page's URL. With no toolbar button to hang from, it anchors near the top-right of the page, where Safari keeps its Share button.
- **Feedback** (⌘⇧F, Help menu, About) opens a `mailto:` draft to `hello@officecommun.com` with the version, build and macOS version. Nothing is sent automatically.

## Related

<!-- openwiki: broken internal link [/openwiki/architecture/overview.md] link "/openwiki/architecture/overview.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Architecture overview](/openwiki/architecture/overview.md) — where `Links` sits in launch.
<!-- openwiki: broken internal link [/openwiki/page/page-tools.md] link "/openwiki/page/page-tools.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Page tools](/openwiki/page/page-tools.md) — Peek, which shares the Little window's tab model.
