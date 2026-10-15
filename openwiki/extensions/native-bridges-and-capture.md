---
type: subsystem
title: "Extension native bridges: messaging, sockets, offscreen, capture"
description: The native pieces that let Chrome extensions do what WebKit alone can't — Chrome native messaging hosts, a URLSession WebSocket for workers, offscreen documents, screen/camera/mic capture with per-extension consent and the recording pill, externally_connectable pages, and the policy for websites returning to extension pages.
tags: [extensions, native-messaging, websocket, offscreen, screen-recording, security, redirect]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-50d9705ad83befb6a5230076
    resource: repo://Sources/Search/Browser.swift
  - id: openwiki-source-9230d1d8e1772c063b3a127e
    resource: repo://Sources/Search/ExtensionCapture.swift
  - id: openwiki-source-aac7a0f4c669c29d8b4e3809
    resource: repo://Sources/Search/ExtensionExternal.swift
  - id: openwiki-source-f3f92b120cef48637db74e83
    resource: repo://Sources/Search/ExtensionNative.swift
  - id: openwiki-source-904602ad2d1243bd88f1cbd8
    resource: repo://Sources/Search/ExtensionOffscreen.swift
  - id: openwiki-source-ae516606176c1cc78277b3ce
    resource: repo://Sources/Search/ExtensionRedirectPolicy.swift
  - id: openwiki-source-8e837bb324e561446fd9054e
    resource: repo://Sources/Search/ExtensionReturnNavigation.swift
  - id: openwiki-source-6c58140c7da87ff0c3f3d281
    resource: repo://Sources/Search/ExtensionSocket.swift
  - id: openwiki-source-3133c1976a862a1bfcdf22d1
    resource: repo://Sources/Search/RecordingIndicator.swift
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# Extension native bridges: messaging, sockets, offscreen, capture

<!-- openwiki: broken internal link [/openwiki/extensions/chrome-api-shims.md] link "/openwiki/extensions/chrome-api-shims.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
<!-- openwiki: broken internal link [/openwiki/extensions/architecture.md] link "/openwiki/extensions/architecture.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
These files sit between WebKit's `WKWebExtension` and the Mac, filling gaps the [shim](/openwiki/extensions/chrome-api-shims.md) can't fill in JavaScript alone. All are `@available(macOS 15.4, *)` except where noted. Entry points are on `Extensions`' controller delegate (see [architecture](/openwiki/extensions/architecture.md)).

## Native messaging (`ExtensionNative.swift`)

Password managers, clippers and the like talk to a desktop app through Chrome's native messaging. Search reuses **Chrome's host registrations**: the JSON manifests in `NativeMessagingHosts` folders for Chrome, Chromium, Edge, Brave and Arc (per user and system-wide), then Vivaldi and Opera last so a Chrome/system host of the same name wins.

`host(_:for:)`:

- host name must match `^[a-z0-9_]+(\.[a-z0-9_]+)*$`;
- the manifest's `allowed_origins` must contain `chrome-extension://<id>/` — otherwise "forbidden";
- `path` (absolute, or relative to the manifest's folder) must be executable.

`HostPipe` runs the program with the origin as its argument and speaks Chrome's framing: a 4-byte length and JSON over stdin/stdout.

- `runtime.sendNativeMessage` → `send`: start, write one, read one, stop.
- `runtime.connectNative` → `connect`: keeps the process and the `WKWebExtension.MessagePort` paired until either side ends. The shim's `{"__searchNative":"here?"}` probe is answered without reaching the host; after that, a `"alive"` ping every 25 s makes the worker post on the port, because WebKit unloads a worker that hasn't posted for two minutes (iCloud Passwords forgot its pairing).
- `stopOrphans()` stops hosts whose port is disconnected: WebKit doesn't always call disconnect handlers when an extension unloads, which left helpers (and their code prompts) running until quit.

The gate that an extension's manifest really asked for `nativeMessaging` is applied in `Extensions` before either call (`asksForNative`); failures to a missing host more than 12 times a second are slowed by a second.

## WebSockets for workers (`ExtensionSocket.swift`)

WebKit runs extension service workers on the web process's main thread, and a worker's `WebSocket` waits there synchronously for the main thread — a self-deadlock that froze the extension's every page (1Password, right after sign-in). In a worker, the shim's `WebSocket` instead connects a native port named `search.socket`; `ExtensionSocket.Connection` opens a `URLSessionWebSocketTask` (only `ws`/`wss`), with `Origin: chrome-extension://<id>` and the worker's user agent, and relays frames: text as is, binary as base64, plus `close`. It posts `{ready: true}` on open and again on the worker's `open` (the first is often lost).

## Offscreen documents (`ExtensionOffscreen.swift`)

`chrome.offscreen.createDocument` → `ExtensionOffscreen.create`: one document per extension (a second create throws, and the slot is reserved before any `await` so concurrent creates can't make two). The page must be the extension's own; it gets a copy of the context's preferences with `inactiveSchedulingPolicy = .throttle` (no window, so not suspended, but throttled). For `USER_MEDIA` reasons, WebKit's "getUserMedia requires focus" is turned off (Search still asks first, and the pill shows it). The document is reported to WebKit as a tab adapter (so content scripts in its iframes are identified) but never enters any `Browser.tabs`.

`offscreen.sendMessage` deliveries are checked against the document's frame, tab id and current URL, deduplicated by token so a relay heard by the worker and several pages produces one delivery and one reply. Unloading an extension closes its document.

## Screen, camera and microphone capture

### `ExtensionCapture.swift`

Chrome gives extensions a picker (`desktopCapture.chooseDesktopMedia`) and stream ids for `getUserMedia`; WebKit has only `getDisplayMedia`, which it refuses unless called from a click in an on-screen page. Search stands in between (#218: Loom, Screencastify, Awesome Screenshot):

1. An extension page posts on the `searchCapture` channel; `sender(of:)` accepts only the **top frame of the extension's own page, in that extension's view** — not a site framed in it, its page framed in a site, or another extension.
2. **Consent**, once per extension, stored as `extensions.capture.<id>`, but a remembered yes counts only if the user just used the extension (button within 60 s, or its pages within 5 s, `Extensions.justUsed`); otherwise it asks again. A refusal isn't re-asked until restart. The extension must declare `desktopCapture` (or have it granted).
3. A worker gets a **stream id**: 16 random bytes as hex, good once, for one minute, for that extension (`grant(for:)`); one of its pages redeems it.
4. Search brings the page on screen and calls `getDisplayMedia` itself, which WebKit counts as a click; **macOS's own picker** then asks what to share, every time. No ScreenCaptureKit, no Screen Recording permission.

Test runs never bring anything on screen; `mockDevices` provides fake camera/mic.

### `RecordingIndicator.swift`

<!-- openwiki: broken internal link [/openwiki/architecture/browser-and-tabs.md] link "/openwiki/architecture/browser-and-tabs.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
While any extension records (screen, window, camera or mic), a small **pill** at the foot of the screen says "● *Name* is recording your screen — Stop", one line per extension, without taking focus or keys. Stop calls `ExtensionCapture.stop`. Tabs whose page is capturing get `Tab.recording`, which marks them in the row and keeps them awake (see [tabs](/openwiki/architecture/browser-and-tabs.md)). An **offscreen** document that records (Tella, Vidyard) has no on-screen view WebKit would accept, so its web view is **lent to the pill** as a 2×2 pt view behind the pill's content while recording, and given back after.

## Websites messaging extensions (`ExtensionExternal.swift`)

Not gated on macOS version at the type level. For `externally_connectable` (#496 — claude.ai handing Claude in Chrome its sign-in), WebKit already routes `browser.runtime.sendMessage` from listed pages to `runtime.onMessageExternal`, but pages call `chrome.runtime`. Search injects `chrome.runtime` (`sendMessage`/`connect`, with callbacks and promises) **only into pages some loaded extension lists**, and only if the page has no `chrome` of its own; a `chrome` on every site would tell them all this is Chrome. `allowed(_:)` rejects patterns Chrome would (`*://*/*`, wildcards over a TLD, wildcards elsewhere in the host) and **any Google domain**, where a partial `chrome` with a Safari UA trips sign-in/reCAPTCHA browser checks.

## Websites returning to extension pages

A site (an OAuth provider, say) may navigate a tab to a `chrome-extension://` page. WebKit's web views can't show extension pages, so the tab must be replaced with an extension view — but only for pages the extension exposes.

- `ExtensionReturnNavigation` (per tab) records the navigation's **source** from WebKit's provenance: the source frame's https origin for main-frame, body-less GET navigations; for a still-blank tab, only a subsequent main-frame server redirect of the same provisional navigation counts. It never infers a source from `WKWebView.url` (already the destination during a redirect), errors, Referer or history.
- `ExtensionRedirectPolicy.allows` checks the target against the manifest's `web_accessible_resources`: https source only; no credentials or port; path must be a clean decoded path (rejects `%2f`, `%5c`, backslashes, residual `%`, control characters, `.`/`..`/empty segments). MV2 resource lists match by `*` glob; MV3 rules need a matching resource **and** a matching origin (`<all_urls>`, `https://host/*`, `*.suffix`); `use_dynamic_url: true` is refused. Anything unsupported fails closed.
- `Browser.routeExtensionReturn` / `handOverExtensionReturn` cancel the web navigation and `replace` the tab with an extension view at the target — never for private tabs, and only if the extension is loaded and the tab is still on the same navigation revision.

## Related

<!-- openwiki: broken internal link [/openwiki/page/permissions-and-dialogs.md] link "/openwiki/page/permissions-and-dialogs.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Page dialogs, permissions and notifications](/openwiki/page/permissions-and-dialogs.md) — the camera/mic card used for extension pages too.
<!-- openwiki: broken internal link [/openwiki/passwords/passkeys.md] link "/openwiki/passwords/passkeys.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Passkeys](/openwiki/passwords/passkeys.md) — the patch the shim puts in MAIN-world content scripts.
