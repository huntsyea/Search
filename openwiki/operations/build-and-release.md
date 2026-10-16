---
type: operations
title: Build, sign and release
description: How Search is built and shipped — swift build vs ./build.sh, the assembled app bundle (stripped binary, dSYM, drawn icon, Info.plist), ad-hoc vs Developer ID signing and the passkeys provisioning profile, separate arm64 and Intel builds, DMG/ZIP/appcast and the signed appcast, notarisation, publish.sh checks, the Homebrew tap, and the OpenWiki CI workflow.
tags: [build, release, signing, notarization, dmg, appcast, homebrew, ci]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-6d4b4e707b8d60b6ccfa3425
    resource: repo://.github/workflows/openwiki-update.yml
  - id: openwiki-source-8a2e26d4137b8250f68bb869
    resource: repo://build.sh
  - id: openwiki-source-96b1dcf93ba7a3817e1664aa
    resource: repo://Icon/icon.swift
  - id: openwiki-source-3cd60b41c1c92c93defad027
    resource: repo://Installer/dmg.py
  - id: openwiki-source-44556fe9d4e9f904fa84ea9e
    resource: repo://publish.sh
  - id: openwiki-source-9510b2c51248ed198b3882a5
    resource: repo://tap.sh
  - id: openwiki-source-94e7bca26bc3525581ff6cdf
    resource: repo://VERSION
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# Build, sign and release

Requirements: macOS 14+, Xcode 16 / Swift 6 toolchain. No package dependencies (`Package.swift`).

## Two ways to build

| Command | Result |
|---|---|
<!-- openwiki: broken internal link [/openwiki/architecture/persistence.md] link "/openwiki/architecture/persistence.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| `swift build` | Runs the app straight from SwiftPM's binary. Because the path contains `/.build/`, it is **always a test run** (`Store.testing`), with its own folder, settings and website data (see [Persistence](/openwiki/architecture/persistence.md)). |
| `./build.sh` (`= ./build.sh release app`) | Assembles a double-clickable `build/Search.app`, signed with a Developer ID if one is in the keychain, otherwise ad-hoc so it runs on the building Mac. |
| `./build.sh release dmg` | + `Search.dmg`, `Search.zip`, `appcast.json` (+ signed `appcast.json.zip` with a Developer ID). Not notarised. |
| `./build.sh release ship` | + notarises DMG and ZIP with `notarytool`, staples the DMG, rewrites the appcast. Requires a Developer ID (refuses otherwise). |

