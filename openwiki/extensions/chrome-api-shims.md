---
type: subsystem
title: Chrome API shims
description: How ExtensionShims rewrites each installed extension to inject search-shim.js, which defines Chrome APIs WebKit lacks (bookmarks, history, downloads, sidePanel, offscreen, userScripts, identity, tabGroups…) as native messages answered by Search, gated by the extension's manifest, and mends WebKit/Chrome behaviour differences in messaging and workers.
tags: [extensions, shim, chrome-api, javascript, native-messaging, oauth, security]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-faa5d04ea4ac6f560c72c945
    resource: repo://Sources/Search/ExtensionShims.swift
  - id: openwiki-source-bdb9e7be59496551cf0a03c1
    resource: repo://Tests/SearchTests/ExtensionWorkerLinkTests.swift
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# Chrome API shims

Safari's extension engine covers tabs, storage, scripting, declarative net request, cookies, menus, alarms and messaging. Chrome extensions also use bookmarks, history, downloads, the side panel, offscreen documents, tab groups, OAuth and more — and break when those are `undefined`. `Sources/Search/ExtensionShims.swift` (~4,400 lines, most of it one JavaScript string) fills those in.

## Two halves

1. **At install/load** — `ExtensionShims.prepare(folder)` rewrites the unpacked extension so a script, `search-shim.js`, runs first in its background and every page it ships.
2. **At runtime** — the script defines missing `chrome.*` namespaces whose methods send `runtime.sendNativeMessage("search", {api, args})`. WebKit hands that to `Extensions`' controller delegate, which calls `ExtensionShims.answer(_:from:owner:)`; it runs the API in Swift against the browser's own bookmarks, history, downloads, tabs and settings and replies `{value}` or `{error}`.

Everything the shim defines is defined **only if missing** (`if (chrome[name]) return;`), so if WebKit implements an API later, WebKit's version wins.

## `prepare`: rewriting the package

