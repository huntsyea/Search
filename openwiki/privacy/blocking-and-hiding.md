---
type: feature subsystem
title: Ad blocking and hidden elements
description: Shield, the built-in ad and tracker blocker compiled once as a WKContentRuleList (third-party tracker domains plus a short cosmetic list), toggled per navigation and pausable per site; and Curtain, which hides elements you point at by storing per-site selectors injected as a stylesheet at document start, with the picker, undo, private-tab behaviour, and the Hidden panel.
tags: [privacy, ad-blocking, content-blocker, wkcontentrulelist, hide-elements, css]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-50d9705ad83befb6a5230076
    resource: repo://Sources/Search/Browser.swift
  - id: openwiki-source-daad62809913bcef84933e7b
    resource: repo://Sources/Search/Curtain.swift
  - id: openwiki-source-db2a057f6462b48133f2d74a
    resource: repo://Sources/Search/Hidden.swift
  - id: openwiki-source-fc9b78c55ddd3ec773fb0af8
    resource: repo://Sources/Search/Prefs.swift
  - id: openwiki-source-a34ebfe82138473f3f7a80be
    resource: repo://Sources/Search/Registrable.swift
  - id: openwiki-source-6d21ace2d9c03c8b87701a34
    resource: repo://Sources/Search/Shield.swift
  - id: openwiki-source-6e6b2e557229ef129b26e320
    resource: repo://Sources/Search/Tab.swift
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# Ad blocking and hidden elements

## Shield — the ad blocker (`Shield.swift`)

"No settings, no counter, no shield icon going green." Shield is a **`WKContentRuleList`** compiled once at launch, enforced inside WebKit's networking **before a request is made** and before stylesheets apply, so it costs nothing at run time (unlike a JavaScript blocker).

### What it blocks

`Shield.compile()` builds three kinds of rules:

