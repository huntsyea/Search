---
type: interface
title: Window chrome, design system and panels
description: The visible interface of Search — tab strip vs sidebar, folding them away (⌘S), hand-placed traffic lights with no toolbar, the page as a card, the Palette/Metrics/Motion design tokens, the shared Plate panel pieces, Settings pages, the Welcome and What's New cards, and user-customisable keyboard shortcuts with extension command keys.
tags: [ui, swiftui, design-system, sidebar, settings, shortcuts, onboarding]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-f8a0c692de846759bafa2f68
    resource: repo://Sources/Search/Design.swift
  - id: openwiki-source-2a7a537c4bc5cf796a619f55
    resource: repo://Sources/Search/Fold.swift
  - id: openwiki-source-a0cf806a60b914f016259627
    resource: repo://Sources/Search/Lights.swift
  - id: openwiki-source-96ec59fd9f20a1a7092b2822
    resource: repo://Sources/Search/Plate.swift
  - id: openwiki-source-84006d5d987b894a14994de8
    resource: repo://Sources/Search/Settings.swift
  - id: openwiki-source-376c0c01c9035fdfef6d893e
    resource: repo://Sources/Search/Shortcuts.swift
  - id: openwiki-source-be7b775551d1783aa423da10
    resource: repo://Sources/Search/Side.swift
  - id: openwiki-source-2c6655bb845f73454c0c0209
    resource: repo://Sources/Search/WhatsNew.swift
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# Window chrome, design system and panels

Search has almost no chrome: a row of tabs (across the top, or down a side) and the page. Everything else floats over the page when asked for and goes away after. The interface is SwiftUI (`ContentView` in `App.swift`) with AppKit where SwiftUI can't reach.

## The row of tabs

**Across the top — `TabBar.swift`.** "The only chrome there is": tab titles, the active one in a grey pill that **slides** from the tab left to the tab picked. The strip is `Metrics.strip` = 52 pt tall, and the window's title bar grows to match so the traffic lights sit centred in it. Tabs have a **fixed width** (`tabWidth` 186) so the close button always lands in the same place and the row never rearranges as you read. With too many tabs they narrow, below 80 pt showing only the site's mark, down to 36 pt, after which the row scrolls within its own edges and keeps the active tab in view. Pins are 30 pt squares holding a letter or icon. The empty part of the strip drags the window (`DragStrip`); the `+` appears only when the pointer is in the row. Optional back/forward/reload "helm" (`navigationLeft`) and, with Spaces, the current space and the neighbouring spaces' rows for vertical swiping.

**Down a side — `Side.swift`.** `SideBar` uses the same pieces laid out vertically: sliding grey, pinned squares (and optional pinned **rows**, as in Arc), close button on hover, group headings, speaker for noisy tabs. Default width 232, user-resizable between 176 and 440 by dragging the edge (double-click resets); left or right (`SidebarPosition`, the right side added in 1.0.4). With the column showing, the page is drawn as a **card** inset by `cardGap` 8 pt with `cardRadius` 10 corners on the window's `frame` colour (`CardEdge`). ⇧⌘S switches between strip and column.

**Folding — `Fold.swift` (⌘S).** The column (or strip) slides away so the page takes the whole window; the traffic lights go with it so they don't sit over the page's own corner content. Pushing the pointer against the edge brings it out **over** the page, and it leaves again after a short grace period once the pointer goes. Details that matter:

- Folding by hand lasts the session only, so a browser never launches with no tabs visible "for a reason set days ago" — unless Settings › Tabs says to keep the column folded (Arc's way, `sideHides`), and then the column waits for the pointer to **settle** at the edge, since a hand passing to the Dock or another display hits it often.
- A pointer flung just past the window edge still counts, if it came from inside the window.
- The strip across the top always waits for the pointer to settle, because the menu bar is right above.
- While a tab's address is being edited in its row, the column stays out.

**Traffic lights — `Lights.swift`.** The window has **no toolbar**: on macOS 26 a toolbar also rounds window corners to 31.5 pt instead of 17.5 pt. The three buttons are moved by hand to where a unified toolbar would put them, using AppKit's spacing read **once** from the first layout. Re-reading it during a resize once caught AppKit mid-update and collapsed the buttons on top of each other. When the app is inactive they are drawn as resting greys (`RestingLights`). `Metrics.lights` (100) and `sideLights` (72) keep the first tab and the column's doors clear of them.

<!-- openwiki: broken internal link [/openwiki/architecture/browser-and-tabs.md] link "/openwiki/architecture/browser-and-tabs.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
<!-- openwiki: broken internal link [/openwiki/tabs/split-view.md] link "/openwiki/tabs/split-view.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
The page itself sits in the stage (see [Browser model](/openwiki/architecture/browser-and-tabs.md)), or `PaneStage` with [Split View](/openwiki/tabs/split-view.md).

## Design tokens (`Design.swift`)

- **`Palette`.** Every colour is a light/dark **pair** that resolves against the window's appearance (`NSColor(name:)` dynamic providers in `Palette.NS`), so no other code knows which mode it's in. Greys: `ground`, `ink`, `muted`, `faint`, `hairline`, `wash` (live tab), `hover`, `pinLive`, `frame` (the ground around the card), and sidebar variants `sideWash/sideHover/sideTile/sidePinLive`, which keep the same contrast steps against `frame`. The only non-greys: `safe` (green) and `unsafe` (amber) for connection state in the site card.
- **`Look`.** Light, dark, or system, set on `NSApp.appearance` so every window, sheet and page agrees, and pages honouring `prefers-color-scheme` follow the frame. Applied on the next run-loop turn: changing it mid-animation once left a layer that took clicks and showed nothing.
- **`Metrics`.** Every fixed size above, plus `fieldWidth` 560 for the address field and `bare` 34 for the band with no strip.
- **`Motion`.** One spring for moving between places (`glide`), one for arriving/leaving (`settle`), plus `quick`. All become immediate when macOS Reduce Motion is on.
- `Logomark` draws the Search mark from path data; `Shake` is the field's "that isn't an address" shiver.

## Panels (`Plate.swift`)

Settings, History, Downloads, Passwords and Bookmarks are built from the same pieces, so they read as one kind of thing: `Plate` (rounded card with title, close cross, optional foot below a hairline), `Card`, `Rule`, `Line` (label + caption + control), `Caption`, `Hunt` (the search field), `Nothing` (empty state). A panel only says what goes in it. ⌘W and Escape close the panel in front before the tab (`Browser.closeFront`).

## Settings (`Settings.swift`, `Prefs.swift`)

<!-- openwiki: broken internal link [/openwiki/architecture/persistence.md] link "/openwiki/architecture/persistence.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
`SettingsPanel` has pages down the left and one page at a time on the right: **General, Tabs, Shortcuts, Extensions, Passwords, Downloads, Privacy, AI, About** (AI is hidden while `AI.shipped` is false). Each page is a short list of `Line`s; controls are the app's own `Switch`, `Segmented`, `Steps` and `Pill`. Every setting is a property on `Preferences`, persisted to its own defaults key (see [Persistence](/openwiki/architecture/persistence.md)).

## Welcome and What's New

<!-- openwiki: broken internal link [/openwiki/import/browser-import.md] link "/openwiki/import/browser-import.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
<!-- openwiki: broken internal link [/openwiki/integrations/macos.md] link "/openwiki/integrations/macos.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- **`WelcomePanel`** (first launch, `Welcome.swift`): four short skippable pages over the window — what this is, bringing things over (a short [import](/openwiki/import/browser-import.md)), how to hold it (layout), and whether links from other apps should come here ([default browser](/openwiki/integrations/macos.md)). Not shown to people who already had a session before it existed.
<!-- openwiki: broken internal link [/openwiki/workflows/contributing.md] link "/openwiki/workflows/contributing.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- **`WhatsNew`** (`WhatsNew.swift`): because new features start **off**, the first launch of a newer version shows a card with that version's new switches (each with a line and the switch itself) plus earlier versions' switches that are still off. Closed, it doesn't come back for that version. Never after a fresh install (Welcome covers that) or in a test world unless the bench asks. A release edits `toggles` (with `since`), `releases` and `notes`. Every version's notes live in Settings › About › What's New…. See [Contributing](/openwiki/workflows/contributing.md).

## Keyboard shortcuts (`Shortcuts.swift`, `ShortcutsPage.swift`)

Each menu command is a `Command` (`id`, title, section, default `KeyCombo`, action); menu items in `SearchApp` reference them via `.shortcut("file.newTab")`. `ShortcutStore` keeps **only the user's changes** on top of defaults, so a default changed in a later release still reaches everyone who never touched it.

- `KeyCombo` reads keys by the layout's unshifted name and the top row by position, so ⌘1–9 work on every keyboard layout; ⌘+ (⇧⌘= or a dedicated key) is normalised to "+".
- Settings › Shortcuts lists every command by section, filterable by name or key ("tab" and "⌘T" both find New Tab). Click a key and press the new one; right-click to clear or reset. Assigning a key that another command has moves it (`assign`). Split View's commands appear only when it's on.
- **Extension commands** (#189): keys from an extension's manifest are adopted when it loads (`adopt`). An extension never gets a key the Mac reserves, a browser-only key, or one a Search command currently has — as in Chrome — and then its command is left unbound for the user to set. Changing one of Search's keys can free or take an extension's, and the result is handed to WebKit (`applyExtensions`).
<!-- openwiki: broken internal link [/openwiki/architecture/overview.md] link "/openwiki/architecture/overview.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- The window's key monitor checks user-changed commands first, then extension commands, then the built-in keys (see [Architecture overview](/openwiki/architecture/overview.md)).
