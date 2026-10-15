---
type: feature subsystem
title: Importing from other browsers
description: How Search brings over passwords, bookmarks, history, icons, extensions and Arc spaces/pins from Chromium browsers (Login Data + Safe Storage key), Firefox and Zen (logins.json + key4.db), Arc's sidebar file, and exported files (Netscape HTML, password CSV, Safari's export ZIP) — the ImportPanel flow, snapshot copies, previews that never prompt, ImportRecord-based Replace, cleanup, and tests.
tags: [import, chromium, firefox, arc, safari, passwords, bookmarks, history]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-1b91af10ad5375b1fe623b19
    resource: repo://Sources/Search/Import.swift
  - id: openwiki-source-9ade5d6d664e5edd36321368
    resource: repo://Sources/Search/ImportArc.swift
  - id: openwiki-source-6f92cb5d1a17b55c934a8893
    resource: repo://Sources/Search/ImportFile.swift
  - id: openwiki-source-58d933bc0d58c6ae52e44cc6
    resource: repo://Sources/Search/ImportPanel.swift
  - id: openwiki-source-2dbd2535a72764d14bf71bb3
    resource: repo://Sources/Search/ImportRecord.swift
  - id: openwiki-source-534ae75d10a3d699fb8d4da3
    resource: repo://Sources/Search/Links.swift
  - id: openwiki-source-ee7ac01ee31ac7125a13b71e
    resource: repo://Tests/SearchTests/ImportFileTests.swift
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# Importing from other browsers

"Bring Things Over…" (File menu, Settings › Passwords, Bookmarks/Passwords panels, the Welcome screens, and Settings › Extensions for extensions alone) opens **`ImportPanel`** — one sheet for every source: which browser, which profile, and what to bring. Nothing leaves the Mac.

## Sources

`ImportSource` (`Import.swift`) wraps two families so the panel, Welcome and bench speak one vocabulary:

| Family | Browsers | Reader |
|---|---|---|
| `chromium` | Dia, Chrome (+Beta/Dev/Canary), Arc, Brave, Edge, Vivaldi, Chromium, Opera, Opera GX, Helium, Comet (`Chromium.known`) | `Chromium` |
| `mozilla` | Firefox, Zen | `Mozilla` |

Plus **files** (`ImportFile.swift`) and **Arc's sidebar** (`ImportArc.swift`). Safari's data is protected from other apps, so for Safari the sheet explains how to export (File › Export Browsing Data) and import the ZIP.

Profiles are found by folders holding `Login Data`, `Bookmarks` or `History` (Opera keeps its single profile in the browser folder). Chromium's `Local State` gives each profile's display name and the last used; Guest/System profiles are hidden. The default profile is the last used (or most recently modified). Choosing "All profiles" reads every one. Browsers that are installed but whose data isn't where expected are named with the path looked at (`Chromium.unreadable`), rather than "no browser found".

