---
type: feature subsystem
title: Address field, suggestions and search
description: How the one field works — Address parsing (what counts as a place, http for local hosts), history completion and the suggestion list, search engines and custom templates, keyword shortcuts, Arc-style site search with learned OpenSearch descriptions, address-bar commands, the ⌘K open-tab switcher, and the site card shown under a tab's address.
tags: [omnibox, address-bar, search, completion, opensearch, navigation]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-098b3e70fd8275d3d2f90da8
    resource: repo://Sources/Search/Address.swift
  - id: openwiki-source-74264db9671959865379b391
    resource: repo://Sources/Search/AddressCommands.swift
  - id: openwiki-source-50d9705ad83befb6a5230076
    resource: repo://Sources/Search/Browser.swift
  - id: openwiki-source-626cb1763e72174ab3f8bad2
    resource: repo://Sources/Search/Keyword.swift
  - id: openwiki-source-53c316a9b7b1c9800ceadd1c
    resource: repo://Sources/Search/SiteCard.swift
  - id: openwiki-source-6da5ddf13b785492f9d97c10
    resource: repo://Sources/Search/SiteSearch.swift
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# Address field, suggestions and search

There is one field. On a blank tab it stands in the middle of the page; ⌘L raises it over a page (`Browser.editing`); clicking the address in the active tab edits it in place in the row (`TabAddressField`). The view is `Omnibox` (`Omnibox.swift`, an `NSViewRepresentable` text field underneath); the logic lives on `Browser` (`typed`, `offers`, `ending`, `picked`, `guess()`, `submit()`).

> Some older comments (`Address.swift`, `Omnibox.swift`) still say the field takes "addresses and only addresses". Searching was added later: non-addresses now go to the chosen engine. The rule that survives is that `Address` itself never guesses a search — it returns a URL or nil.

## What counts as an address (`Address.url(from:)`)

- Empty text, or anything containing a space, is not an address.
- With `://`, the scheme must be one the window can show (`http https file about data`); other schemes (`mailto:`, app links) are refused here rather than opening a blank tab. `about:` and `data:` without slashes are accepted.
- Otherwise the part before `/ ? #` must look like a host: `localhost`, four dotted numbers, `[::1]`, or dotted labels ending in an **alphabetic TLD of 2+ letters** (so `1.2.3` is a version, not a site). An `@` means an email address → not a place.
- **Local hosts get `http://`**, everything else `https://`: `localhost`, `*.localhost`, `*.local`, `127.0.0.1`, `0.0.0.0`, `192.168.*`, `10.*`, `172.16–31.*`. Local servers rarely have certificates.
- `Address.reachable` rewrites `0.0.0.0` (what dev servers print) to `localhost` at navigation time, since WebKit won't load it.
- `editable(_:)` shows a page's address for editing in the shortest form that round-trips back to the same URL; `pretty(_:)` is the host-and-path form tabs show before a title arrives.

## Suggestions (`Browser.guess()`)

Every change to `typed` recomputes the list:

1. **Empty field → no suggestions.** A list before you've said what you want is noise.
<!-- openwiki: broken internal link [/openwiki/features/history-bookmarks-downloads.md] link "/openwiki/features/history-bookmarks-downloads.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
2. Up to **three history places** (`History.suggestions(for:limit: 3)`, frecency-ranked, front doors before deep pages, host matches only; see [History](/openwiki/features/history-bookmarks-downloads.md)).
3. **A search row last**, and only if the text can't be an address: a matching keyword shortcut's search, otherwise the default engine's.
4. **An address-bar command first** when enabled and the whole text matches one.
5. The grey inline **ending** (`History.completion`) — the rest of the best match, never with a command on top. Backspace drops it for that keystroke (`stopCompleting`); Tab or → accepts it.

Open tabs are deliberately **not** mixed in — ⌘K exists for those. Arrow keys walk the list (`walk`); walking off the top releases it. A row clicked with the mouse is taken directly (`take`), so a list appearing under a resting pointer can't rewrite the field.

