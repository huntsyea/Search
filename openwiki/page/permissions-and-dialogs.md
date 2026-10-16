---
type: feature subsystem
title: Page dialogs, permissions and notifications
description: How Search answers what pages ask — alert/confirm/prompt, file pickers, HTTP auth and bad certificates as sheets over the asking tab only (held for background tabs, per-pane in Split View); camera, microphone, location and notification permission cards remembered per origin under capture.* keys; web notifications through WebKit's private store delegate; pop-ups, print() and dead web processes.
tags: [permissions, dialogs, camera, location, notifications, security, webkit]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-443ae6faac7b0d18ff3addda
    resource: repo://Sources/Search/App.swift
  - id: openwiki-source-50d9705ad83befb6a5230076
    resource: repo://Sources/Search/Browser.swift
  - id: openwiki-source-eb0cee777122274fb19fa231
    resource: repo://Sources/Search/Dialogs.swift
  - id: openwiki-source-03dd60eb1c1318a3b76b4792
    resource: repo://Sources/Search/Notifications.swift
  - id: openwiki-source-6e6b2e557229ef129b26e320
    resource: repo://Sources/Search/Tab.swift
  - id: openwiki-source-6be6fe9e9b5cd8c1a25f46ba
    resource: repo://Tests/dialog_keys.py
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# Page dialogs, permissions and notifications

WebKit does nothing with `alert()`, `confirm()`, `prompt()`, a file input or a password-protected site unless the app answers for it. "Nothing" means `confirm()` is always false (so "leave without saving?" leaves) and file pickers never open. `Sources/Search/Dialogs.swift` (an `extension Browser` implementing `WKUIDelegate` methods) shows the system's own sheets on the window the page is in.

## The rule: a question goes over its own page only

`Browser.ask(from:show:drop:)` is the gate for every page question:

- From the **active tab**: shown now, as a sheet on the window.
- From a **background tab, or another space**: held as a `HeldQuestion` in `heldDialogs[tab]` and presented when you switch to that tab (`activeID.didSet`). Shown over the tab in front, a `prompt()` asking for a password would pass for that page's.
- From one page of the **Split View pair on screen**: drawn as a `PaneQuestion` card over that pane only (`PaneQuestionCard`), so the other page keeps working. It names the asking **frame's own origin**, never the page's address.
- **Every question is answered exactly once.** WebKit requires an answer, and answering twice crashes the page. A held or pane question that is let go (tab closed or navigated, Split View turned off) answers as *dismissed* (`dropQuestions`). Held questions also keep a tab from sleeping.

What's asked this way:

| Page asks | Answer |
|---|---|
| `alert` / `confirm` / `prompt` | `NSAlert` sheet (or pane card) |
| File input (`runOpenPanelWith`) | `NSOpenPanel` naming the site the file goes to; in a test run, cancelled (never shown) |
| HTTP Basic/Digest auth (`signIn`) | Name/password sheet; one wrong answer gets another try, the second failure is taken as "not for me" |
| Server trust (`trust`) | Valid certificates are left to the system. If invalid: **localhost/loopback is trusted**; anything else (including `.local` and private-network addresses) is **asked about once per site per launch**, and only for the **main page** — subresources from a bad certificate simply don't load |
<!-- openwiki: broken internal link [/openwiki/architecture/browser-and-tabs.md] link "/openwiki/architecture/browser-and-tabs.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Opening another app (`handOff`) | "Open “App”?" sheet, see [tabs](/openwiki/architecture/browser-and-tabs.md) |

Keys typed while a question hangs from the window go to the question: Escape is its Cancel, not "close the panel underneath" (`Tests/dialog_keys.py`).

## Camera, microphone, location

All three use the same **card over the asking page** (`Browser.asking: CaptureAsk`, drawn by `ContentView.captureAsking`) with Allow / Allow Once / Don't Allow. The card **ignores clicks during its first 0.5 s**, so a page can't time a click to land on Allow as it appears. Only one question is shown at a time; a second page asking meanwhile is refused rather than queued.