In a **test run**, `Chromium.base` (and Mozilla's) is `<test world>/Import/`, so tests read made-up profiles, never a real browser's.

## Reading safely

- **Snapshot copies.** Every SQLite file (`Login Data`, `History`, `Favicons`, `places.sqlite`…) is copied with its `-wal`/`-shm` siblings into a scratch folder and read from there (`Snapshot`). Reading the live database risks lock errors and misses the newest writes still in the WAL.
- **Scratch folders** are per-process (`ImportFile.scratchFolder()`), and `ImportFile.sweepScratch()` runs at launch (from `Links.applicationDidFinishLaunching`) to delete folders left by a crashed or killed import — a Safari export's passwords sit there in the clear.
- **Previews never prompt.** `preview(of:profile:)` counts bookmarks, places (up to 3,000) and password rows from the files alone; no key is requested and nothing is decrypted. The bench checks that counting never asks for the key.

## Chromium passwords

Chromium browsers on macOS store passwords in `Login Data` (SQLite), each value `v10` + AES-128-CBC, with the key derived from a passphrase in the login keychain under "*Name* Safe Storage":

1. `safeStorage` reads that keychain item — **the one step macOS asks the user to allow**, asked once per read regardless of profile count.
2. `stretch`: PBKDF2-SHA1, salt `saltysalt`, 1003 rounds, 16 bytes.
3. `unwrap`: AES-128-CBC, IV of 16 spaces, PKCS7. Newer builds prefix a 32-byte site hash, which is skipped.

<!-- openwiki: broken internal link [/openwiki/passwords/vault-and-autofill.md] link "/openwiki/passwords/vault-and-autofill.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
**Only `v10`-encrypted values are accepted**: a plaintext password lying in a profile file could only have been put there by another program to get Search to keep it. Sites marked "never save" come over as `disabledHosts`; logins with no usable site are counted as skipped. Decrypted logins go into the keychain through `Vault` (see [Passwords](/openwiki/passwords/vault-and-autofill.md)) — never written anywhere else.

Chrome's channels (Beta/Dev/Canary) share Chrome's key; Opera and Opera GX share Opera's.

## Firefox and Zen

History and bookmarks live together in `places.sqlite` (dates in microseconds since 1970, unlike Chromium's 1601), icons in `favicons.sqlite`. Passwords are in `logins.json` with the key wrapped in `key4.db`: Search handles the common case of **no primary password** — checks the empty password against key4.db's record, unwraps the key, decrypts each login. With a primary password set, it doesn't ask for it; the panel says to export a CSV from Firefox instead. The result has the same shape as Chromium's, so the keychain path is shared.

## Other data

- **Bookmarks**: Chromium's JSON `Bookmarks` file (bar first, then others, folders kept); Mozilla's from places. `bookmarkRead` also reports whether every chosen profile read **cleanly** (a missing file counts as clean and empty; an unreadable one doesn't) — Replace depends on it.
<!-- openwiki: broken internal link [/openwiki/features/history-bookmarks-downloads.md] link "/openwiki/features/history-bookmarks-downloads.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- **History**: up to 3,000 places per import, merged by `History.take` (larger count wins, see [History](/openwiki/features/history-bookmarks-downloads.md)).
- **Icons**: the largest bitmap the other browser kept for each imported page or its front door, up to 400, seeded into `Favicons`.
<!-- openwiki: broken internal link [/openwiki/extensions/installation.md] link "/openwiki/extensions/installation.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- **Extensions** (Chromium only): ids of extensions the person added **from the Chrome Web Store** — read from `Preferences`/`Secure Preferences` (location 1, "internal"), excluding built-ins, unpacked, policy-installed, other stores' and themes. They are **installed fresh from the store** one after another (`Extensions.install(id:)`), never copied from the profile. See [Installation](/openwiki/extensions/installation.md).

## Arc's spaces and pins (`ImportArc.swift`)

Arc keeps its sidebar in plain JSON, `StorableSidebar.json`, beside its profiles (no key needed). `Arc` parses its flat id/object lists into `ArcSidebar`: spaces (name, icon mapped to one of `Spaces.icons`, colour, the Chromium profile it signs in with), each space's **pinned** container (the "unpinned" one is Arc's Today, left behind), folders, and favourites (per profile). Read defensively: a folder visited once and no deeper than 64, only http(s) URLs, credentials dropped, oversized files not read.

<!-- openwiki: broken internal link [/openwiki/tabs/spaces-pins-groups.md] link "/openwiki/tabs/spaces-pins-groups.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
`Browser.takeArc` turns on Spaces if Arc has more than one space, creates or matches spaces by name, brings pinned tabs as asleep tabs/pins and favourites as pins, skipping ones already pinned — including a pin whose page wandered (Gmail pinned at `mail.google.com` found at `/mail/u/0/`, #482). See [Spaces, pins and groups](/openwiki/tabs/spaces-pins-groups.md).

## Files (`ImportFile.swift`)

One chooser accepts a file, a folder, or a ZIP:

- **`.html`** — Netscape bookmarks (`BookmarksFile`).
- **`.csv`** — passwords, handed to `Vault.take(csv:)`.
- **Safari's export ZIP** — bookmarks, passwords and a history JSON per profile. File names inside are localized, so members are recognised by content, not name. Safari's history is identified by `metadata.data_type == "history"`; redirect steps and failed loads are skipped. Only a ZIP containing that history marks the import as Safari's (which also triggers a note that Safari's export holds passwords in the clear).

ZIPs are extracted with `/usr/bin/ditto` into the scratch folder (the child is terminated on cancel; the folder removed on any failure). Folders are read to one level of subfolders only. Reading is chunked with cancellation checks; progress is throttled to about ten updates a second and **never contains file contents**. File imports run in the background with a progress card and Cancel (`ImportProgress` in `App.swift`); quitting cancels them and waits up to 5 s.

## Replace and `ImportRecord`

`ImportRecords` (in settings under `import.records`) notes, per browser name: date, counts of bookmarks/places/passwords/spaces/pins, and the ids of every bookmark and folder that import added. The panel shows "brought over on …" beside the browser.

**Replace** (off unless chosen) removes exactly the bookmarks that came from that browser before adding them fresh — **but only if the new read was complete**, so a missing or malformed profile never wipes an earlier import (#375). Passwords are never removed by Replace. Only imports made since records existed have one; older ones are never guessed at. Bookmark merges keep concurrent edits and deduplicate.

## Tests

- `Tests/SearchTests/ImportFileTests.swift` — Netscape parsing with decoded titles; folder reading order and depth; progress reset/throttling; cancellation during HTML parsing; CSV progress never containing contents; merge keeps concurrent edits; Replace with a readable empty profile removes only that source's bookmarks; Replace with a missing/malformed profile preserves the earlier import; Arc import keeps spaces, folders, pins and record counts; ZIP extraction cleaned up and only ZIP history marks Safari.
- `Tests/arc_pins.py`, `arc_folders.py`, `arc_icons.py`, `arc_rows.py` — Arc imports through the bench in an isolated world (`python3 Tests/arc_pins.py` after `./build.sh`).
