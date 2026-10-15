---
type: workflow
title: Contributing conventions and roadmap workflow
description: How changes land in Search — off-by-default features with a Settings switch and a What's New entry, no dependencies, why-not-what comments, no force-unwraps on fallible work, zero new warnings, CHANGELOG Unreleased and NOTES.md, the ROADMAP and the ./ideas tool backed by a database, secret scanning with gitleaks, privacy boundaries, and private security reporting.
tags: [contributing, conventions, roadmap, changelog, security, workflow]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-727b56653fd0103b1858eee2
    resource: repo://.gitleaks.toml
  - id: openwiki-source-ca6cb4b1a14fd7969dfae3ec
    resource: repo://CHANGELOG.md
  - id: openwiki-source-f317ee207e1653d2033c81a4
    resource: repo://CONTRIBUTING.md
  - id: openwiki-source-c013208b307ea9a1cf3b7278
    resource: repo://ideas
  - id: openwiki-source-72fe826953aaa47d17a811e4
    resource: repo://ROADMAP.md
  - id: openwiki-source-3a44815832a872f4778f822b
    resource: repo://SECURITY.md
  - id: openwiki-source-2c6655bb845f73454c0c0209
    resource: repo://Sources/Search/WhatsNew.swift
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# Contributing conventions and roadmap workflow

Sources: `CONTRIBUTING.md`, `SECURITY.md`, `ROADMAP.md`, `CHANGELOG.md`, `NOTES.md`, `ideas`, `.gitleaks.toml`. Search is a small, mostly solo project (by Drice at Office Commun); PRs usually get a first pass from Claude Code before a human review.

## Before writing code

Open an issue for anything beyond a small fix. Look at how other browsers do it and read the requests on its issue; `ROADMAP.md` lists where each request came from.

## New features: off until turned on

Anything that changes how the browser looks or behaves must be:

- **minimal** — the smallest version that does the job, in the app's quiet style;
- **optional and off by default** — someone who never asks for it never sees it;
<!-- openwiki: broken internal link [/openwiki/architecture/persistence.md] link "/openwiki/architecture/persistence.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- **findable** — a switch in Settings (a `Preferences` property, see [Persistence](/openwiki/architecture/persistence.md)), and for big ones a line in the Welcome screens.

Fixes and things every browser is expected to do (Tab between form fields, ⌘1–⌘9) need no switch.

<!-- openwiki: broken internal link [/openwiki/interface/window-chrome.md] link "/openwiki/interface/window-chrome.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
In code, "off by default" usually means a `Preferences` property defaulting to `false`, plus a `WhatsNew.Toggle` with `since: "<version>"` so the first launch of the new version offers it on a card along with older switches still off (see [Window chrome](/openwiki/interface/window-chrome.md)). A release edits `WhatsNew.toggles`, `releases` and `notes`. Some long-standing behaviours default on with a switch to turn them off (e.g. Peek, link status line, tab sleeping, float on tab switch).

## What tends to get merged

- **Small, focused changes** — one thing per PR, readable start to finish.
- **No new dependencies** — Foundation, AppKit, SwiftUI, WebKit and the system frameworks only (`Package.swift` has none).
- **Matches the existing style** — one file per concern; **comments explain *why*, not what the next line does** (often with the measurement, issue number or date behind a decision); read a couple of files first.
- **No force-unwraps on anything that can plausibly fail** (network responses, file reads, keychain lookups).
<!-- openwiki: broken internal link [/openwiki/testing/test-suites.md] link "/openwiki/testing/test-suites.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- **Builds clean** — `swift build` with zero warnings you introduced. See [Test suites](/openwiki/testing/test-suites.md) for what to run.

What doesn't: rewrites for style alone; **anything that phones home**, adds analytics, or changes what leaves the app over the network (the only traffic is pages, their icons, and the update check — see the privacy table in `README.md`); vendoring Chromium or another engine ("a WebKit browser on purpose"); and **any real key or token** anywhere (code, tests, issues, PRs, logs) — tests use obviously fake keys.

