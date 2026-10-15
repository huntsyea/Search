---
type: subsystem
title: Chrome extensions on WKWebExtension
description: How Search runs Chrome extensions on Apple's WKWebExtension (macOS 15.4+) — the Extensions controller and installed.json, staggered loading and stale-worker clearing, ExtensionTab/ExtensionWindow adapters, permission policy (granted at install, never extension pages or files), the puzzle-button slot and Search-owned popups, popup windows, and daily store updates.
tags: [extensions, webkit, wkwebextension, chrome, permissions, popup, security]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-20366afd416d2f9db3617d79
    resource: repo://Sources/Search/ExtensionPopup.swift
  - id: openwiki-source-d712b4ebc436418885b2aa56
    resource: repo://Sources/Search/Extensions.swift
  - id: openwiki-source-6e6b2e557229ef129b26e320
    resource: repo://Sources/Search/Tab.swift
  - id: openwiki-source-57b978cfff7c4ea9a27612ea
    resource: repo://Tests/SearchTests/ExtensionPopupWindowTests.swift
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# Chrome extensions on WKWebExtension

Search runs Chrome extensions on **`WKWebExtension`**, the engine Safari uses, reading the same `manifest.json`. It requires **macOS 15.4 or later**; every type here is `@available(macOS 15.4, *)`, and on older systems Settings › Extensions just says so (`ExtensionsUI.swift`).

`Sources/Search/Extensions.swift` is the browser's half of WebKit's contract: which tabs and windows exist, what opening a tab or window means, who is asked for a permission and how. The rest is split out:

<!-- openwiki: broken internal link [/openwiki/extensions/installation.md] link "/openwiki/extensions/installation.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Installation](/openwiki/extensions/installation.md) — Chrome Web Store CRX fetch/verification (`Crx`), "Add to Search" (`StoreRelay`), unpacked folders.
<!-- openwiki: broken internal link [/openwiki/extensions/chrome-api-shims.md] link "/openwiki/extensions/chrome-api-shims.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Chrome API shims](/openwiki/extensions/chrome-api-shims.md) — APIs WebKit lacks, answered natively (`ExtensionShims`).
<!-- openwiki: broken internal link [/openwiki/extensions/native-bridges-and-capture.md] link "/openwiki/extensions/native-bridges-and-capture.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Native bridges and capture](/openwiki/extensions/native-bridges-and-capture.md) — native messaging, WebSockets, offscreen documents, screen recording, externally connectable pages.

## The controller

`Extensions.shared` owns one `WKWebExtensionController`:

