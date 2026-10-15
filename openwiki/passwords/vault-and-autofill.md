---
type: feature subsystem
title: "Passwords: keychain vault and sign-in autofill"
description: How Search keeps and offers passwords — the Vault (keychain internet passwords labelled Search, never written elsewhere), FormRelay's sign-in detection and native-setter filling, offering saves only after a sign-in actually took, the account list under the field (never auto-filled, click guard, http/https separation, site matching across subdomains), identifier-first and password-only flows, the Passwords panel with Touch ID, CSV import, and tests.
tags: [passwords, keychain, autofill, security, forms, touch-id]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-50d9705ad83befb6a5230076
    resource: repo://Sources/Search/Browser.swift
  - id: openwiki-source-716a15dd607ed903eaaabada
    resource: repo://Sources/Search/Forms.swift
  - id: openwiki-source-7be01bbd59a5c452c7f33cef
    resource: repo://Sources/Search/Passwords.swift
  - id: openwiki-source-6e6b2e557229ef129b26e320
    resource: repo://Sources/Search/Tab.swift
  - id: openwiki-source-991498b388e5740007ee4bd8
    resource: repo://Sources/Search/Vault.swift
  - id: openwiki-source-0ead1ed6b75bc386dd734814
    resource: repo://Tests/identifier_first.py
  - id: openwiki-source-f1a7ddd4936f2b18684f26ab
    resource: repo://Tests/password_only.py
  - id: openwiki-source-3eb60176080332a8d148f21e
    resource: repo://Tests/SearchTests/VaultAndUpdaterTests.swift
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# Passwords: keychain vault and sign-in autofill

## The Vault (`Vault.swift`)

Passwords live in the **macOS login keychain** as **internet passwords** (`kSecClassInternetPassword`) keyed by server (host) and account, **labelled `Search`** (a test world labels its own `Search (<world>)`, so test saves never mix with real ones). Nothing is written to disk in any other form and nothing is logged. Safari's passwords are behind an entitlement no other browser gets, so Search has its own items.

- **Ownership.** Every query includes the label, and saved items use `kSecAttrAuthenticationTypeHTMLForm`. Server and account alone would also match other apps' items (git's token for github.com), which an update would otherwise overwrite or a duplicate-add would fail on.
- **http vs https.** `kSecAttrProtocol` records whether a password was saved from a page sent in the clear. A page over plain http is **only offered passwords saved from plain http**, never the https site's of the same name (a café network could have written that page).
- **Last used** rides in `kSecAttrComment` as a timestamp; lists sort newest first (`touch`).
- **Password-only sign-ins** are stored with **no account** (the keychain lists them without the attribute), and read back as `""` so they're offered, listed and forgettable.
- **Lists without secrets.** The keychain can't list many items and return all their secrets in one call (it answers `errSecParam`, which once made saved passwords unreadable). So `rows` lists attributes only and `secret(host:user:)` reads one secret per call. `Kept` (no secret) is what panels use; `Login` (with secret) is only produced on the paths that fill or compare, so a list row can't be passed off as holding a password.
- **Site matching.** `logins(matching:)` returns exact-host items plus those sharing the **registrable domain** (`Vault.registrable`, public-suffix aware: `accounts.example.com` ↔ `example.com`, while `bbc.co.uk` stays itself).
- **Never** list: per-site "Never for this site" choices (`never`, also matched by registrable domain).
- `Vault.host(of:)` accepts only website URLs, so an Android app login in an export (`android://…@com.vendor.app/`) isn't offered to whoever owns `vendor.app`.