Run on install, update, reload, and each launch (skipped when the folder's `.search-shim` stamp equals the current `version`, a hash of the shim script, the passkey page script and a `preparation` counter; test builds add `-test`). For a **fresh** package, any `.search-shim` / `.search-added` files that came inside it are deleted first — those names are Search's to write.

What it changes, only by adding:

<!-- openwiki: broken internal link [/openwiki/passwords/passkeys.md] link "/openwiki/passwords/passkeys.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- Writes `search-shim.js` and `search-passkeys.js` (the passkey patch, see [Passkeys](/openwiki/passwords/passkeys.md)) into the folder.
- Adds `nativeMessaging` to `permissions` (how the shim reaches Search), and `scripting` if the extension uses `userScripts`. What it added is recorded in `.search-added`, so permission prompts describe only what the extension itself asked for.
- **Background**: a classic `service_worker` gets the shim text inlined at the top between a start `marker` and an `ender` comment (old copies are stripped and replaced); a module worker gets `import "/search-shim.js";` first; `background.scripts` gets the file prepended.
- **Content scripts** get the shim first; content scripts in the page's `MAIN` world also get the passkey patch first, so password managers capture Search's `navigator.credentials`.
- **Every HTML page** in the package gets `<script src="/search-shim.js">` right after `<head>`.

<!-- openwiki: broken internal link [/openwiki/extensions/installation.md] link "/openwiki/extensions/installation.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
Path safety: worker paths are resolved with `inside(_:of:)`, which rejects `..` escapes and symlinks (a symlinked worker would otherwise be written through, copying an outside file's bytes into the package). A worker that is a symlink to another file **inside** the package is replaced by a copy so it can carry the shim (`unlink`); one pointing outside is left alone. Store packages containing any link are refused outright by `Crx` (see [Installation](/openwiki/extensions/installation.md)).

`shim(for:)` specialises the script per extension: it scans the package's `.js` files for `.<namespace>.on<Event>` mentions (so the worker can accept listeners added late), lists shipped scripts (so a missing `importScripts` fails at once, as in Chrome), and fills in the Chrome version and a verbose flag for test runs.

## What the shim defines

Namespaces answered natively (`run(_:_:context:owner:)`):

| Area | APIs |
|---|---|
| Browser data | `bookmarks.*` (Chrome-shaped tree: root `0`, bar `1`), `history.*`, `downloads.*`, `sessions.*`, `topSites.get`, `readingList.*`, `browsingData` settings |
| UI | `sidePanel.*`, `action.popup` (per-tab popup paths), `notifications.*`, `tts.*` (one `NSSpeechSynthesizer`) |
<!-- openwiki: broken internal link [/openwiki/extensions/native-bridges-and-capture.md] link "/openwiki/extensions/native-bridges-and-capture.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Documents | `offscreen.createDocument/closeDocument/hasDocument/sendMessage` (see [native bridges](/openwiki/extensions/native-bridges-and-capture.md)) |
| Scripts | `userScripts.*`, `scripting.file` (functions forwarded from extension frames written as files for WebKit's scripting API) |
| Tabs | `tabs.describe`, `tabs.move`, `tabs.discard`, `tabs.group/ungroup`, `tabGroups.*` (Chrome numbering via `TabGroup.number`; groups hidden while groups are off), `search.query` |
| Identity | `identity.launchWebAuthFlow`, `getProfileUserInfo` (empty), `removeCachedAuthToken`; `getAuthToken` throws (needs a Chrome Google account) |
| System | `management.*`, `runtime.getContexts`, `fontSettings.*`, `idle.*`, `power.*` (IOKit sleep assertions, released on unload), `system.cpu/memory/storage/display` |
| Settings | `setting.*` for `chrome.privacy` and similar |
| Capture | `capture.grant` for `desktopCapture`/`tabCapture` |
| Internal | `background.wake/loadedBefore/revive`, `clients.pages`, `permissions.*`, `debug.error` |

Anything else in `run` throws `"<api> isn't available in Search"`; the script's `refuse` helper returns the same error as a rejected promise or `lastError` for callback-style calls, as Chrome does for unavailable APIs.

### Permission gate (enforced in Swift)

The shim runs beside the extension's code, so checks inside it "stop only the honest". The real gate is in `run`: each family in `gates` (`bookmarks`, `history`, `downloads`, `sessions`, `topSites`, `browsingData`, `readingList`, `userScripts`, `identity`, `search`, `notifications`, `idle`, `power`, `tts`, `tabGroups`) requires that name in the manifest's `permissions` **or** in optional grants stored under `extensions.granted.<id>` (`allowed`). `tabs.describe` requires WebKit's `.tabs` permission. `setting.<family>.*` requires the family. Otherwise the call throws "The extension never asked for …".

## Mending WebKit's differences

Large parts of the script fix behaviour where WebKit and Chrome disagree. Representative cases, each tied to a real extension in the comments:

- **Messaging**: multiple `onMessage` listeners (WebKit took only the first's return); messages from the worker to the extension's open pages relayed over a channel so a popup asking "anyone there?" gets an answer (1Password); pages saying whether they will respond so replies don't hang; ports posted before WebKit has set them up held until ready.
- **Workers**: listeners added after worker start-up (WebKit refuses them; Chrome accepts) via the event list found at prepare time; a worker WebKit lost track of is detected by asking it, then revived (`background.revive`); `importScripts` of a missing file fails fast.
- **Globals**: `chrome` and its namespace objects kept stable and captured early, so sandboxes like MetaMask's LavaMoat that later lock globals away don't cut WebKit's listeners off.
- **Extension frames in websites** (e.g. Vimium's bar): privileged calls are routed through the worker, since WebKit kills a web process that makes them directly.
<!-- openwiki: broken internal link [/openwiki/extensions/architecture.md] link "/openwiki/extensions/architecture.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- **User agent**: extension pages and workers see a Chrome UA in `navigator.userAgent` (not WebKit's setting, see [architecture](/openwiki/extensions/architecture.md)).
- **Downloads**: worker `blob:` URLs are converted to data URLs (WebKit's download page can't read them), capped near half a gigabyte, and `downloads.onChanged` is fired when Search saves the file (SingleFile waits for it).
- **declarativeNetRequest**: rules WebKit can't take are reshaped (e.g. counted repeats written out, unsupported regex constructs dropped) or left out individually rather than failing the whole set.
- **WebAssembly**: `.wasm` served without `application/wasm` is handled.
- **Errors**: `error` / `unhandledrejection` in extension pages and workers are reported via `debug.error` and listed per extension (`Extensions.noteError`, last 40); in test runs `console.error/warn` too.

## OAuth (`ExtensionAuth`)

`identity.launchWebAuthFlow` → `ExtensionAuth.run`: opens the provider URL in a foreground tab and waits. The flow ends with **Declined** if the tab disappears or 10 minutes pass. `intercept` (called from `Browser.decide` for every navigation) catches `https://<id>.chromiumapp.org/…` **only from the flow's own tab or a popup that tab opened**, resolves the flow with that URL, and closes the tab(s) — nothing is ever loaded from chromiumapp.org.

`handOver` covers extensions that open the provider with `tabs.create` and watch the tab's URL (Figma): for an installed extension with `identity`, the tab shows the redirect address without loading (`Tab.hold`), so `tabs.onUpdated` reports it as Chrome's error page would; after 4 s an untouched tab says "No site at that address." On load, an extension with `identity` is also granted its own `chromiumapp.org` match pattern so it can see that address.

## Tests

- `Tests/SearchTests/ExtensionPortTests.swift` — extracts the messaging part of the script and checks content-script messages stay plain while own-page messages stay numbered.
- `Tests/SearchTests/ExtensionScriptingTests.swift` — `scriptingFile` keeps a forwarded function's arguments and result.
- `Tests/SearchTests/ExtensionWorkerLinkTests.swift` — a worker symlink inside the package becomes a shimmed copy; one under a linked folder outside the package is left alone.

<!-- openwiki: broken internal link [/openwiki/testing/bench-and-test-worlds.md] link "/openwiki/testing/bench-and-test-worlds.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
`./bench ext-*` drives the shims against a test run (see [bench](/openwiki/testing/bench-and-test-worlds.md)).
