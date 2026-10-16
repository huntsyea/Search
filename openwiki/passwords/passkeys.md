---
type: subsystem
title: Passkeys and security keys
description: How Search runs WebAuthn itself instead of leaving it to WebKit — a navigator.credentials patch in the page world bridged to Search's world, origin and relying-party checks from WebKit's frame info, ASAuthorization's browser API with Search-written client data, conditional mediation offered in the account list, sealed PRF results, the browser entitlement and provisioning profile, and test-run rehearsals.
tags: [passkeys, webauthn, security, authentication-services, entitlements, autofill]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-02847f451c085472cf1aac1a
    resource: repo://Search.passkeys.entitlements
  - id: openwiki-source-6ac42fada10be5d789df6d6c
    resource: repo://Sources/Search/Accounts.swift
  - id: openwiki-source-6eff1f46e2649b744c0c6afe
    resource: repo://Sources/Search/Passkeys.swift
  - id: openwiki-source-fc9b78c55ddd3ec773fb0af8
    resource: repo://Sources/Search/Prefs.swift
  - id: openwiki-source-6e6b2e557229ef129b26e320
    resource: repo://Sources/Search/Tab.swift
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# Passkeys and security keys

`Sources/Search/Passkeys.swift`. Passkeys (and security keys, and an iPhone over QR) work in Search through the **Mac's own sheet**, but the WebAuthn ceremony is carried by Search itself, as Chrome and Firefox do on macOS.

## Why WebKit isn't left to do it

For a sign-in page that offers your passkey under its name field (**conditional mediation**), WebKit opens an AutoFill operation with macOS's `AuthenticationServicesAgent` and holds it as long as the page waits. If Search dies meanwhile (quit, crash, kill), the agent **never releases it** and refuses every later passkey request from Search before any sheet ("Request already in progress for specified application identifier") — "Authentication failed" on every site until the Mac restarts (found 24 Sep 2026). So Search never opens that operation.

## Requirements

<!-- openwiki: broken internal link [/openwiki/operations/build-and-release.md] link "/openwiki/operations/build-and-release.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- The restricted entitlement **`com.apple.developer.web-browser.public-key-credential`**, which Apple grants browsers on request, plus a matching **Developer ID provisioning profile** embedded in the app. `build.sh` embeds `Search.provisionprofile` and signs with `Search.passkeys.entitlements` only when the profile is present (see [Build and release](/openwiki/operations/build-and-release.md)). Source builds have neither.
- `Preferences.entitledToPasskeys` reads the entitlement at runtime (`SecTaskCopyValueForEntitlement`). In an entitled build, passkeys default **on** the first time that build runs, whatever was chosen while they couldn't work; after that, the Settings switch is the user's (`passkeys`, `passkeys.entitled`).
- macOS asks the user once whether Search may use the Mac's passkeys (`ASAuthorizationWebBrowserPublicKeyCredentialManager`; System Settings › Privacy & Security). Search asks **only when a site first requests a passkey with a sheet**, never while a page merely loads; callers waiting on the question are queued.

## How a request flows

<!-- openwiki: broken internal link [/openwiki/extensions/chrome-api-shims.md] link "/openwiki/extensions/chrome-api-shims.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
1. **Page world patch.** `PasskeyRelay.page` is injected at document start into the **page's own world** (it must replace the page's functions) — the one Search script that lives there. It patches `navigator.credentials` on the **prototype** (WebKit recreates `navigator.credentials` when nothing holds it), answers public-key `get`/`create`, and leaves other credential types alone. It captures WebCrypto before site scripts run. The same patch is placed first in extensions' MAIN-world content scripts (`search-passkeys.js`, see [Chrome API shims](/openwiki/extensions/chrome-api-shims.md)) so password managers capture Search's version. Whichever copy runs first installs it once.
2. **Bridge.** The page world has no `window.webkit`, so the patch dispatches window events (`search-passkeys-ask` / `-answer`) to a bridge in **Search's world**, which posts to `PasskeyRelay` (`WKScriptMessageHandlerWithReply`, name `officePasskeys`).
3. **Caller from WebKit, not the page.** `PasskeyRelay` builds a `Caller` from `message.frameInfo` — security origin, main frame or not, the page's host, window, view — and calls `Passkeys.perform`.
4. **Checks** (`perform`):
   - Passkeys disabled in Settings → `NotAllowedError` (a conditional `get` just waits).
   - Must be **https**, or http on localhost/loopback.
   - A sheet request must come from the **front window of the active app** ("The document is not focused"); conditional requests may come from a page still loading or behind, since nothing shows until you pick.
   - A **cross-site frame** can't ask on the page's behalf; conditional requests from frames wait with nothing offered.
   - **Relying party** (`fits`): the page's host or a parent domain that is still a registrable site — never another site, an IP address, or a public suffix (`com`, `co.uk`, `github.io`), checked with CFNetwork's private `_CFHostIsDomainTopLevel`. Without that symbol, only the exact host is allowed.
   - A non-empty challenge is required.
5. **Client data written by Search**: `ASPublicKeyCredentialClientData(challenge:origin:)`, with the origin **from WebKit's frame info**, never one the page states.
6. **Requests** (`assertion` / `registration`): platform (iCloud Keychain / password apps) and security-key requests. New Mac passkeys are always **ES256**, so they're offered only if the site accepts it (no `pubKeyCredParams` means ES256 or RS256, per the standard). Allowed credential descriptors, transports, user verification and attestation are mapped across.
7. `ASAuthorizationController` shows the Mac's sheet anchored to the window. A new request ends the previous one; a page's `AbortSignal` cancels by token. The result is returned in the shape a native credential has (`assertionReply` / `registrationReply`, including authenticator data and public key extracted from the attestation). Data properties are read-only and methods writable, because libraries like GitHub's webauthn-json add `toJSON` (#407).

## Conditional mediation (passkeys under the field)

<!-- openwiki: broken internal link [/openwiki/passwords/vault-and-autofill.md] link "/openwiki/passwords/vault-and-autofill.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
A conditional `get` from the main frame is checked, then **kept waiting** per page view (`conditional`). The Mac is asked only **which passkeys it holds for the site**, a question with no sheet and no open operation. They appear **first** in the account list under the sign-in field (`AccountList` in `Accounts.swift`, as Safari does), beside saved passwords (see [Passwords](/openwiki/passwords/vault-and-autofill.md)). Nothing reaches the page until you pick one: then `sign(in:with:)` shows the Mac's sheet for **that passkey alone** and answers the waiting request. A new document (`Tab.didCommit` → `forget`), the page cancelling, or the page asking again (including a modal request) ends the wait.

## PRF (keys derived from a passkey)

The PRF extension (sites encrypting data only your passkey opens) is passed to AuthenticationServices (`prfAssertion`, salts untouched; salts for credentials not in the allow list are dropped, as the standard requires). Results travel back over a window event any script could hear, so they're **sealed** for a one-time P-256 key the page's own call generated: ECDH P-256 → HKDF-SHA256 → AES-GCM (`prfReply`). Without that key, no results are sent.

## Test runs

A test run never asks the Mac or shows the sheet (it would list or prompt with the passkeys of whoever is at the machine). Conditional requests get a made-up passkey, and sheet requests get a **rehearsal** credential: a real P-256 key in the right shape with nothing signed, so the checks and the page side still run for real. `./bench` reads `Passkeys.asked` and `Passkeys.last`.

## Logging

Only kind, relying party and origin are logged (`Logger` category `Passkeys`); no challenges, credentials or user data.
