# Files

- [Browser model, tabs and web views](browser-and-tabs.md) - How a window's Browser object owns its tabs and acts as WebKit's navigation, UI and download delegate, and how each Tab lazily builds its WKWebView (PageView) with Search's own content world, relays, sleep/wake, crash recovery, mute and autoplay.
- [Architecture overview](overview.md) - How Search is assembled as one SwiftPM executable — the SwiftUI app and its single scene, one Browser per window plus AppKit-made extra windows, shared cross-window state, the SwiftUI/AppKit/WebKit split, the key monitor, and the path from typing in the field to a page on screen.
- [Persistence and the Store](persistence.md) - Where Search keeps its data — the Application Support folder and its JSON files, the Disk serial writer, quarantine of unreadable files, UserDefaults settings via Preferences, session and pins files, per-space WebKit stores — and how test worlds (SEARCH_PROBE) are kept completely apart from the real browser.
