---
type: testing
title: Test suites
description: Every kind of test in the repository and how to run it — the SearchTests XCTest target (swift test), standalone swiftc harnesses (test-find, HistoryRegression, extension files), Python probe tests that drive a hidden built app through the bench in their own worlds, and what is deliberately left to hand checks on a release candidate.
tags: [testing, xctest, harness, python, probes, qa]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-16a6a536c0a5303df5e05c6c
    resource: repo://Package.swift
  - id: openwiki-source-23775c3de52f3ab95a13cb8b
    resource: repo://README.md
  - id: openwiki-source-2d129081a33bcee8ef790401
    resource: repo://test-find
  - id: openwiki-source-7640b7721db645be0755e4fc
    resource: repo://Tests/arc_pins.py
  - id: openwiki-source-7f7a48db30537642e622c56a
    resource: repo://Tests/HistoryRegression/README.md
  - id: openwiki-source-ef7775ccb2b4dbf18dc4c9d0
    resource: repo://Tests/HistoryRegression/run.sh
  - id: openwiki-source-f08d9263893be896036e5db8
    resource: repo://Tests/live_rate.py
  - id: openwiki-source-b9f553120d42102412524c0e
    resource: repo://Tests/run-extension-files-tests.sh
  - id: openwiki-source-6b5661225021f2d716c6def8
    resource: repo://Tests/SearchTests/DownloadLifecycleTests.swift
  - id: openwiki-source-57b978cfff7c4ea9a27612ea
    resource: repo://Tests/SearchTests/ExtensionPopupWindowTests.swift
  - id: openwiki-source-1bd0c0af0ffcb61525e1ef45
    resource: repo://Tests/SearchTests/LocalDownloadServer.swift
  - id: openwiki-source-73c6f018b9cc3b29eb9e640e
    resource: repo://Tests/split_view.py
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# Test suites

Search's tests are built around one rule: **a test never touches the browser somebody is using, and never shows a window.** There are four kinds:

| Kind | Where | How to run | Needs |
|---|---|---|---|
| XCTest unit/model tests | `Tests/SearchTests/` | `swift test` | Swift toolchain |
| Standalone harnesses | `test-find`, `Tests/HistoryRegression/run.sh`, `Tests/run-extension-files-tests.sh` | run the script | `swiftc` / `xcrun` |
| Python probe tests | `Tests/*.py` | `./build.sh` first, then `python3 Tests/<name>.py` | built `build/Search.app` |
| Hand checks | release candidate | by eye | — |

## XCTest: `Tests/SearchTests/`

Declared in `Package.swift` as `SearchTests` (depends on `Search`, Swift 5 mode); tests use `@testable import Search`. Since `swift test` runs from `.build/`, everything is a test run (separate folder, defaults and stores). Tests that need AppKit set `SEARCH_PROBE` to a per-process world, use `.prohibited` activation policy, and assert in `tearDown` that **no window became visible and the app never activated**.

| File | Covers |
|---|---|
<!-- openwiki: broken internal link [/openwiki/operations/self-update.md] link "/openwiki/operations/self-update.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| `VaultAndUpdaterTests` (17) | Login host rules, registrable domains, password CSV parsing (never touches the keychain), release minimum-OS checks, rejecting garbage and **unsigned feeds** ([self-update](/openwiki/operations/self-update.md)) |
<!-- openwiki: broken internal link [/openwiki/import/browser-import.md] link "/openwiki/import/browser-import.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| `ImportFileTests` (12) | Netscape parser, folder/ZIP reading, progress throttling, cancellation, CSV progress never containing contents, bookmark merge and **Replace** safety, Arc import, Safari ZIP detection ([import](/openwiki/import/browser-import.md)) |
| `DownloadLifecycleTests` (7) + `LocalDownloadServer` | Real `WKDownload`s against a loopback server: resume after failure, pause/resume, retry, cancel cleanup, replacement-file safety, deleted space cancels its download, private downloads stay out of shared lists |
| `FetchEntryTests` (4) | Download row state machine and stale-callback tokens |
<!-- openwiki: broken internal link [/openwiki/extensions/installation.md] link "/openwiki/extensions/installation.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| `UnpackedIDTests` (6), `ExtensionFolderLinkTests`, `ExtensionWorkerLinkTests`, `ExtensionFileAccessTests` | Unpacked extension ids from real paths, symlink policy, `file:` never granted ([installation](/openwiki/extensions/installation.md)) |
<!-- openwiki: broken internal link [/openwiki/extensions/chrome-api-shims.md] link "/openwiki/extensions/chrome-api-shims.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| `ExtensionPortTests`, `ExtensionScriptingTests`, `ExtensionDownloadPageTests`, `ExtensionPopupWindowTests` | Shim messaging numbering, forwarded functions, extension downloads never via private tabs, popup windows never saved ([shims](/openwiki/extensions/chrome-api-shims.md)) |
| `FindStageTests` | The find bar follows the focused Split View pane |
| `PinCarriedTests` | A dragged pin square's landing cell |

