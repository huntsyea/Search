---
type: feature subsystem
title: History, bookmarks and downloads
description: The browser's own records — History (visit identity, frecency, capped JSON file feeding address completion), Bookmarks (tree model, bar, panels, Netscape HTML format), downloads (FetchEntry/Fetches pause–resume–retry lifecycle, private downloads, Loot memory, save locations), favicons, and the tests and harnesses that cover them.
tags: [history, bookmarks, downloads, favicons, persistence, frecency]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-3fce78f1ecf9d16c3307e665
    resource: repo://Sources/Search/Bookmarks.swift
  - id: openwiki-source-a97ff61923191a97675d2505
    resource: repo://Sources/Search/BookmarksBar.swift
  - id: openwiki-source-0996e09f4a0b6db6296e3cc8
    resource: repo://Sources/Search/BookmarksFile.swift
  - id: openwiki-source-50d9705ad83befb6a5230076
    resource: repo://Sources/Search/Browser.swift
  - id: openwiki-source-37b31c89058e61703536e3f0
    resource: repo://Sources/Search/Fetching.swift
  - id: openwiki-source-3fc03362e153f232f43d994b
    resource: repo://Sources/Search/History.swift
  - id: openwiki-source-12b1e82b99dc52b330146703
    resource: repo://Sources/Search/Icons.swift
  - id: openwiki-source-1c5bbbfd8e732117a4da40f7
    resource: repo://Sources/Search/Loot.swift
  - id: openwiki-source-7f7a48db30537642e622c56a
    resource: repo://Tests/HistoryRegression/README.md
  - id: openwiki-source-ef7775ccb2b4dbf18dc4c9d0
    resource: repo://Tests/HistoryRegression/run.sh
  - id: openwiki-source-6b5661225021f2d716c6def8
    resource: repo://Tests/SearchTests/DownloadLifecycleTests.swift
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# History, bookmarks and downloads

<!-- openwiki: broken internal link [/openwiki/architecture/persistence.md] link "/openwiki/architecture/persistence.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
<!-- openwiki: broken internal link [/openwiki/interface/window-chrome.md] link "/openwiki/interface/window-chrome.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
All three are shared across windows through `Shared` (`Shared.history`, `Shared.bookmarks`, `Shared.fetches`, `Shared.loot`) and stored as JSON files in the Store folder (see [Persistence](/openwiki/architecture/persistence.md)). Their panels are built from the common `Plate` pieces (see [Window chrome](/openwiki/interface/window-chrome.md)); `Recall.swift` holds `HistoryPanel` (⌘Y) and `DownloadsPanel` (⇧⌘J).

## History (`History.swift`)

History exists "so the field can finish the address for you". `Browser.webView(_:didFinish:)` calls `history.record(url, title:)` for every finished main-frame load **except private and bench tabs**.

**Identity.** `History.identity(for:)` lowercases scheme and host, removes user/password and fragment, and treats an empty path as `/`; the path and query keep their exact spelling and encoding. `History.kept(_:)` strips credentials from any recorded URL, and loading an older file removes them too (and rewrites the file at once). Only `http`/`https` are recorded.

**Visits** are `{url, key, title, count, last}`. Recording a deep page **also credits the site's home page**, so typing three letters offers the front door rather than last week's article. Counts are clamped to `mostVisits` so hand-edited files can't overflow.

<!-- openwiki: broken internal link [/openwiki/navigation/address-field.md] link "/openwiki/navigation/address-field.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
**Ranking (frecency).** `score = count × exp(−days/30)`: a month-old visit counts about a third of a fresh one. `suggestions(for:limit:)` keeps only the best few while scanning (no allocation per match), ranks where the match falls (start of host first; subdomain matches like "google" → mail.google.com; nothing from a single letter in the middle; **never** path matches), prefers a front door over a room inside it, and falls back to a built-in list of well-known sites (`known`) only when memory has nothing. `completion(for:among:)` returns the grey inline ending. An empty field suggests nothing. See [Address field](/openwiki/navigation/address-field.md).

**Persistence.** `history.json`, written **1.5 s after** a visit (coalesced), via `Disk`; the file keeps only the **2,000 best-scoring** visits. The History menu's recent list is cached because the menu bar redraws on every keystroke.

**Import.** `take(_:title:count:last:)` merges visits from another browser using the larger count (not the sum), so importing twice doesn't double-count; `settle()` saves after a batch.

**Clearing.** `forget()` empties history; `Browser.clearHistory()` also clears favicons on disk and the site searches learned from visited sites (`SiteSearch.forget()`).

## Bookmarks (`Bookmarks.swift`, `BookmarksBar.swift`, `BookmarksFile.swift`)

A `Bookmark` is `{id, title, url?, children?}` — a nil `url` is a folder. A bookmark with an emptied name is "unnamed" and shows as its icon alone on the bar, as in Chrome and Safari. `Bookmarks` publishes `roots` and maintains a `kept` set of URL strings so "is this page bookmarked?" (asked on every redraw of the button) is O(1). `matches(_:)` (all words in title or URL, with folder path) is the same rule `chrome.bookmarks.search` uses.

Shown as the app's own lists rather than system menus, on purpose — a system menu can't be dragged into or right-clicked: `BookmarksPanel`, `BookmarkOutline`, `BookmarksDropdown`, and `BookmarkMenu` (an `NSMenu` used for bar folders). Removing a non-empty folder asks first.