## Secret scanning

<!-- openwiki: broken internal link [/openwiki/ai/assistant.md] link "/openwiki/ai/assistant.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
Run `gitleaks git --pre-commit --staged` with the repo's `.gitleaks.toml` before committing (worth a pre-commit hook), and `gitleaks git` over history. The config extends gitleaks' defaults with rules for **OpenRouter** (`sk-or-v1-…`), **Groq** (`gsk_…`) and **Google AI Studio** (`AQ.…`) keys — the providers the [AI add-on](/openwiki/ai/assistant.md) may be given.

## Changelog, notes and roadmap

- **`CHANGELOG.md`** — newest first. A PR that fixes or adds something adds its line under **Unreleased** the day it merges (and takes its item off the roadmap), so release notes write themselves. Unreleased also has a **Held back** section for work kept on main but not shipping (currently the AI add-on, gated by `AI.shipped`). At release the section gets its number and date.
<!-- openwiki: broken internal link [/openwiki/operations/build-and-release.md] link "/openwiki/operations/build-and-release.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- **`NOTES.md`** — one paragraph per release, newest first. `build.sh` puts the **first paragraph** into the appcast, which Settings shows under the version (see [Build and release](/openwiki/operations/build-and-release.md)).
- **`ROADMAP.md`** — every idea and report (issues, PRs, emails, replies on X) with its status. It is **generated** by `./ideas md` from the live list, which is published at officecommun.com/search/roadmap.

### `./ideas`

A Python CLI over the `search_ideas` table in Office Commun's Supabase project (via the Management API). Writing needs the owner's Supabase CLI login (keychain or `SUPABASE_ACCESS_TOKEN`); anyone can read the page.

- `./ideas` (being built / next version / next), `all [STATUS]`, `find WORDS…`, `show ID`
- `add TITLE [DETAIL] --area AREA [--now|--next|--later] [--fix|--feature] [--from SRC…]`, `from ID SRC…` (another person asked)
- `start ID WHO`, `stop ID`, `done ID [VERSION]` (on main → ships next), `set ID KEY=VALUE…`
- `ship VERSION` (at release, everything done becomes shipped), `check` (every open GitHub issue/PR has an idea; nothing closed is still to do), `md` (write `ROADMAP.md`)

Statuses: `new, planned (now/next/later), building, review, ready, shipped, asked, call, declined`. Areas: passwords, extensions, video, tabs, speed, sites, interface, keyboard, import, security, platform. Sources: `#123`, `email`, `x`, `message`. **Never** put a private security report, or a name or address from an email, in it.

Rules from `ROADMAP.md`: every new idea gets its line the day it arrives (`find` first, then `from` instead of a duplicate); say what you're building as you start (`start`), and `done` it when on main, together with its CHANGELOG line.

## Reporting bugs and security issues

- **Bugs**: an issue with what you did, expected, got, and the macOS version. A crash log, if any, is at `~/Library/Application Support/Search/crash.log` and never leaves the Mac unless pasted.
<!-- openwiki: broken internal link [/openwiki/operations/self-update.md] link "/openwiki/operations/self-update.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- **Security** (`SECURITY.md`): report privately through GitHub's **Report a vulnerability** or hello@officecommun.com with "security" in the subject. No public issue or PR describing the attack until a fix ships (a PR that only fixes it is fine). In scope: anything letting a page, extension, another app or the network read files, passwords, cookies or history, bypass a permission, open another app without asking, or change the app — including the updater, keychain items, the extensions layer and `./bench`. Fixes go in the next version and reach people within a day via [self-update](/openwiki/operations/self-update.md); reporters are thanked in the changelog. Several releases (1.0.3–1.0.5) shipped rounds of hardening from such reports.

## Licence and name

MIT. "Search" and the icon are Office Commun's: rename a fork before distributing it.
