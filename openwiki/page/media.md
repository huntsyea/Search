---
type: feature subsystem
title: "Video and audio: floating video, live rate, frame rate"
description: How Search handles media in pages — the floating video (moving the whole web view into an always-on-top panel instead of system picture-in-picture), when videos float on their own, the Isolate script, LiveRate's fix for live-stream stutter, 120 Hz pages via a WebKit feature flag, and per-tab sound (AudioWatch, mute, autoplay).
tags: [video, audio, picture-in-picture, webkit, media, performance]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-50d9705ad83befb6a5230076
    resource: repo://Sources/Search/Browser.swift
  - id: openwiki-source-e24182c97191f68e5cdcf1b4
    resource: repo://Sources/Search/Float.swift
  - id: openwiki-source-0eda526931747072f48f3038
    resource: repo://Sources/Search/FrameRate.swift
  - id: openwiki-source-5c6db38d9754ad0c581eca46
    resource: repo://Sources/Search/LiveRate.swift
  - id: openwiki-source-fc9b78c55ddd3ec773fb0af8
    resource: repo://Sources/Search/Prefs.swift
  - id: openwiki-source-6e6b2e557229ef129b26e320
    resource: repo://Sources/Search/Tab.swift
  - id: openwiki-source-350737765a83d41b12ef1a11
    resource: repo://Tests/float_video.py
  - id: openwiki-source-f08d9263893be896036e5db8
    resource: repo://Tests/live_rate.py
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# Video and audio: floating video, live rate, frame rate

## Floating video (`Float.swift`)

**Why it isn't system PiP.** WebKit only hands a video to macOS picture-in-picture after a **real click on the page**, and nothing the app does counts as one (Chromium is looser). So Search doesn't ask the engine at all. It **moves the page**: everything but the video is made invisible, the video is stretched to fill the viewport, and the **whole web view** is lifted out of the browser window into a small floating panel. The video never stops, because it is the same page in a different window.

There is exactly **one** floating video for the app (`Shared.floater`), tracked by `Browser.floating` (tab id) and `Tab.floating`, which are checked against each other.

### Lifting and landing (`Browser.lift` / `land`)

