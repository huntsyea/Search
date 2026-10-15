---
type: feature subsystem
title: "Page tools: reader, find, peek and more"
description: The per-page tools — Reading mode's article heuristic, Find on Page built in Search's own content world, text substitutions, the custom image menu, the link status line, Peek (shift-click), middle-click and autoscroll, Search's own back/forward swipe, and the Web Inspector — with their defaults and tests.
tags: [reader, find, peek, swipe, inspector, context-menu, page]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-290f249b86db710f770b1c77
    resource: repo://Sources/Search/AutoScroll.swift
  - id: openwiki-source-50d9705ad83befb6a5230076
    resource: repo://Sources/Search/Browser.swift
  - id: openwiki-source-54f6bab3d94a2fee561ac8d5
    resource: repo://Sources/Search/ImageMenu.swift
  - id: openwiki-source-cf80cb286acd65d3b90ac9a2
    resource: repo://Sources/Search/Inspector.swift
  - id: openwiki-source-fe775f56efe6e02051192b20
    resource: repo://Sources/Search/PageFind.swift
  - id: openwiki-source-199dc4f0a33a9f3f841610bf
    resource: repo://Sources/Search/Peek.swift
  - id: openwiki-source-fc9b78c55ddd3ec773fb0af8
    resource: repo://Sources/Search/Prefs.swift
  - id: openwiki-source-4566e8608f450a4e48e7b681
    resource: repo://Sources/Search/Reader.swift
  - id: openwiki-source-5632aca42bcac1aa2c19332a
    resource: repo://Sources/Search/StatusLine.swift
  - id: openwiki-source-6667f8c853322f282f974ed7
    resource: repo://Sources/Search/Substitutions.swift
  - id: openwiki-source-b2afdd088edcb44837cd12be
    resource: repo://Sources/Search/Swipe.swift
  - id: openwiki-source-6e6b2e557229ef129b26e320
    resource: repo://Sources/Search/Tab.swift
  - id: openwiki-source-2d129081a33bcee8ef790401
    resource: repo://test-find
  - id: openwiki-source-b4bea035b2d80a9733ab2222
    resource: repo://Tests/PageFindHarness.swift
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# Page tools: reader, find, peek and more

<!-- openwiki: broken internal link [/openwiki/architecture/browser-and-tabs.md] link "/openwiki/architecture/browser-and-tabs.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
Each tool is one file. Most work by injecting a small script into the page **in Search's own content world** (`Web.world`, which page scripts can't see or tamper with) and reporting back through a relay registered in `Tab.build()` (see [Browser model](/openwiki/architecture/browser-and-tabs.md)).

> **Defaults vs. file headers.** The headers of `Peek.swift` and `StatusLine.swift` say "off unless asked for", but `Preferences` now defaults both to **on** ("On unless turned off": `links.peek`, `links.show`). Trust `Prefs.swift`.

## Reading mode (`Reader.swift`, ⇧⌘R)

