---
type: workflow
title: "Installing extensions: CRX, Web Store and unpacked"
description: How Search installs Chrome extensions — fetching a CRX3 from Chrome's update service and verifying that its RSA proof's key hashes to the requested id, the Web Store "Add to Search" button, unpacked folders with path-derived ids and Reload, staging and atomic folder replacement, removal and data clearing, and the tests that cover them.
tags: [extensions, install, crx, chrome-web-store, security, signature, unpacked]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-834e25883139255c40974e4e
    resource: repo://Sources/Search/Crx.swift
  - id: openwiki-source-7e54e31e723d57e5d34c1400
    resource: repo://Sources/Search/ExtensionFiles.swift
  - id: openwiki-source-d712b4ebc436418885b2aa56
    resource: repo://Sources/Search/Extensions.swift
  - id: openwiki-source-ccac928e4f161cbf8aaab732
    resource: repo://Sources/Search/StoreRelay.swift
  - id: openwiki-source-6e6b2e557229ef129b26e320
    resource: repo://Sources/Search/Tab.swift
  - id: openwiki-source-a5dbc88af6e3e268446fd2ad
    resource: repo://Tests/ExtensionFilesTests.swift
  - id: openwiki-source-b9f553120d42102412524c0e
    resource: repo://Tests/run-extension-files-tests.sh
  - id: openwiki-source-8aa7659dbad3ba3895f837fe
    resource: repo://Tests/SearchTests/UnpackedIDTests.swift
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# Installing extensions: CRX, Web Store and unpacked