The **bookmarks bar** is off by default (Settings › Tabs or Bookmarks › Show Bookmarks Bar). It hides with the tabs when folded (⌘S) and when a video is fullscreen; folders open as menus; overflow scrolls sideways.

Bookmarks are written to `bookmarks.json`. Extensions read and change them via the shimmed `chrome.bookmarks` API (`insert`, `update`, …), with Chrome-style ids (root `0`, bar `1`).

<!-- openwiki: broken internal link [/openwiki/import/browser-import.md] link "/openwiki/import/browser-import.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
**Netscape bookmark files.** `BookmarksFile` reads the HTML format every browser exports (`<DT><H3>Folder</H3><DL><p><DT><A HREF=…>`), loosely: tags in any case, omitted paragraphs and closing tags, attributes in any order. Only http/https addresses are kept. A cancellable variant reports progress (stage names and counts, never contents) for the file importer. See [Importing](/openwiki/import/browser-import.md).

## Downloads (`Fetching.swift`, `Loot.swift`, download delegate in `Browser.swift`)

### How a download starts

- A navigation flagged `shouldPerformDownload` → `.download`.
<!-- openwiki: broken internal link [/openwiki/architecture/browser-and-tabs.md] link "/openwiki/architecture/browser-and-tabs.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- A response with `Content-Disposition: attachment`, or a MIME type WebKit can't show → `.download` (redirects are always followed). See [tabs](/openwiki/architecture/browser-and-tabs.md).
- Context-menu "Download Linked File" (`contextMenuDidCreateDownload`), the PDF viewer's download button (a private WebKit delegate method), and Search's own image menu.

**Where it goes** (`whereToSave`): only the last path component of the suggested name is used (never a path out of the folder; empty/`.`/`..` become `download`). The default folder is `~/Downloads` (or the configured one; per-space folders are possible with Spaces); with Settings › Ask where to save, an `NSSavePanel`. Because WebKit won't overwrite, a taken name becomes `name 2.ext`, `name 3.ext`… Test runs download into the test world's own folder so macOS never prompts.

### `FetchEntry` and `Fetches`

`FetchEntry` is one row in the Downloads panel: state `downloading | pausing | paused | resuming | failed`, name, progress, bytes, error. Its **resume data, original request and data store live in memory only** — never in the saved list — and resume/retry reuse the same store so private cookies never reach normal downloads and vice versa.

- **Pause/resume** use `WKDownload` resume data. `canPause` requires a replayable request; a server that gives no resume data turns pause into a retryable failure with "The server doesn't let this download pause."
- **Retry** only for plain GET/HEAD (`replayable`) — a POST would resubmit a form — and writes to a freshly numbered name.
- **Partial-file ownership.** A destination is claimed only after real bytes arrive, identified by volume, inode, size and mtime. Resume continues only if the file is still the one this download wrote (`partialFileIsOurs`); otherwise resume data is dropped and only Retry remains. Cancel/discard deletes the partial file only while that identity still matches, so a user's replacement file is never deleted.
- **Operation tokens** (`operationID`, `StartOperation`/`StopOperation`) reject late callbacks from an older attempt, and cancellation that races a resume cancels the new `WKDownload` instead of reviving the row.
- When the tab's view is gone, a resume/retry uses a throwaway `WKWebView` on the same store (no page, no extensions), kept only for that attempt.
- Progress is published on the file for Finder and the Dock's Downloads stack; Finder cancellation is handled even if WebKit sends no callback.
- **Private downloads** are tracked for cleanup and the aggregate progress circle but **never appear** in the shared panel, history or completed list; a failed private download's partial file is deleted.
- Deleting a space takes its running downloads with it (`forgetDownloads(of:)`).

When a download finishes, `Fetches.finish` tells the Dock (bounce) and drops the entry; `Browser.saved` adds a `Keep` to **Loot** and announces "Saved *name*". The toolbar circle lingers 5 s after the last one.

### `Loot`

The memory of finished downloads (`downloads.json`): name, source host, path, date — newest first, **at most 50**. "Clear" empties the list only; files are "the Finder's business".

## Favicons (`Icons.swift`)

WebKit doesn't expose favicons, so after load the page is asked (via `IconRelay` in Search's world) what icons it declares; the best is fetched once and stored as PNG in `icons/` under the site key — **host plus non-default port** (localhost:3000 ≠ localhost:5173, #413). Dark variants (`prefers-color-scheme: dark`, or icons swapped by script like GitHub's) are kept separately under `host@dark`. Absent icons are remembered so lists don't hit the disk thousands of times. A restored tab shows its icon before its page loads; a new site shows a letter until the icon arrives. Clear History removes all stored icons. Imports can seed icons from another browser's cache.

## Tests

| Test | Covers | Run |
|---|---|---|
| `Tests/HistoryRegression/` | URL identity regressions, compiling real `Address.swift` + `History.swift` with stubs in a temporary store (never the real history file) | `Tests/HistoryRegression/run.sh` |
| `Tests/SearchTests/DownloadLifecycleTests.swift` | Resume after failure keeps entry and destination; pause/resume keeps bytes; retry without resume data; deleted space cancels its download; cancel removes partial file; removing a paused download preserves a replacement file; private downloads never enter shared lists (uses `LocalDownloadServer.swift`) | `swift test` |
| `Tests/SearchTests/FetchEntryTests.swift` | Resume-data edge cases and stale-callback tokens | `swift test` |
| `Tests/bookmark_names.py`, `bookmarks_dropdown.py`, `bookmarks_menu.py` | Bookmark UI behaviour through the bench | `python3` after `./build.sh` |