<!-- openwiki: broken internal link [/openwiki/ai/assistant.md] link "/openwiki/ai/assistant.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
Picks the article with the classic heuristic: the element carrying the most prose, **penalised for every link inside it** (navigation, related-article rails and comment threads are made of links; prose isn't). `Tab.toggleReader` runs `Reader.script` and sets `reader` only if it answers `"read"`. **Leaving reading mode reloads** the page rather than restoring the old markup, which would look right but have lost every event listener. The [AI add-on](/openwiki/ai/assistant.md) reuses the same article detection.

## Find on Page (`PageFind.swift`, `Find.swift`, ⌘F)

`FindBar` is a pill in the top corner saying e.g. "3 of 17". `PageFind` builds the match list **in Search's own world**, so the page can't see the query, the list, or the functions used. A page that replaces `Range`, `getSelection` or `RegExp` only changes its own world's copies. The count and the range selected by Next always come from the same list.

- Counting stops at **`PageFind.limit` = 1000** (as Safari does), extending as Next goes past the end, because measuring each match's boxes is the expensive part on long pages.
- Options: match case, whole words. Unicode case folding; composed/decomposed forms match; a letter typed without an accent finds accented ones (as WebKit's find does), unless Match case is on.
- Hidden text (`display:none`, `visibility:hidden`) is excluded; same-origin iframes are searched; selections in iframes and inputs are restored and cleaned up when moving between hits.
- Switching tabs carries the words to the new page; a page that finishes loading with the bar open is searched again (`Browser.webView(_:didFinish:)`).

`./test-find` compiles `PageFind.swift` with `Tests/PageFindHarness.swift` and runs it standalone (17-hit navigation and wrap-around, case and whole-word options, umlauts, composed/decomposed é, unaccented queries, hidden text, literal quotes/backslashes, iframe moves, selection cleanup). `./bench find TEXT [next N] [back N] [case] [words]` checks it in a test run.

## Text substitutions (`Substitutions.swift`)

Edit › Substitutions, as in Safari: **Text Replacements** (follows System Settings › Keyboard), **smart quotes** and **smart dashes** (both start **off** — wrong in every code field). WebKit's text checker reads its switches once from the app's **standard** defaults (not the test suite) and applies them to every page; its own toggle action flips it everywhere and writes back to those defaults. `Substitution.register()` runs before the first web view, and autocorrect is told to WebKit the same way (`Preferences.tellWebKit`). `./bench textcheck` tests this in a copy under its own bundle id.

## Image context menu (`ImageMenu.swift`)

WebKit's image menu (Safari's) has two items that do nothing on some sites: **Download Image** never asks for a download (it isn't a navigation the app's delegate sees), and **Copy Image** writes a pasteboard promise that pasting doesn't always resolve. No public hook can fix WebKit's menu, so for an `<img>` only, a script asks the page's own menu to step aside on that element's `contextmenu`, and Search shows its own menu (`ImageRelay` → `Browser` extension) that downloads and copies the image a different way. Lost: Copy Subject and Look Up, which are system features with no public API.

## Link status line (`StatusLine.swift`)

Where a link goes, shown at the bottom of the page while hovering (`LinkBubble`). `HoveredLink` relays the resolved address to the tab (holding it weakly, so closing the tab frees the page). When the setting is off, the listener is not put into pages at all, and pages already open go quiet. It runs in the `.defaultClient` world.

## Peek (`Peek.swift`)

Shift-click a link (Arc's peek): its page opens in a panel over the current one, which stays put underneath and is dimmed around the panel. Escape, a click beside it, or its cross closes it; **keep** (⌘Return or its button) moves it into the row beside the source tab, loaded as is. It joins the source's group, or with Split View, ⌥⌘Return keeps it **in a pair** with the source. The peek is a tab of its own that isn't in the row, so nothing loads twice. Triggered in `Browser.decide` only for http(s) link activations with exactly Shift held, from a tab in the row, with no peek already open. Selecting another tab closes it.

## Middle-click and autoscroll

- **Middle-click on a link** opens it in a background tab beside this one. WebKit gives the browser no navigation action for the middle button (and reports buttons as a mask where 2 is the *right* button), so `MiddleRelay` listens to the page's own `auxclick` in the main frame, as it bubbles back up: only real (`isTrusted`) clicks, only unclaimed ones (`preventDefault` respected), only links to somewhere the browser would go. Any navigation action WebKit does report for the middle button is cancelled in `decide`.
- **Autoscroll** (`AutoScroll.swift`, off by default in Settings › General): a middle-click on a page (not a link) leaves a mark, and the page scrolls toward the pointer, faster the further away it is; another click, Escape or the wheel stops it, and hold-and-drag stops on release. Done in the page, which knows which element scrolls.

## Back/forward swipe (`Swipe.swift`)

WebKit's own swipe (dragging the page with a snapshot of the last) is **disabled** (`allowsBackForwardNavigationGestures = false`). Instead, two fingers sideways bring in a disc from the pulled edge; past a threshold it's armed, and releasing goes back or forward. Nothing slides and no snapshot is kept. On every sideways wheel event the page is asked whether anything under the pointer can scroll that way (carousel, wide table, map, canvas) or took the event; the answer comes a frame or two in, before anything is drawn. Rubber-banding is turned off (`Swipe.calm`). Optional (`swipe.history`, off): holding an armed swipe shows a list of pages that way to pick from.

## Web Inspector (`Inspector.swift`)

WebKit's inspector on the front tab: View menu and Chrome/Arc keys — ⌥⌘I inspector, ⌥⌘J console, ⌥⌘C pick an element — plus Inspect Element in a page's right-click menu. Developer extras are enabled on every page via a private preference; the inspector calls are private API, each checked with `responds(to:)`, so a WebKit without them leaves the menu inert. `StageView` restores a docked inspector when its page comes back on screen. Pages are also `isInspectable` for Safari's Develop menu.

## Elsewhere

<!-- openwiki: broken internal link [/openwiki/integrations/macos.md] link "/openwiki/integrations/macos.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- **Little window** for links from other apps, and **Share**: [macOS integration](/openwiki/integrations/macos.md).
<!-- openwiki: broken internal link [/openwiki/page/media.md] link "/openwiki/page/media.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- **Floating video**: [Video and audio](/openwiki/page/media.md).
<!-- openwiki: broken internal link [/openwiki/privacy/blocking-and-hiding.md] link "/openwiki/privacy/blocking-and-hiding.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- **Hide elements** (⇧⌘H): [Ad blocking and hidden elements](/openwiki/privacy/blocking-and-hiding.md).