1. **Third-party requests to tracker/ad domains** (`unwanted`: doubleclick, googlesyndication, google-analytics, googletagmanager, amazon-adsystem, criteo, taboola, outbrain, hotjar, fullstory, clarity.ms, mixpanel, amplitude, segment, connect.facebook.net, ads-twitter, TikTok analytics, …) as `url-filter: ^https?://([^/]+\.)?domain` with `load-type: third-party`. **First-party requests are untouched**: a site's own scripts are the site.
2. **A deliberately short cosmetic list** (`slots`, `css-display-none` on every page): `.adsbygoogle`, `div-gpt-ad*`, `google_ads_*`, taboola containers, ad iframes, and whole-word EasyList generic class names for the boxes sites hold open for ads (`.ad-slot`, `.ad-unit`, `.dfp-ad`, …, #159). It's kept short because a generous cosmetic list is how a blocker starts eating the page.
3. **Per-site cosmetic rules** (`slotsBySite`, with `if-domain`) for slot names too generic to hide everywhere — `.ad` on AS and El País, The Guardian's and CNN's banner wrappers, The Independent's billboard — following EasyList's site rules.

The list is compiled into `WKContentRuleListStore.default()` under the identifier `office-shield`.

### On, off and per site

- **Global switch**: Settings (`shield` pref, default **on**) sets `Shield.shared.enabled` and `apply(to:)` adds or removes the list on every open tab's controller, effective from the next request.
- **Per site**: `pause(host, off)` adds the host to `shield.paused` (for sites it breaks, like a checkout that never finishes) — from the site card.
- **At every main-frame navigation**, `Browser.decide` calls `Shield.shared.tune(controller, for: host)` to remove and re-add the list for the destination, because a rule list applies from the moment it is added; doing it at navigation makes "off for this site" true for the whole page.
- **Every tab** calls `protect(controller)` when its view is built. Tabs created before compilation finishes are queued and given the list once it's ready.
- **Failure**: if building the JSON, getting the store or compiling fails, `trouble` is set. The Settings toggle may say "on" but nothing is blocked until `trouble` is nil, which is why it's surfaced rather than failing silently.

<!-- openwiki: broken internal link [/openwiki/extensions/chrome-api-shims.md] link "/openwiki/extensions/chrome-api-shims.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
Extensions' own `declarativeNetRequest` rules are separate (WebKit compiles them per extension; see [Chrome API shims](/openwiki/extensions/chrome-api-shims.md)).

## Curtain — hiding things for good (`Curtain.swift`, `Hidden.swift`)

⇧⌘H, then click a cookie banner, a newsletter overlay, a rail of "related" links: it goes, and **stays gone on that site next time, before the page draws a single frame**.

### Model and storage

- A `Veil` is `{selector, label, note, date}`. `label` names it in words (what it calls itself, then what kind of thing it is, then what it says); `note` records its size and corner at hide time, because a hidden element has no size to measure later and two elements often read alike.
- `Curtain.byHost` maps a **host without `www.`** to its veils, saved to `hidden.json` 0.4 s after a change (coalesced, atomic write).
- `css(on:without:)` emits **one rule per selector**, `selector { display: none !important; }`, so one unparseable selector can't break the rest. Leaving one out is how the panel previews what it would restore.

### Injection

At each main-frame navigation `Browser.decide` calls `tab.arm(hiding: curtain.css(on: host))`. `Tab.arm` rebuilds the tab's user scripts, adding `Veiling.style(css)` **at document start in Search's own content world**, so the stylesheet is in before the document has a body. `applyVeils` applies the same CSS to the page already showing. Because the CSS is set per navigation, it always matches the destination site.

### The picker

`Veiling.picker` is loaded on every page (main frame, Search's world) but asleep until `startPicking()`. Turned on, it outlines the element under the pointer with a name tag placed so it isn't clipped, and **swallows every kind of press** (pointerdown, mousedown, click…), because real pages act on pointerdown and would navigate away before a click completed. It builds a selector preferring an id or **"steady"** class names (words, not build hashes), checked for uniqueness, and falls back to a path anchored on the nearest named ancestor. The result is sent through `VeilRelay` (`officeVeil`) to `Tab.picked` → `Browser`, which calls `curtain.hide` and re-dresses the page. Problems ("couldn't hide that — …") are announced.

- **⌘Z while picking** brings back the last thing hidden (`undoHiding`).
- **Private tabs** don't write to the curtain: what you hide there is kept in memory **for that tab only** (`passingVeils`) and applied on top of the site's saved list.

### The Hidden panel (⇧⌘U)

`HiddenPanel` lists what is hidden on the current site. A list of selectors is unreadable, so **resting the pointer on a row puts that one element back, outlined, and scrolls to it** (`peek`: the stylesheet is rebuilt without that selector, rather than fighting it with another rule, so the element returns with its real layout). Restore one, or restore all for the site.

## Registrable domains (`Registrable.swift`)

`Registrable.domain(of:isSuffix:)` returns the registrable domain for a host given a public-suffix predicate (IP addresses and hosts that are themselves suffixes are returned whole). It underpins site matching elsewhere — `Vault.registrable` for passwords, relying-party and OpenSearch same-site checks — with the predicate supplied from macOS's public suffix list (CFNetwork).

## Related

<!-- openwiki: broken internal link [/openwiki/architecture/browser-and-tabs.md] link "/openwiki/architecture/browser-and-tabs.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Browser model, tabs and web views](/openwiki/architecture/browser-and-tabs.md) — where `decide`, `arm` and `protect` are called.
<!-- openwiki: broken internal link [/openwiki/architecture/persistence.md] link "/openwiki/architecture/persistence.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Persistence](/openwiki/architecture/persistence.md) — `hidden.json` and `shield.paused`.
<!-- openwiki: broken internal link [/openwiki/page/page-tools.md] link "/openwiki/page/page-tools.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Page tools](/openwiki/page/page-tools.md) — other per-page features.
