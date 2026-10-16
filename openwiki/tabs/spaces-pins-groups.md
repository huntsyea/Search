---
type: feature subsystem
title: Spaces, pins, tab groups and the tab switcher
description: How Search organises tabs — Spaces (separate rows and optionally separate WebKit data stores, parked rows, deletion), pins (letters, squares and rows, put down by ⌘W, shared across windows via pins.json), tab groups (Chrome-numbered, collapsible, ordering invariant), dragging tabs between rows, spaces and windows, the ⌃Tab switcher, and space swiping — with persistence and tests.
tags: [tabs, spaces, pins, tab-groups, switcher, gestures, session]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-50d9705ad83befb6a5230076
    resource: repo://Sources/Search/Browser.swift
  - id: openwiki-source-b7b01e0296b054b7f8ddcb53
    resource: repo://Sources/Search/Pins.swift
  - id: openwiki-source-e329201dd1541697e6c26a79
    resource: repo://Sources/Search/Sleep.swift
  - id: openwiki-source-d8690cd873e110911612abf9
    resource: repo://Sources/Search/Spaces.swift
  - id: openwiki-source-067e60d11728b11792d12c8a
    resource: repo://Sources/Search/SpaceSwipe.swift
  - id: openwiki-source-f85d70046437c27980a8cae4
    resource: repo://Sources/Search/TabGroup.swift
  - id: openwiki-source-ffbfe7e942a00ad36d7b600b
    resource: repo://Sources/Search/TabSwitcher.swift
  - id: openwiki-source-ea73e6444bef1bb437f7592b
    resource: repo://Tests/pin_tiers.py
  - id: openwiki-source-58af88d7d1fe544c5957ddb6
    resource: repo://Tests/tab_switcher.py
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# Spaces, pins, tab groups and the tab switcher

<!-- openwiki: broken internal link [/openwiki/architecture/browser-and-tabs.md] link "/openwiki/architecture/browser-and-tabs.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
<!-- openwiki: broken internal link [/openwiki/architecture/persistence.md] link "/openwiki/architecture/persistence.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
All of these build on `Browser.tabs` (one row per window per space) and `Tab` (see [Browser model](/openwiki/architecture/browser-and-tabs.md)), and persist through `Session`/`pins.json`/`spaces.json` (see [Persistence](/openwiki/architecture/persistence.md)). Most are **off until turned on** in Settings › Tabs.

## Spaces (`Spaces.swift`, `SpaceSwipe.swift`)