<!-- openwiki: broken internal link [/openwiki/operations/build-and-release.md] link "/openwiki/operations/build-and-release.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
A build signed differently (your own build vs Office Commun's) gets its own keychain access, because macOS ties items to the signature (see [Build and release](/openwiki/operations/build-and-release.md)).

## Detecting sign-ins (`Forms.swift`)

`FormRelay` (in Search's content world) reports from the page:

- whether the caret is in something editable (`typing`) and whether the page went fullscreen (`immersed`);
- which **sign-in box** the caret is in and where it is on the page (CSS px, converted to points using page zoom), whether it's part of a sign-in with a password, a passkey-only (`webauthn`) box, or the **name box of a first step** (identifier-first);
- that a sign-in was **sent** (name + password, the host it was sent from, whether over http).

**Filling** goes through the field's own native value setter and fires the events a keystroke would. Assigning `.value` behind a framework's back leaves React-style forms thinking the box is empty, with a grey submit button.

## Offering to save — only once it worked

`Tab.sentSignIn` **holds** the credentials, recording the host at send time, since a moment later the page may be elsewhere. `settleSignIn` decides later:

- A **new document** after sending: judged at once.
- Fields removed by the page itself (in-page sign-in): wait **1.5 s**, because many forms close on submit and reappear if the server refuses. Offering in between would save a possibly wrong password. Only if nothing newer was sent meanwhile.
- Still a password box: a refused sign-in, or a second step. Kept a little longer.

Then `Browser`'s `onCredentials` offers to save (`offering`, a card with Keep / Not now / Never for this site), unless: saving is off (Settings › Passwords), the tab is **private**, the site is "never", the page is an **extension's own page** (Bitwarden's unlock PIN was once offered), or a password-manager extension asked to do the saving itself. An identical saved login is just touched (and its http/https flag updated); a known account with a new password is offered as a change.

## Offering accounts under the field

<!-- openwiki: broken internal link [/openwiki/passwords/passkeys.md] link "/openwiki/passwords/passkeys.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
When the caret enters a sign-in box, `Browser.hang(from:…)` shows **`AccountList`** (`Accounts.swift`) hanging from the box: the Mac's passkeys for a page waiting for one first (see [Passkeys](/openwiki/passwords/passkeys.md)), then the site's saved accounts, newest first — "the way Safari does it". **Nothing is filled on its own.**

- The list **ignores clicks for its first 0.5 s**, as Chrome's does: a page can move the caret into a sign-in box itself, an invisible one under the pointer included, so a click already on its way isn't a choice. The half second restarts when what's under the pointer changes, but not when the same box merely scrolls (the list follows it, and the keychain is asked once per box, not per frame).
- It goes a beat after the caret leaves (so a click on a row isn't lost), and doesn't immediately return for the box you just filled.
- `choose(_:)` refuses if the tab has moved to another site since the list was made, so accounts offered for one site are never put into another's page.
- A **passkey-only box** gets no passwords.

**Identifier-first sign-ins** (Google, impots.gouv.fr…): on the name step, the list offers names and a pick fills **the name alone** (`fillName`). The name sent is remembered **in memory only, for that tab and that site, for 5 minutes** (`gaveName` / `givenName`). On the password-only next page, that account comes first, and a password saved there is saved **with** that name rather than as half a login.

**Password-only sign-ins** (an access code, a dashboard) save and offer an account with an empty name. They still settle correctly when the page swaps itself with `history.pushState` instead of loading a new document.

## The Passwords panel (`Passwords.swift`, ⌥⌘L)

Every saved password by site, in the shared panel style. **A password is never shown until the Mac's owner proves who they are** (`Vault.prove`: Touch ID, Apple Watch or the account password, via `LocalAuthentication`; a Mac with no password set has nothing to prove), and never for longer than it takes to read. **Copy** also requires proof (since 1.0.3). The copied password goes on **this Mac's** clipboard only (not Universal Clipboard), marked concealed and transient so clipboard managers skip it, and is removed after **90 seconds** unless something else was copied since. Forget removes the keychain item.

## Bringing passwords in

<!-- openwiki: broken internal link [/openwiki/import/browser-import.md] link "/openwiki/import/browser-import.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- From Chromium browsers and Firefox/Zen profiles, decrypted and saved straight into the vault (`Browser.keep(_ found:)`). Re-importing updates existing items rather than duplicating. See [Importing](/openwiki/import/browser-import.md).
- From a **CSV** (Google Password Manager / Chrome / Dia: `name,url,username,password,note`): `Vault.take(csv:)` parses quoted fields with embedded quotes and newlines, CRLF and blank lines, finishes parsing before any keychain write, and counts rows it can't keep as skipped. An export **without a password column is skipped whole**. The file is never copied.

## Tests

- `Tests/SearchTests/VaultAndUpdaterTests.swift`: host of a login (no `www`, websites only), registrable-domain rules (never spanning tenants of a public suffix like `github.io`, addresses left whole), and CSV handling (no password column, empty export, unkeepable rows counted, quoted multiline fields, CRLF). It never touches the keychain: every row in it is one that gets skipped.
- `Tests/password_only.py` and `Tests/password_only_mixed.py`: a password-only sign-in sent by `fetch` that then `pushState`s to a dashboard (Next.js-style), saved and offered without a name; mixed with a named login on the same site.
- `Tests/identifier_first.py`: name-first then password-only pages on a local server; accounts brought in via CSV into the test world's own keychain items and forgotten afterwards; the list read and picked through `./bench accounts`. The list's look is checked by eye on a release candidate.