Environment knobs: `SEARCH_ARCH` (`arm64` → `build/`, `x86_64` → `build/intel/`; default the Mac's own), `SEARCH_SIGN_IDENTITY`, `SEARCH_NOTARY_PROFILE` (default `search`), `SEARCH_DOWNLOAD_URL` (default `https://officecommun.com/search`, where `Updater.feed` looks), `SEARCH_AI_ENGINE_VERSION`.

A self-built copy isn't notarised and needs right-click → Open the first time. It keeps **separate passwords** from the signed release, because the keychain tells them apart by signature.

## What `build.sh` does

1. `swift build -c release --arch $ARCH` with **`-Osize`** for release (14% smaller binary at the same measured speed), and checks with `lipo` that the binary is exactly the requested architecture.
2. Creates `Search.app/Contents/{MacOS,Resources}`, copies the binary and `Search.sdef`.
3. Release only: writes a **dSYM** beside the app (`build/Search.app.dSYM`, for `atos` / Console symbolication) and `strip -x`s the binary. Symbols were more than half the binary size.
4. **Icon**: `swift Icon/icon.swift` draws the iconset and an Icon Composer document from the mark's own path data (the same shape as `Logomark` in `Design.swift`). `iconutil` makes `AppIcon.icns`. With Xcode 26's `actool`, it also compiles `Assets.car` so macOS 26's Dark/Clear/Tinted Dock styles work (#337); otherwise it notes the fallback.
<!-- openwiki: broken internal link [/openwiki/integrations/macos.md] link "/openwiki/integrations/macos.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
5. **Info.plist**: bundle id `com.officecommun.search`, `CFBundleShortVersionString` from `VERSION` (currently `1.0.5`), `CFBundleVersion` = `date +%Y%m%d%H%M` (a build number that only increases, which the updater compares), `LSMinimumSystemVersion` 14.0, URL/document types, ATS, usage strings, AppleScript (see [macOS integration](/openwiki/integrations/macos.md)).
6. **Signing**: if `Search.provisionprofile` is next to the script, it is embedded and `Search.passkeys.entitlements` is used (for the passkey browser entitlement), otherwise `Search.entitlements`. With an identity: `codesign --deep --timestamp --options runtime` (hardened runtime). Without one: ad-hoc (`--sign -`), which **the updater refuses to swap anything in under**. A codesign failure stops the build (no `|| true`).

Then, for `dmg`/`ship`:

7. **DMG**: `Installer/background.swift` draws the window background; `Installer/dmg.py` lays it out through **dmgbuild** (installed once into `.build/dmgbuild`, pinned to 1.6.7), so no Finder is scripted mid-build. Without dmgbuild, a plain `hdiutil` image with an Applications link. Signed if possible.
8. **ZIP** (`ditto -c -k --keepParent`) — what the updater downloads; its SHA-256 goes in the appcast.
9. **Appcast** `appcast.json`: `version`, `build`, `url` (ZIP), `dmg`, `sha256`, `dmgSha256`, `notes` (the **first paragraph of `NOTES.md`**, shown under the version in Settings), `minimumSystemVersion`, and optionally `ai.engine` (see below). It is written **after** stapling, because stapling changes the DMG's hash.
<!-- openwiki: broken internal link [/openwiki/operations/self-update.md] link "/openwiki/operations/self-update.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
10. **Signed appcast** `appcast.json.zip`: the same JSON signed with `codesign --identifier com.officecommun.search.appcast` (signature in extended attributes, carried by `ditto --sequesterRsrc`). Builds from 1.0.4 read **only** this; older builds read the plain file. No separate signing key to keep or lose. See [Self-update](/openwiki/operations/self-update.md).

**Two builds per release** since 1.0.5: Apple Silicon and Intel, each with its own appcast (Intel's under `…/intel/`). A universal binary would double the download for everyone (10.9 vs 5.4 MB).

<!-- openwiki: broken internal link [/openwiki/ai/assistant.md] link "/openwiki/ai/assistant.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
**AI engine** (only if `SEARCH_AI_ENGINE_VERSION` is set, arm64 only): verifies `build/engine/search-ai-engine-arm64` is signed with the Developer ID as `com.officecommun.search.ai-engine` (team `7BYKA895MC`), copies it under `ai/`, and adds its version/URL/hash/size to the feed. Built separately by `./engine.sh` (see [AI add-on](/openwiki/ai/assistant.md)); the add-on itself is not shipped in 1.0.5.

## Publishing (`publish.sh`)

`./publish.sh "<site>/public/search"` (with `SEARCH_ARCH=x86_64` for `intel/`) copies `Search.dmg`, `Search.zip`, `appcast.json`, `appcast.json.zip` into the website folder, after checking:

- every file exists and `appcast.json` is **this `VERSION`**;
- the ZIP's app is the right architecture;
- the signed appcast **verifies** against the designated requirement (Apple anchor, identifier `com.officecommun.search.appcast`, Developer ID certificate fields, team `7BYKA895MC`) and is byte-identical to `appcast.json` — a broken signed feed would silently stop every update;
- warns if the DMG isn't stapled;
- if the feed names an AI engine, that file exists with the feed's hash.

File names never change, so site links and the updater's address are permanent.

## Homebrew (`tap.sh`)

After the GitHub release `vX.Y.Z` has `Search.dmg` and `Search-Intel.dmg`, `./tap.sh` downloads both, computes SHA-256s, clones `github.com/driceroland/homebrew-tap`, rewrites the head of `Casks/search.rb` (`arch arm: "", intel: "-Intel"`, version, both checksums, release URL), drops the old arm64-only restriction, commits and pushes. `brew install --cask driceroland/tap/search` then installs the right DMG per chip.

## Release checklist (as the scripts imply)

<!-- openwiki: broken internal link [/openwiki/workflows/contributing.md] link "/openwiki/workflows/contributing.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
1. Bump `VERSION`; write the new top paragraph in `NOTES.md`; update `WhatsNew` toggles/notes and `CHANGELOG.md` (see [Contributing](/openwiki/workflows/contributing.md)); `./ideas ship VERSION`.
2. `./build.sh release ship` and `SEARCH_ARCH=x86_64 ./build.sh release ship`.
3. `./publish.sh <site folder>` for each arch.
4. Create the GitHub release with both DMGs; run `./tap.sh`.
<!-- openwiki: broken internal link [/openwiki/testing/test-suites.md] link "/openwiki/testing/test-suites.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
5. Check the release candidate by hand for what tests can't see (e.g. Split View dragging, see [Test suites](/openwiki/testing/test-suites.md)).

## OpenWiki CI (`.github/workflows/openwiki-update.yml`)

A daily (08:00 UTC) and manual GitHub Actions job installs `openwiki@0.7.2`, runs `openwiki code --update --print` with full git history (so it can diff from the last documented commit), deletes `openwiki/.run.json`, and opens or updates a `openwiki/update` pull request with changes under `openwiki/`, `AGENTS.md`, the workflow, and `CLAUDE.md` if present. A failed run still opens the PR with the pages completed so far, then fails the job. It needs `OPENAI_API_KEY` and optional LangSmith secrets.