`lift` refuses when the tab is blank or asleep, a float is already showing, or the video is in **WebKit fullscreen** (moving a page out of WebKit's fullscreen window left that window black). It then runs `Isolate.on` in Search's content world. The script hides the body via inherited `visibility` and turns it back on only for the video — the player's machinery keeps running, whereas cutting up the DOM would kill the stream. It handles players that centre with transforms (Netflix), timed-text layers, ancestors that create containing blocks (transform/filter/containment), lazy rendering and fades. Only if it answers `"floating"` does `Float.lift(tab.web)` move the view. With Split View, the other pane's page is tried if the focused one has nothing playing.

<!-- openwiki: broken internal link [/openwiki/architecture/browser-and-tabs.md] link "/openwiki/architecture/browser-and-tabs.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
`land()` puts the page back. The stage takes it on its next layout, which is what `StageView`'s single-`wanted` design is for (see [tabs](/openwiki/architecture/browser-and-tabs.md)). The panel always closes, whatever else is true. Selecting the floating tab lands it first; closing it lands it too.

### When it happens

| Trigger | Setting | Default |
|---|---|---|
| **⇧⌘P** (`toggleFloat`) — from any site | — | always |
| Switching to another tab while a video plays (`leaving`) | `float.leave` (Settings › General) | **on** |
| Another app comes to the front (`appLeft`); lands again when Search returns (`appBack`) if lifted that way | `float.away` | off |

Automatic floats (`quietly`) happen **only on known video sites** (`Players.knows`: YouTube, Netflix, Prime Video, Disney+, Apple TV, Twitch, Vimeo, Max, Arte, Crunchyroll, …, with path rules for shops that also stream). A playing video elsewhere is as likely a background as a film. A site can be **grounded** from its site card ("Don't Float Videos Here", #267, `Grounded`, per host; ⇧⌘P still works there).

### The panel

An `NSPanel`, borderless, resizable, **non-activating**, at `.floating` level, on all Spaces and over fullscreen apps (`.canJoinAllSpaces, .fullScreenAuxiliary`), movable by its background, 440×247 by default at the bottom-right, then where it was last. It has **no shadow**: a shadowed window is composited by WindowServer every frame (measured: 28% GPU vs 16–20% without, on 1080p/4K YouTube). A `Panel` subclass can become key without activating the app, so gestures still reach it. Controls: return to the tab, play/pause, skip ±, and a progress line polled every half second.

Trackpad behaviour: with **flicks** (`float.flicks`, on by default for people who never set it), a two-finger flick sends the panel to the corner it points at (diagonal between ~22° and 68°), otherwise against the nearer edge (`Float.corner`). It can be **docked** off a screen edge leaving a 10 pt sliver, but not onto an edge where another display continues (`dockable`).

The bench opens it off-screen (`benchAway`, `benchScreens`) and never shows it in a hidden probe.

## Live streams without stutter (`LiveRate.swift`)

Live players keep up with the broadcast by nudging `playbackRate` (X's goes to 1.04 and back to 1 every few seconds). In WebKit on macOS, every step **across exactly 1.0** tears down and rebuilds audio on CoreMedia's special speed-1 path, freezing the picture ~50 ms — a visible jump every few seconds, Safari included.

`LiveRate.script` is injected **in the page's own world at document start, in every frame** (it has to wrap the `playbackRate` property players use). Once a page has used a catch-up rate on a video (within a small band off 1), a later request for `1` is applied as **1.0001**, which nobody can hear or see, while the page still reads back `1`. Speeds chosen from a menu (1.25, 1.5, 2) never start it, and pages that never nudge are never touched. If the rate was changed some other way since (native controls, an extension), the current value wins, and invalid values throw as WebKit would. Measured: 11 stalls in 26 s before, 1 after.

## Pages at 120 Hz (`FrameRate.swift`)

WebKit holds page animations and its own scrolling to ~60 fps even on 120 Hz displays (Safari's default, and cheaper: one CSS animation cost about 50% more energy at 120). Settings › General › **Pages at 120 Hz** (`pages.120`, off by default) clears WebKit's "prefer near 60" **feature flag** (from the private feature-flag list, looked up once and guarded) in each page's preferences, applied in `Tab.build()` before the view exists, since WebKit reads it then. Turning it off undoes only the preferences this changed. Already-open tabs follow after a reload or sleep/wake; Search doesn't reload them, so nothing typed is lost. Off, the flag is never touched.

## Sound per tab

- **`AudioWatch`** observes WebKit's private `_isPlayingAudio` via KVO (if present) and sets `Tab.noisy`, which shows a speaker in the row and keeps the tab awake.
- **Mute** (`Muter`, the speaker or tab menu) toggles the page bit of `_mediaMutedState` with `_setPageMuted:`, so the page keeps playing silently and camera/mic mute bits are left alone. A sleeping tab is muted without waking and re-muted when rebuilt.
- **Autoplay**: by default sound needs a click (`mediaTypesRequiringUserActionForPlayback = .audio`); Settings › General › **Videos wait for a click** (`waitsForPlay`, 1.0.4) makes all media wait. A site can be allowed to autoplay from its site card (`Autoplay`, per host via private `_setAutoplayPolicy:`; never from private tabs; overridden by "videos wait"). An already-built view keeps its playback policy until it sleeps or closes (`playbackChanged`).

<!-- openwiki: broken internal link [/openwiki/architecture/browser-and-tabs.md] link "/openwiki/architecture/browser-and-tabs.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
Details of the private-API guards are in [Browser model, tabs and web views](/openwiki/architecture/browser-and-tabs.md).

## Tests

- `Tests/float_video.py` (after `./build.sh`) runs the `Isolate` script on local pages whose videos sit under awkward ancestors (transforms, filters, containment, off-screen rendering, fades) in a hidden probe — the floating window is never opened — and checks the video fills the view and is visible.
- `Tests/live_rate.py` runs `LiveRate.script` in JavaScriptCore (`osascript`) against a stand-in element whose `playbackRate` behaves like WebKit's. No page is opened; the pause itself was measured by hand.