Separate sets of tabs in one window (Arc's spaces), off by default (`spaces`). Until turned on there is one space — the first, `Space.firstID` (`00000000-…-0001`, named "Personal") — and nothing about it shows. Its tabs are the session that always existed and its sites use the store that always existed, so **turning spaces on signs nobody out**.

- A `Space` has `id`, `name`, `icon` (one of `Spaces.icons`, SF Symbols in one grey; an older `colour` index still reads), `sharesSignIns`, and an optional `downloads` folder.
- **Cookies and sign-ins**: a new space by default **shares** the first space's store (`sharesSignIns: true`), so only its tabs are its own. Or it starts afresh with its own `WKWebsiteDataStore(forIdentifier: spaceID)` (`Spaces.store(for:)`). History, bookmarks, keychain passwords, settings and extensions are shared by every space.
- **Switching** (⌃1–⌃9, the space dot's menu, or swiping) parks the current row as it is (`Parked`), **sound and all**: music keeps playing in the space you left (⇧⌘M or its speaker stops it). Parked tabs sleep after half an hour like any tab (`parkedTabs` are included in the sleep timer). Each window shows one space of its own choosing; `Spaces.current` follows the key window, and new pages open there.
- `preloadSpaces()` builds the neighbouring spaces' rows ahead of time, so the column can show the next space sliding in.
- **Deleting** a space (never the first) closes its tabs in every window, cancels its downloads, empties its store at once and again a moment later (for what closing tabs were still writing), and removes the store itself. WebKit won't remove a store while the process holds it, so the id is recorded and `Spaces.sweep()` retries at the next launch. Its session file and pins go too.
- **Swiping** (`SpaceSwipe`): in the column, two fingers sideways page through spaces with the rows following (as in Arc); in the bar across the top, up/down, or one mouse-wheel notch at a time. A gesture is only taken if it **starts over the tabs** and sets off clearly along the spaces' axis, and must travel 50 pt in the column or most of the 52 pt bar. After a space arrives, the rest of that hand movement (glide included) is ignored. Swiping past the last space offers a new one in place (`NewSpaceCard`).

## Pins (`Browser` pinning section, `Pins.swift`)

A pinned tab gives up its title for **one letter** (or the site icon, per Settings › Tabs wear) and keeps its place at the head of the row.

- **Pinning is instant**: the letter is guessed from the address and arrives selected, so the next keystroke replaces it — no dialog (`pin`, `editLetter`). Private tabs and bench tabs can't be pins.
- Pins sit first, in the order pinned, so their letters never move under your hand. With **Pinned rows** (Settings › Tabs, `pins.list`, 1.0.5, #183) a pin can be a **row** with its name under the squares (Arc's pinned list). Rows are drawn as squares when the setting is off or tabs are across the top. Converting moves it to the nearer end of its new kind.
- **⌘W puts a pin down** rather than closing it: its page is released, its letter and address kept (`Tab.rest`). Selecting it loads it again. Only Unpin removes it. A double-click on a pin goes back to `home`, the page it was pinned at (`goHome`).
- **Shared across windows**, per space: what makes a pin a pin (`PinDef`: id, letter, home, title, name, listed) is kept in `pins.json` (`Pins`). Each window holds **its own `Tab`** per pin, its own page wherever you navigated. Changing pins in one window calls `Pins.set`, which saves and posts `SearchPinsChanged`; other windows run `reconcilePins` to follow. The oldest window's session also keeps pins so 1.0.3 can still read them.
- Pins are never put to sleep by the timer (they're put down by hand instead).

## Tab groups (`TabGroup.swift`, `TabGroups.swift`, `Browser`)

Named, collapsible sections of ordinary tabs (Settings › Tabs, `tabs.groups`, off by default, 1.0.4). Right-click a tab to start one.

- `TabGroup` is `{id, name, collapsed}` per space; membership is each tab's own `groupID`. Pins are never in a group.
- **Ordering invariant**: with groups on, every change to `tabs` ends with `arrangeGroupedTabs()` putting the row back in display order, so ⌘1–9, ⌃Tab and extension tab indexes always agree with what's drawn. A tab opened from a grouped tab (link, peek kept, ⌘-click) joins that group.
- A group with no tabs left disappears (`removeEmptyGroup`). Selecting a tab in a collapsed group opens the group.
- Groups and members are written in the session **whether or not groups are on**, so turning them off loses nothing; while off, nothing acts on them.
- Extensions see groups through the shimmed `chrome.tabGroups`, with a stable Chrome-style number derived from the UUID (`TabGroup.number`), colour always grey, and none while groups are off.
- Group headings publish their frames (`GroupDropFrames`), so the existing reorder drag can drop a tab onto a group without a second gesture.

## Dragging tabs (`TabDrag.swift`, `TabBar`/`Side`)

<!-- openwiki: broken internal link [/openwiki/tabs/split-view.md] link "/openwiki/tabs/split-view.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
One drag gesture per tab handles reordering within the row, dropping onto a group heading, onto the edge of a page to make a **Split View** pair (`SplitDropZone` markers report what's under the pointer and never receive events themselves, see [Split View](/openwiki/tabs/split-view.md)), onto another space, into another window (`moveToWindow`), or out of the window to become a new window (`dragOut`). Moving a tab to another space whose store differs rebuilds its view with that store (`Tab.rehome`), keeping its history state.

## The ⌃Tab switcher (`TabSwitcher.swift`)

With Settings › Tabs' switcher on, **⌃Tab** shows the current space's tabs as **pictures**: the one you're on first, then the ones you last left, most recent first. **One gesture's order is fixed until ⌃ is released**, so walking it doesn't rearrange it. ⌃ and the arrows move; releasing ⌃ switches; any other key dismisses. A Split View pair is one card with both pages side by side.

- `left(_:alive:)` records the tab just left with a snapshot; only the **ten** latest keep a picture; closed tabs fall out. Order is kept per space.
- Pointer support (#358): a card under the pointer is picked only **after the pointer moves**, so a card landing under a still pointer doesn't steal the pick from the keys. Clicks are routed through the window's event monitor (`clickTabSwitcher`).
- Without the switcher (or with something over the page), ⌃Tab / ⌃⇧Tab walk the row.

<!-- openwiki: broken internal link [/openwiki/navigation/address-field.md] link "/openwiki/navigation/address-field.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
⌘K, the field's open-tab switcher, is described in [Address field](/openwiki/navigation/address-field.md).

## Tests

- `Tests/pin_tiers.py` — pinned squares and rows and the line's Clear, through the bench in a hidden probe (visuals checked by hand).
- `Tests/tab_switcher.py` — ⌃Tab pressed and a click sent through the app's event monitor in a hidden probe.
- `Tests/close_group.py`, `Tests/arc_pins.py`, `Tests/arc_rows.py` — closing groups; Arc pins/rows import.
- `Tests/SearchTests/PinCarriedTests.swift` — the dragged-pin view modifier.
- `Tests/SearchTests/DownloadLifecycleTests.swift` — deleting a space takes its running download with it.