<!-- openwiki: broken internal link [/openwiki/architecture/overview.md] link "/openwiki/architecture/overview.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
**Submitting** (`submit`) — see also [Architecture overview](/openwiki/architecture/overview.md): an open-tab row switches to that tab; a command row runs; otherwise the target is the picked row, the completed text, or `destination(for:)` = site chip → `Address.url` → keyword → default engine. No target makes the field shake ("refusals"). ⌘Return opens the result in a new background tab, ⇧⌘Return in a foreground one.

## Search engines (`Engine.swift`)

Google (default), DuckDuckGo, Bing, Ecosia, Startpage, Kagi, Brave Search, Qwant, or **Custom**: a template with `%s`. A custom template must be http(s) with a host that stays the same whatever replaces `%s`; otherwise Google is used. Words are percent-encoded with only unreserved characters left bare. The engine's display name for a custom template is its host without `www.`.

## Keyword shortcuts (`Keyword.swift`)

Settings › General › Site shortcuts: `yt cats` goes straight to YouTube's search whatever the default engine is (Firefox's keyword bookmarks, without the bookmark). A keyword matches only as the first word, followed by a space and something more. Keywords whose template wouldn't be accepted today are skipped. They work whether site search is on or off.

## Site search (`SiteSearch.swift`)

Off by default (Settings › General › Search a site from the address field, new in 1.0.5). Type the start of a site's name — "red", "yout", "chat" — and the list offers "Search Reddit". **Tab** puts the site in the field as a chip (`siteChip`), and the words typed after it go to that site's search.

- A **built-in** list of popular sites (each hand-checked, 28 Sep 2026), matched by the start of the name, address or alternate names (`yt`, `so`), with at least two letters and no space. Wikipedia uses the Mac's first language; Amazon the Mac's region.
- **Learned** sites (OpenSearch, as Chrome reads it): when a site's **home page** loads over https in an ordinary tab (not private, not bench), Search reads its `<link rel="search">` in its own content world. If the description URL is on the **same registrable domain** (public-suffix aware, so `foo.github.io` can't speak for `github.io`), it fetches it over https, **without cookies**, at most 64 KB, following redirects only within the site, parses the HTML results template (optional parameters dropped, required ones → refused), and adds it to `search-sites.json` (max 40, oldest dropped).
- A learned site is **named by its address**, never by the name it gives itself, which could impersonate anyone, and is matched only by its address. Nothing is fetched for sites you haven't visited. Learned sites are forgotten with Clear History.

## Address-bar commands (`AddressCommands.swift`)

<!-- openwiki: broken internal link [/openwiki/interface/window-chrome.md] link "/openwiki/interface/window-chrome.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
Off by default (Settings › General › Address bar commands): typing exactly `settings`/`preferences`, `new tab`, `new private tab`/`private tab`, `new space` (only with Spaces on), `bookmarks`, `history`, `downloads`, `passwords`, or `toggle sidebar`/`sidebar` offers the app action as the top row, and Return runs it. Only the **whole** text matches, so "settings for gmail" or "sett" still searches. These are words, not keys (keys are [Shortcuts](/openwiki/interface/window-chrome.md)).

## ⌘K: switch to an open tab

`summon()` turns the field into a switcher (`summoning`): it lists **only open tabs in this window**, most recently used first (6 when empty, 3 when filtered by title or address), with the most recent already picked, so ⌘K then Return is the whole gesture. Holding ⌘ and pressing K again walks the list; releasing ⌘ lands. An address typed into it still works.

## The site card (`SiteCard.swift`)

Clicking the active tab (in the strip or column), or right-click › Site Information…, shows a small card under its address (#56): whether the connection is **private** (green `safe`) or readable by anyone on the way (amber `unsafe`), with certificate trust checked off the main thread, plus the page's own controls — copy address, print, zoom, whether it may autoplay sound (per-site `Autoplay`), whether its videos float out. It never takes the keyboard, and goes as soon as you type, leave the address, or use one of its lines.

## Tests

`Tests/site_search.py` (after `./build.sh`) drives site search through the bench in a hidden probe, including OpenSearch learning from duckduckgo.com and search.brave.com. History ranking and identity are covered by `Tests/HistoryRegression/`.