- **Camera/microphone** (`askedForCapture`, also used by extension popups): remembered per **origin** (scheme + host + non-default port: `http://site` and `https://site` are different) and media type, as `capture.<origin>|<type>`. A background tab or the other pane waits until you go to it. When an **extension page** asks (its popup, or its own frame inside a website, like a recorder's camera bubble), it's named and remembered **as the extension**, never the host site, so allowing the bubble doesn't give the site the camera.
- **Location** (`askedForLocation`, a non-public WebKit delegate method on macOS; unanswered, every page is refused): only the **tab in front**, only for the page's own origin or a same-origin frame (frames from elsewhere can't borrow its answer), remembered as `capture.<origin>|location` only for "always". Test runs never go on to ask macOS.
- **Private tabs** are asked but **never remembered**.
<!-- openwiki: broken internal link [/openwiki/integrations/macos.md] link "/openwiki/integrations/macos.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- The hardened runtime requires the camera, audio-input and location entitlements and usage strings (see [macOS integration](/openwiki/integrations/macos.md)).
- **Settings › Privacy › Forget choices** (`forgetCaptureChoices`) removes every `capture.*` key (and site "don't float" choices).

<!-- openwiki: broken internal link [/openwiki/extensions/native-bridges-and-capture.md] link "/openwiki/extensions/native-bridges-and-capture.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
Extension screen recording has its own consent flow; see [native bridges](/openwiki/extensions/native-bridges-and-capture.md).

## Web notifications (`Notifications.swift`, #328)

- **Asking** (`askedForNotifications`): a card over the asking page, for its own origin, stored as `capture.<origin>|notifications`. Refused without a card in **private tabs** or when Settings › Privacy › *Let sites ask to send notifications* (`notifications.ask`) is off. The first site allowed triggers macOS's one-time authorization for Search.
- **Delivering**: `SiteNotifications` attaches as delegate to each non-private data store (`Web.configuration` → `attach`) through WebKit's **non-public** store delegate methods, asked for by name. Service-worker notifications are posted as Mac notifications named by the site and wearing its icon. For page (non-worker) notifications, `PageNotifications.provide` installs a provider on the page's notification manager via WebKit's C API (`WKNotificationProviderV0`, laid out by hand). A click brings the site's tab forward; click and dismissal are reported back to the page/service worker, as in Chrome. If WebKit lacks the names, nothing is posted and nothing breaks.
- Only allowed origins post, and only while the switch is on. Settings › Privacy lists allowed sites and can forget each.
- **Test runs post nothing** (it would land on someone's screen); they keep a list for the bench (`./bench notifications`).

## Pop-ups

`javaScriptCanOpenWindowsAutomatically = false` in every configuration: `window.open` works only from a click or key (Safari's pop-up blocking), so a sign-in window opened by its button still works but a page can't open tabs on load or a timer. Opened windows become tabs (`createWebViewWith`); one with a size or no toolbar is marked `popup` and named by its **site**, never its title (a page could title it "Sign in with Google" over someone else's address). A pop-up that calls `window.close()` returns you to its opener (`webViewDidClose`).

## `print()` from a page

A page's own `print()` or ⌘P inside an editor reaches Search through a non-public delegate method. Only the **front tab of the front window** may ask, one sheet at a time; the page's script waits until the sheet is gone (`PrintSheet`). A site that re-asks each time it's cancelled is ignored after **two cancels within ten seconds**, until the tab goes to another site.

## A page whose process died

<!-- openwiki: broken internal link [/openwiki/architecture/browser-and-tabs.md] link "/openwiki/architecture/browser-and-tabs.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
`webViewWebContentProcessDidTerminate` drops the tab's pending questions, reloads the active tab straight away, and marks a background tab `stale` to recover when you return (see [Browser model](/openwiki/architecture/browser-and-tabs.md)).
