---
type: testing
title: Driving Search with ./bench and test worlds
description: The Bench — a same-user Unix socket that lets a script drive a running Search in flask-marked tabs of its own — its consent mark, security and protocol; the ./bench CLI and its test-run-only commands; isolated test worlds (SEARCH_PROBE, --test, --world), hidden probes that must never show a window, fresh.sh, and the search-bench agent skill.
tags: [testing, bench, automation, test-world, socket, tooling]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-da4e871fee65ff305251146d
    resource: repo://bench
  - id: openwiki-source-7f5c0d0b278c8be08d70452b
    resource: repo://fresh.sh
  - id: openwiki-source-93ccbe5e9c12a13eb6a27d86
    resource: repo://skill/search-bench/SKILL.md
  - id: openwiki-source-74189958c809478ddf728dfc
    resource: repo://Sources/Search/Bench.swift
  - id: openwiki-source-fc9b78c55ddd3ec773fb0af8
    resource: repo://Sources/Search/Prefs.swift
  - id: openwiki-source-dc828845e05bae729f2bad99
    resource: repo://Sources/Search/Store.swift
  - id: openwiki-source-6e6b2e557229ef129b26e320
    resource: repo://Sources/Search/Tab.swift
  - id: openwiki-source-991498b388e5740007ee4bd8
    resource: repo://Sources/Search/Vault.swift
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# Driving Search with ./bench and test worlds

Search is tested largely **while it runs**, by driving the real app over a local socket. This is how a person can keep using their browser while scripts test it, and how isolated "test worlds" exercise everything else.

## Test worlds (`Store.swift`, `fresh.sh`)

A run is a **test run** if `SEARCH_PROBE` is set or the binary runs from `.build/` (so `swift build` output is always a test run). Its **world** is `test` (for `SEARCH_PROBE=1`/empty/`test`) or a name. A world has its own:

- folder `~/Library/Application Support/Search (<world>)/` (socket, session, history, imports…),
- defaults suite `com.officecommun.search.test[.<world>]`,
- WebKit website store (`5E4C…-000000000001`) and extension store (`…2`),
- keychain labels (`Search (<world>)` for passwords, `consent (<world>)` for the bench mark),
- downloads folder (inside the world's folder).

<!-- openwiki: broken internal link [/openwiki/architecture/persistence.md] link "/openwiki/architecture/persistence.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
Full details in [Persistence](/openwiki/architecture/persistence.md). Test runs also differ in behaviour to stay invisible and safe: they never accept links from other apps, never show file pickers, notifications, passkey sheets or capture pickers (they answer or rehearse instead), never ask macOS for location, never bring windows to the front, and keep timers running behind other windows (`inactiveSchedulingPolicy = .none`, no App Nap). `SEARCH_MEASURE` restores shipped throttling for measurements.

**`./fresh.sh`** wipes a world (its folder, defaults suite, and website store) and opens `build/Search.app` with `SEARCH_PROBE` (building it first if missing). `./fresh.sh again` reopens without wiping; `SEARCH_PROBE=NAME ./fresh.sh` targets a named world. If the world's `bench` default is on, it launches **hidden** (`open -g -j`).

## The Bench (`Sources/Search/Bench.swift`)

**Off unless switched on**: Settings › General › *Let a script drive Search* (`bench`).

- **Consent mark.** The defaults key alone opens nothing (any program can write defaults). Turning the switch on in Settings also writes a mark into the **data-protection keychain** under Search's access group (`com.officecommun.search.bench`, `AfterFirstUnlockThisDeviceOnly`), which only apps signed as Search can write. At launch, a `bench` setting without the mark is reset to off, with a note (`benchRefused`). Test runs accept the setting alone (scripts set it with `defaults write`). Copies without the provisioning profile have no access group and keep the switch as is.
- **Socket.** `bench.sock` in the world's folder, `chmod 0600`, and every connection's peer is checked with **`getpeereid` to be the same uid** before anything is read.
- **Protocol.** One JSON object per line in, one per line out, **one request per connection**. Commands that never answer are cut off by the client after about 25 s.
- **Bench tabs** (`Browser.benchOpen`, `Tab.bench`): appended at the end of the row with a **flask** (⚗), **never selected** for you, **never in the session or history**, signed in as you (same store), never pinned, split or slept. `close` refuses non-bench tabs. Turning the socket off closes leftover bench tabs. Unselected bench pages are laid out in an off-screen window at 1280×800 so snapshots have something to capture.
- **Test-run-only commands.** Anything that would act on your browser (`select`, `key`, `press`, `tap`, `resize`, `field`, `bookmark`, `pin`, `middle`, `windows`, `towindow`, `quit`, `ext-answer`, `split`, `sitesearch`, `ai`, `import`, …) answers "only works on a --test run" outside a test world. `--yes` skips extension install prompts only in a test run.
- **Nothing on a screen.** In a test run, any window that comes onto a screen (a sheet, panel, or an unexpected path) is taken off at once and **named in every later answer** (`onScreen`), and `./bench` fails, because a test must never show a window. If the app itself is shown or activated, it is hidden again. `pages on` lets a hidden probe's pages paint off-screen for `picture`; `film` captures animations off-screen.

## The `./bench` CLI

A Python 3 script at the repo root speaking the protocol. `--test` targets world `test`, `--world NAME` a named world, and no flag the **installed browser** (`~/Library/Application Support/Search/bench.sock`). `./bench help` is authoritative.

| Area | Examples |
|---|---|
| Tabs and pages | `tabs`, `open URL [private]`, `go`, `wait ID [S]`, `text`, `eval ID JS [search]` (optionally in Search's own world), `click`, `type`, `submit`, `shot ID PATH`, `close ID\|all`, `sleep ID` |
| Window and chrome | `probe` (panels, modal, field, windows, traffic lights, page frame), `ui KEY VALUE`, `resize`, `strip PATH`, `column PATH`, `fold PATH`, `picture PATH`, `film …`, `hit X Y` |
| Input (test) | `key ID TEXT`, `press CODE CHARS MODS`, `tap ID SELECTOR`, `pull DX`, `middle`, `keyeq` |
| Features (test) | `find`, `split …`, `space …`, `group …`, `tospace`, `pin`, `peek`, `little`, `windows …`, `towindow`, `accounts [ROW]`, `answer once\|always\|no`, `sitesearch …`, `textcheck`, `notifications`, `news`, `update`, `consent` |
| Extensions | `extensions`, `ext-add`, `ext-folder`, `ext-press`, `ext-popup`, `ext-page`, `ext-reload`, `ext-pin`, `ext-enable`, `ext-remove`, `ext-shot`, `ext-menu`, `ext-answer`, `capture`, `capture-stop` |
| Import (test) | `import BROWSER [WHAT] [--profile]`, `import-preview`, `import-file[-start\|-status\|-cancel]` (made-up profiles in the world's `Import/` folder) |
| AI add-on (test) | `ai mock URL`, `ai key`, `ai read ID`, `ai check`, `ai engine`, `ai summarize`, … |
| Timing | `field TEXT [type] [go]`, `bookmark URL [new]`, `fill [STEPS]` — measure how long the window takes to catch up |

## Typical session

```bash
defaults write com.officecommun.search.test bench -bool true
./fresh.sh again                       # opens build/Search.app hidden, world "test"
./bench --test tabs                    # retry until it answers
id=$(./bench --test open https://example.com)
./bench --test wait "$id" 20
./bench --test text "$id"
./bench --test shot "$id" "$TMPDIR/page.png"
./bench --test close "$id"
```

`./fresh.sh` (without `again`) deletes the suite too, which clears the `bench` switch. Follow it with the `defaults write`, quit that process, then `./fresh.sh again`. Never kill or quit by app name: the installed `/Applications/Search.app` has the same bundle id and process name.

## The `search-bench` skill

`skill/search-bench/SKILL.md` is an agent skill that teaches the above: choose a world (and use one for anything that changes chrome, installs extensions, resizes, sends key events or selects tabs); get it listening; only use bench tabs on someone's real browser unless asked; close the ids you opened; write screenshots under `$TMPDIR`; and read errors such as `isn't listening`, `no tab`, `not a bench tab`, `only works on a --test run`.

## Related

<!-- openwiki: broken internal link [/openwiki/testing/test-suites.md] link "/openwiki/testing/test-suites.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Test suites](/openwiki/testing/test-suites.md) — the Python probes built on this, XCTest and standalone harnesses.
<!-- openwiki: broken internal link [/openwiki/tabs/split-view.md] link "/openwiki/tabs/split-view.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Split View](/openwiki/tabs/split-view.md) — `Tests/split_view.py`, whose harness the other probes reuse.