- Its configuration is `.default()` for the real browser and `.init(identifier: Store.probeStore(2))` in a test run (so a test's extension storage is separate). Extension pages use `Store.websites` as their data store.
- Extension views get **the same user agent as web tabs** (`Web.userAgentName`). WebKit gives workers the last page's UA and, if it differs, restarts running workers — and never restarts extension workers. Extensions are told they run in Chrome by the shim instead.
- The `chrome-extension` scheme is registered as a custom match-pattern scheme, and each context's `baseURL` is fixed to `chrome-extension://<id>/`, the address the extension has in Chrome. That keeps `localStorage`/IndexedDB under a stable origin across launches, and lets servers that check the extension origin (Raindrop) accept it. Addresses saved under the older `webkit-extension://` are mapped to the new scheme (`Extensions.current`).
- **Every tab's configuration gets the controller at creation** (`Extensions.attach(config)` from `Web.configuration`); it can't be added later. Private tabs get it only if Settings › Extensions allows extensions in private tabs, and only tabs created after that switch.

### Installed list

`Installed` records live in `<Store.folder>/Extensions/installed.json`, with unpacked extensions in `Extensions/<id>/`. Each record has `id` (Chrome Web Store id, or the id Chrome would compute for an unpacked folder), `name`, `version`, `enabled`, `fromStore`, `permissions` (what was granted at install, compared on update), `pinned`, and `source` (an unpacked extension's folder, for Reload).

### Loading

`start(for:)` runs once the first window is shown (immediately if launched hidden), so loading — tens of ms per extension on the main thread — doesn't delay the first frame. It:

1. Clears **all** service-worker registrations if the shim version or any installed id/version changed since last launch (`forgetWorkersIfChanged`). WebKit otherwise restarts a cached copy of an old worker that may be permanently dead, and has no per-extension clearing.
2. Loads enabled extensions **one at a time, 400 ms apart** for those with background content — started all at once, WebKit fails some workers and never retries.
3. Marks started, running callbacks registered via `whenStarted(within:)` (pages that should wait briefly for extensions' early scripts), then checks for updates.

`load(_:)` re-prepares the folder with the current shim (`ExtensionShims.prepare`, off the main thread), creates the `WKWebExtensionContext`, sets its stable base URL, makes it inspectable, grants permissions (below), loads it in the controller, and adopts any custom keyboard shortcuts for its commands. `unload` also closes its popups and offscreen document, stops capture, releases any sleep assertion it held, and cleans up orphaned native hosts.

## Tabs and windows as WebKit sees them

`Tab` is a Swift class and WebKit's protocols are Objective-C, so each tab has an **`ExtensionTab`** adapter and each window an **`ExtensionWindow`** adapter, cached by id. Adapters read `tab.built`, never `tab.web`, so a sleeping or put-down tab is reported without being woken.

- Extensions see each window's row filtered by `seen(_:)`: private tabs are hidden unless they carry the controller. `windows.getAll` returns `Browsers.all`, oldest first.
- A tab showing **another extension's page is sealed**: its web view and URL are reported as `nil` to every other extension, whatever it was granted.
- `openNewTab` opens in the requested or front window (`browser.open(…atEnd: true)`), refusing `javascript:` and `file:` URLs (`mayOpen`).
- `openNewWindow` **refuses private windows** (they would land in the normal store and history). A `popup`-type window may only show http(s), `about:blank`, or the extension's own pages; it becomes a small `Browser` with `extensionPopup` set — never saved to `windows.json` — sized to the requested frame kept on screen.

## Permission policy

- **Installing is the consent.** On load, all `requestedPermissions`, `nativeMessaging`, and the manifest's match patterns are granted explicitly. Optional permissions are asked for when the extension asks.
- **Never granted, never asked**: other extensions' pages (`chrome-extension://*`, the former schemes) and `file:` URLs. `fence(_:)` sets explicit denials for those after every grant, because WebKit counts registered custom schemes inside `<all_urls>` and Chrome doesn't.
- WebKit's `promptForPermissionToAccess urls` (host access requested at runtime, often with no user action) is **always refused** silently, matching Chrome, where an extension has its manifest's sites, `activeTab`, and `permissions.request` grants.
- `promptForPermissionMatchPatterns` and `promptForPermissions` show a sheet ("… wants to read and change every website").
- Questions are serialized (one at a time) and shown as **sheets** on the front window, never app-modal alerts that would stall pages and other extensions. In tests, `answerForTests` answers instead.
- `nativeMessaging` is granted to all so the shim can talk to Search (`ExtensionShims.application`); talking to an **app on the Mac** additionally requires the manifest to really ask for it (`asksForNative`, which ignores what Search itself added, recorded in `.search-added`). Repeated failures to a missing host (>12 per second) are slowed.
- Install and update prompts list human-readable capabilities (`describe`), including Chrome APIs Search answers itself (`searchAnswered`: history, bookmarks, downloads, userScripts, desktopCapture…).

User gestures are tracked so `permissions.request` and capture behave like Chrome's "user gesture": `clicked`/`pressed` record button presses, a local event monitor records real clicks and keys in extension pages (`touched`), and `justUsed(id)` means within 5 s.

## The toolbar slot and popups

There is no toolbar: extensions live behind a **puzzle button** (`ExtensionSlot`), and pinned ones get their own button in the row (`setPinned`). `buttons` builds one entry per loaded extension with an action (label, 16 pt icon, badge, enabled) for the active tab; `actionsChanged` triggers redraws.

`press(_:)` records the gesture, opens the side panel if the extension asked for that on click, otherwise opens its popup **directly in Search's own popover** (`ExtensionPopup`), otherwise performs the action. WebKit's own popover is not used: for some extensions its messages never reached the worker. `ExtensionPopup` loads the popup page in a view built from the context's configuration, sizes it like Chrome (25×25 to 800×600, measured at DOMContentLoaded and followed as content changes), remembers each popup's last size, handles `window.close()`, routes camera/mic requests to the window's permission card, and closes on a second press of the same button. The popover hangs from the extension's button or, if unpinned or folded away, the puzzle button.

## Updates

Once per ~20 hours (`extensions.checked`), each store-installed extension is checked against Chrome's update service (`clients2.google.com/service/update2/crx`), parsing only the `<updatecheck>` element. A newer version is fetched, verified (`Crx.verifiedZip`), unpacked to a staging folder, shimmed, and loaded as a `WKWebExtension`. If it would gain any permission or site beyond what is recorded, the user is asked first. The folder is swapped atomically (`ExtensionFiles.replace`), and the extension is reloaded.

## Tests

<!-- openwiki: broken internal link [/openwiki/testing/test-suites.md] link "/openwiki/testing/test-suites.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
`Tests/SearchTests/ExtensionPopupWindowTests.swift` checks popup windows on the model only (no window is shown): they are never written to the saved window list and extensions see them as popups. Other extension tests are covered in [Test suites](/openwiki/testing/test-suites.md); `./bench ext-*` commands drive extensions against a test run.
