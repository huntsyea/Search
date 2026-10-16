---
type: feature subsystem
title: Split View
description: Two pages side by side (1.0.5, off by default) — the TabSplit model and its invariants, pairing rules (pins, private, bench), the never-rebuilt PaneStage AppKit stage with per-page StageViews, the divider (snap, narrowest page, gutter), focus and keys, SplitStage overlays and per-pane questions, the split tab item in the row, drag-to-edge drop zones, session persistence, and the split_view.py probe suite.
tags: [split-view, tabs, appkit, layout, session, ui]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-50d9705ad83befb6a5230076
    resource: repo://Sources/Search/Browser.swift
  - id: openwiki-source-5c328fc416f764bd7eaa4627
    resource: repo://Sources/Search/PaneStage.swift
  - id: openwiki-source-255fce787b60cc4317727a81
    resource: repo://Sources/Search/Split.swift
  - id: openwiki-source-66d19da6b30f3ac257b40199
    resource: repo://Sources/Search/SplitTabItem.swift
  - id: openwiki-source-e72ed2764ec768056acfcee2
    resource: repo://Sources/Search/SplitView.swift
  - id: openwiki-source-26d504ddef9f7c7e2ecd12b9
    resource: repo://Sources/Search/TabDrag.swift
  - id: openwiki-source-73c6f018b9cc3b29eb9e640e
    resource: repo://Tests/split_view.py
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# Split View

Two tabs shown side by side, sharing one place in the row. New in 1.0.5 and **off until turned on** in Settings › Tabs (`splitView`). Turn it on, then drag a tab to the edge of a page, choose Tabs › Split Current Page (⌥⌘N), or a tab's menu › Open in Split View.

## Model (`Split.swift`)

`TabSplit` is `{id, tabs: [Tab.ID], axis, sizes: [Double], focused}`. In 1.0.5 a pair is always two tabs, horizontal. The shape is a list with an axis so that a vertical layout or a third page needs no new file format later.

- `tabs[0]` (`left`) is the pair's **place in the row**; the others follow it. `Browser.displayedTabs` hides the later pages, and `visibleTabIDs` is the pair when it's active.
- `sizes` add up to 1; `clamp` keeps each page between **20% and 80%** for two pages and normalises otherwise. `fraction` is the first page's share.
- `focused` is the page last focused, to return to when the pair is selected again. Moving focus within a pair isn't "leaving" it.

`Browser.splits` holds the pairs of the current row. **Turned off, pairs are kept** (like groups) and nothing acts on them until it's on again (`split(for:)`, `activeSplit` check the setting).

## Making and breaking pairs (`Browser` "tabs" section)