<!-- openwiki: broken internal link [/openwiki/extensions/architecture.md] link "/openwiki/extensions/architecture.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
There are two ways in, both in Settings › Extensions (`ExtensionsPage` in `ExtensionsUI.swift`): a **Chrome Web Store link or id**, or a **folder** ("Load Extension", unpacked, as in Chrome's developer mode). Browsing the store in a tab also offers **Add to Search** on each listing. All of them end in `Extensions.admit`, which shows the permission prompt and moves the staged package into place. Everything requires macOS 15.4+ (see [architecture](/openwiki/extensions/architecture.md)).

## From the Chrome Web Store (`Crx.swift`)

1. **Id.** `Crx.id(in:)` takes the first run of 32 letters `a`–`p` from a pasted id or store link (new or old store URL). `install(id:)` re-checks that the id is exactly that shape before it goes into a URL or folder name.
2. **Fetch.** `Crx.fetch` downloads from `https://clients2.google.com/service/update2/crx?response=redirect&prodversion=140.0.0.0&acceptformat=crx3&x=id%3D<id>…` — the same public update address Chromium browsers use. It claims Chrome 140 because the store refuses extensions whose minimum Chrome version is higher than the browser says it is.
3. **Verify** (`verifiedZip`). A CRX3 is a `Cr24` magic, version 3, a protobuf header, then a zip. The check that matters: a Chrome extension id is the first 16 bytes of SHA-256 of its public key, written as letters a–p. Search requires
   - the signed header's `crx_id` to equal the requested id, and
   - at least one RSA (`sha256_with_rsa`) proof whose **public key hashes to that id** and whose PKCS#1 v1.5 SHA-256 signature verifies over `"CRX3 SignedData\0" + len + signed_header + zip`.

   The store's own additional proof isn't the one that counts. A tampered file, or an extension posing under another's id, fails one of these, raising `Refused.unsignedOrWrong`.
4. **Unpack** (`unpack`). The zip is written to a scratch folder and extracted with `/usr/bin/ditto -x -k`; it must contain `manifest.json`. **Any symbolic link in the package rejects it whole**, because the shim rewrites files in place and a link would redirect that write.
<!-- openwiki: broken internal link [/openwiki/extensions/chrome-api-shims.md] link "/openwiki/extensions/chrome-api-shims.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
5. **Shim** — `ExtensionShims.prepare(staged, fresh: true)` (see [Chrome API shims](/openwiki/extensions/chrome-api-shims.md)).
6. **Admit** — see below.

Errors are announced in plain words (`Crx.Refused`), e.g. "The Chrome Web Store has nothing for that id".

### "Add to Search" on the store (`StoreRelay.swift`)

On macOS 15.4+, every tab's main frame gets `StoreRelay.script` at document end, in Search's own content world. It returns immediately on any host but `chromewebstore.google.com`. On the store it:

- hides the "Switch to Chrome" banner and floating promo card (found by structure and the Chrome logo, not by class names, which change between releases);
- clones the disabled "Add to Chrome" button into an enabled **Add to Search** button with the store's own styling, and hides the original;
- re-applies itself through a `MutationObserver` (debounced with a timer, since background tabs get no animation frames), because the store rewrites itself;
- shows "Adding…" / "Added to Search" from state the browser pushes (`Browser.tellStore`, re-sent whenever `installed` or `busy` changes).

A click only posts `{add: true}`. **What gets installed is read from the tab's own address** (`Crx.storeID(of:)`: https, no credentials, `/detail/<slug>/<id>` on the store host), never from anything the page says, and the normal confirmation prompt still applies.

## From a folder (unpacked)

`installFolder(at:)`:

- Requires `manifest.json` in the folder.
- Resolves the folder's real path and computes the id the way Chrome does for unpacked extensions: **SHA-256 of the real path**, first 16 bytes as letters (`Crx.unpackedID`). The manifest's `key` is **ignored** — store keys are public, so honouring it would let any folder take any extension's id. Native-messaging hosts built for an unpacked extension list this id.
- Copies the folder (through any link to it) into a staging folder, then `Extensions.unlinkOutside` deletes every symlink that leads outside the package or nowhere (links inside are kept), then shims and admits it. `source` records the original path for Reload.

**Reload** (`reload(_:)`, the button in Settings, like Chrome's developer-mode reload) re-copies from `source`, re-shims, and re-reads the manifest. It refuses if the folder is gone, or if `sourceKeepsID` fails — the path now resolves somewhere whose id differs (a link was put in the way). If the new version needs more permissions than recorded, it asks. Older `local-…` ids from before path-derived ids still reload. Store extensions reload in place without copying.

## Admitting, replacing, and loading

Every install goes through a staging folder `Extensions/.staging-<id>-<uuid>`, deleted afterwards whatever happens.

`admit` reads the staged package as a `WKWebExtension`, asks **"Add “Name” to Search?"** listing what it will be able to do (`Extensions.describe`, excluding what Search itself added), and on yes:

1. records the grant set (`Extensions.grants`: WebKit permissions, `site:` patterns, `search:` APIs Search answers) — compared on every future update or reload;
2. `ExtensionFiles.replace(staged, at: target)`;
3. unloads any old copy, clears its errors, invalidates cached workers, writes the `Installed` record, and loads it.

On no, nothing is left behind. The bench can skip the prompt only in a test run (`confirm: confirm || !Store.testing`).

### Atomic folder replacement (`ExtensionFiles.swift`)

`replace` uses `renamex_np`: first with `RENAME_EXCL` (fresh install — fails if the target exists), and on `EEXIST` with `RENAME_SWAP`, which atomically swaps the staged and installed folders. The installed copy is **never removed first**, so a failure leaves the old extension intact; after a swap the old contents sit in the staging path, which the caller deletes. Errors carry the POSIX code, the target and the staged path.

## Removing

`remove(_:)` unloads the extension, forgets its capture grants, settings, optional grants (`extensions.granted.<id>`), new-tab-page choice, its record and its folder, then clears its WebKit data. Ids still to be cleared are kept under `extensions.forgetting` until done and retried at the next launch before anything loads — otherwise an unpacked extension reinstalled from the same path (same id) would inherit the old data.

## Self-healing

WebKit records a worker that failed to start as an error and doesn't retry. `watch(_:)` observes `errorsDidUpdateNotification`; on `backgroundContentFailedToLoad` it calls `revive`, which unloads and reloads the extension (at most once a minute) and reopens its popup if it was open.

## Tests

| Test | What it checks | How to run |
|---|---|---|
| `Tests/ExtensionFilesTests.swift` | Fresh install, swap-and-cleanup, retry after missing staging, immutable target/staging failures | `Tests/run-extension-files-tests.sh` (compiles `ExtensionFiles.swift` with the test standalone) |
| `Tests/SearchTests/UnpackedIDTests.swift` | Id from path; manifest `key` ignored; same key → different ids; links resolve to their folder; Reload refuses a folder that now leads elsewhere; old lists still reload | `swift test` |
| `Tests/SearchTests/ExtensionFolderLinkTests.swift` | Links leading out of the package or nowhere are removed | `swift test` |
| `Tests/SearchTests/ExtensionFileAccessTests.swift` | `file:` patterns are never granted, sites are | `swift test` |

<!-- openwiki: broken internal link [/openwiki/testing/test-suites.md] link "/openwiki/testing/test-suites.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
See [Test suites](/openwiki/testing/test-suites.md).