Extension tests are `@available(macOS 15.4, *)`.

## Standalone harnesses

Each compiles a few real source files with a test `main` into a temp dir, runs it, and deletes it — fast, and independent of the app target.

<!-- openwiki: broken internal link [/openwiki/page/page-tools.md] link "/openwiki/page/page-tools.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- **`./test-find`** — `Sources/Search/PageFind.swift` + `Tests/PageFindHarness.swift` (`xcrun swiftc -parse-as-library`): match counting and navigation, case/whole-word, Unicode folding, accents, hidden text, iframes, selection cleanup ([page tools](/openwiki/page/page-tools.md)).
- **`Tests/HistoryRegression/run.sh`** — real `Address.swift` + `History.swift` with `Stubs.swift`, against a fresh temporary store (`SEARCH_HISTORY_TEST_ROOT`); never reads the real history file.
- **`Tests/run-extension-files-tests.sh`** — `ExtensionFiles.swift` + `Tests/ExtensionFilesTests.swift`: atomic `renamex_np` install/swap, cleanup, immutable-file failures.

## Python probe tests: `Tests/*.py`

<!-- openwiki: broken internal link [/openwiki/testing/bench-and-test-worlds.md] link "/openwiki/testing/bench-and-test-worlds.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
Each starts the built `build/Search.app` **hidden in a world of its own**, drives it through the [bench](/openwiki/testing/bench-and-test-worlds.md) socket (`./bench`'s protocol), checks results through the app's own model, then quits and **removes the world's settings and files**. None makes, shows or raises a window. Most reuse the harness in `Tests/split_view.py` (`import split_view as sv; sv.use("<world>")`), which picks a per-checkout world, writes prefs, launches, guards against stray processes, and wipes afterwards.

| Area | Tests |
|---|---|
| Tabs and layout | `split_view.py` (the main suite), `pin_tiers.py`, `tab_switcher.py`, `close_group.py`, `close_panel.py`, `fresh_window.py`, `full_screen_chrome.py`, `fullscreen_card.py` |
| Import | `arc_pins.py`, `arc_folders.py`, `arc_icons.py`, `arc_rows.py` |
| Bookmarks and menus | `bookmark_names.py`, `bookmarks_dropdown.py`, `bookmarks_menu.py`, `link_menu.py`, `dialog_keys.py` |
| Passwords | `password_only.py`, `password_only_mixed.py`, `identifier_first.py` (local pages, this world's own keychain items, cleaned up) |
| Page features | `site_search.py` (reaches duckduckgo.com and search.brave.com for OpenSearch), `text_replacement.py`, `float_video.py`, `recording_pill.py` |
| Pure script | `live_rate.py` — runs `LiveRate.script` in JavaScriptCore via `osascript`; no app needed |

Local pages are served by small Python HTTP servers on 127.0.0.1 inside each test.

## Hand checks on a release candidate

The tests explicitly leave to a person what can only be seen: dragging a tab onto a page's edge, the divider under the pointer and its motion (Split View), the account list's look under the field, pinned rows and the Clear line, the floating window itself, and Escape cancelling a sheet (which needs a key window a hidden probe never has).

## Before a pull request

<!-- openwiki: broken internal link [/openwiki/workflows/contributing.md] link "/openwiki/workflows/contributing.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
[CONTRIBUTING.md](/openwiki/workflows/contributing.md) asks for `swift build` with **no new warnings**. Run the suites relevant to the change (`swift test`, the matching harness or probe), and drive the change in a test world with `./bench --test`.