- `canSplit`: setting on, two different tabs in this row, neither a bench tab, **both private or both not**.
- **Pins** never go into a pair (Zen's rule). The pin keeps its place among the pins in every window, but **its page** goes in as a new tab beside the other page (`splittable`).
- `Browser.holds(pair, in:)` checks a pair can still stand in a row: all its tabs present, adjacent and in order, none pinned or bench, same private-ness and same group. Pairs kept while the setting was off may have come apart.
- `startSplit()` (⌥⌘N): pairs the current page with a **new blank tab** (same space store, or the same private store) and focuses the field in it. Picking an open tab from the blank page's list `fill`s the pair with it.
- `pair(_:with:onLeft:)` from drags; `openInSplit`, `swapSplit` (Swap Pages), `evenSplit` (Even Out or double-click the divider), `closeSplit` (Close Both), `detachSplit` / Tabs › Separate Split Tabs.
- **⌘W** closes the focused tab and gives the other page the whole area. `select` on the other page of the active pair just moves focus (`focusPane`). ⌃⌘← / ⌃⌘→ move between pages. The window's key monitor takes these ahead of WebKit's arrow handling, since panes stay native first responders.
- `activateForExtension`: an extension asking for a tab already on screen in the pair **doesn't move the keys**, so an extension can't redirect typing from one page to the other.
<!-- openwiki: broken internal link [/openwiki/page/page-tools.md] link "/openwiki/page/page-tools.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- A peek can be kept **beside** its source as a pair (⌥⌘Return, see [Page tools](/openwiki/page/page-tools.md)).

## The stage (`PaneStage.swift`, `SplitView.swift`)

<!-- openwiki: broken internal link [/openwiki/architecture/browser-and-tabs.md] link "/openwiki/architecture/browser-and-tabs.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
With the setting on, the window's page area is `SplitStage` (SwiftUI) around `PaneStageView` → **`PaneStage`**, one AppKit view that holds every page on screen, one or two, and is **never rebuilt** — not between tabs, not from one page to two. Each page keeps its own `StageView` (see [Browser model](/openwiki/architecture/browser-and-tabs.md)), so the single-`wanted` self-healing still holds. With the setting off none of this exists.

- **Layout**: a gutter of 7 pt between pages (room for the divider and the left page's scroll bar). If the window is too narrow for both pages to be at least **250 pt**, the pair shows the **focused page alone** until there's room, and stays a pair.
- **Divider** (`PaneDivider`): a hairline that grows under the pointer. While dragged, the stage lays the pages out itself and **publishes nothing** (no redraws of the window, row or menus); the pair is told once, on mouse-up (`setSplitFraction`). It snaps to even within 15 pt and lets go past 20 pt. Double-click evens it; it has a menu (Swap, Even Out, Close Both) and VoiceOver steps. It never takes the keyboard.
- **Focus**: the page that gets keys has a mid-grey hairline (`FocusCue`, drawn so screenshots include it). A click in the other page gives it focus and still reaches the page (watched, not intercepted).
- With the tabs down the side, **each page is its own card** with its own edge and shadow (layers of the stage, never the page's), and the window ground in the gutter.
- Pictures stand in for pages while they move between slots; out-of-date pictures are discarded.
- A page in WebKit fullscreen keeps the stage.
- The find bar is owned by the stage so it stays above WebKit and follows the focused page.

<!-- openwiki: broken internal link [/openwiki/page/permissions-and-dialogs.md] link "/openwiki/page/permissions-and-dialogs.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
`SplitStage` draws, over each page at the frames the stage reports, what SwiftUI normally draws over a page: its cover picture, its failure message (`Trouble`), the address field (a blank pane shows its own field; `ContentView` doesn't draw a second one), and **questions from that page alone** (`PaneQuestionCard`, see [Page dialogs](/openwiki/page/permissions-and-dialogs.md)).

## In the row (`SplitTabItem.swift`)

A pair has one place in the row:

- **In the column**: two lines, one under the other, joined by a hairline (halves side by side in 232 pt would cut titles to a dozen letters).
- **Across the top**: side by side, with a **single** close button at the end for the half under the pointer (two crosses side by side are two chances to close the wrong page).
- The focused page wears the live grey, which glides between halves as it does between tabs.

<!-- openwiki: broken internal link [/openwiki/tabs/spaces-pins-groups.md] link "/openwiki/tabs/spaces-pins-groups.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
The ⌃Tab switcher shows a pair as one card with both pages ([switcher](/openwiki/tabs/spaces-pins-groups.md)). Leaving a pair records it once, under its first page.

## Dragging onto a page (`TabDrag.swift`)

A tab's existing drag gesture asks passive `SplitDropZone` markers what is under the pointer; they never receive mouse events or start a second drag session. Only the stage observes the `preview` (which half the tab would take, named), so the row stays still while the pointer crosses the page. Markers are weakly kept and checked in the source window before becoming targets. Dropping on a page's edge pairs the tab on that side.

## Persistence

<!-- openwiki: broken internal link [/openwiki/architecture/persistence.md] link "/openwiki/architecture/persistence.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
Pairs are saved in each row's session as `Session.Split` (`tabs` as **indices** into the row, so restored tabs can get new identities; `axis`, `sizes`, `focused`), written **whether or not** Split View is on. Decoding is lenient: an unknown axis reads as side by side, and the earliest on-main format (`left`/`right`/`fraction`) still reads (see [Persistence](/openwiki/architecture/persistence.md)). Pairs and widths come back with their space, including after a restart. While a pair is active, both pages count as on screen and don't sleep.

## Tests

<!-- openwiki: broken internal link [/openwiki/testing/test-suites.md] link "/openwiki/testing/test-suites.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
`python3 Tests/split_view.py` (after `./build.sh`) runs the app **hidden** in its own world (`SEARCH_PROBE=split-tests-<checkout>`), drives it through the bench's socket (`./bench split …`), and removes its settings and files afterwards. It never makes or shows a window. Cases: pairs, the file, off keeps pairs; old files, pins, groups; the stage and divider; the row; in and out; with the rest; questions over one page; moving between windows/spaces; a peek kept beside. What can only be seen — dragging onto an edge, the divider under the pointer, the motion — is **checked by hand on a release candidate**. Its harness (`use()`, `cmd()`) is reused by other probe tests (see [Test suites](/openwiki/testing/test-suites.md)).
