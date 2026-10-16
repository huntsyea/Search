---
type: feature subsystem
title: "AI add-on: summarize and ask"
description: The opt-in AI add-on (Summarize Page, Ask About This Page) — providers, keychain-held keys, the isolated request client, how page text is extracted and fenced against prompt injection, OpenRouter PKCE sign-in, and the sandboxed on-device engine. It is compiled in but held back from 1.0.5 by `AI.shipped = false`.
tags: [ai, llm, privacy, security, keychain, sandbox, prompt-injection]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-15T01:51:20.926Z
sources:
  - id: openwiki-source-4faa2a273ebeaf9750241d77
    resource: repo://engine.sh
  - id: openwiki-source-8ab30e7767ef9b965c223145
    resource: repo://Engine/search-ai-engine.cpp
  - id: openwiki-source-39802fe38eb67eba4412c976
    resource: repo://Sources/Search/AI.swift
  - id: openwiki-source-2c495d348021c3fed3496fd1
    resource: repo://Sources/Search/AIAssist.swift
  - id: openwiki-source-f80ef74a05dca6cccac8d1ac
    resource: repo://Sources/Search/AIClient.swift
  - id: openwiki-source-a3a14ec06b37c5a5dbbdc311
    resource: repo://Sources/Search/AIEngine.swift
  - id: openwiki-source-45430fe9b869897e3e603611
    resource: repo://Sources/Search/AIPage.swift
  - id: openwiki-source-b591ea3f347e009741edaf86
    resource: repo://Sources/Search/AISignIn.swift
  - id: openwiki-source-fc9b78c55ddd3ec773fb0af8
    resource: repo://Sources/Search/Prefs.swift
  - id: openwiki-source-84006d5d987b894a14994de8
    resource: repo://Sources/Search/Settings.swift
  - id: openwiki-source-155f858ec9b80172d6bbb9eb
    resource: repo://Sources/Search/Updater.swift
generated: { by: "claude-code", at: "2026-10-15T01:51:20.926Z" }
---

# AI add-on: summarize and ask

The AI add-on gives one page at a time a **summary** or answers **questions about it**. The model runs where the user chooses: on this Mac (Search's own engine), in a local app (Ollama, LM Studio), or at a provider the user has a key or account with (Anthropic, OpenAI, Google Gemini, OpenRouter).

> **Status: not shipped.** `AI.shipped` is `false` (`Sources/Search/AI.swift`). With it off, nothing of the add-on shows or runs: no Settings › AI page, no menu items, no Welcome/What's New lines, and a pref left on by a test build reads as off. Test runs (`Store.testing`) still exercise it. Flipping that one constant brings it back.

## Files

| File | Responsibility |
|---|---|
| `AI.swift` | `AI.shipped` gate, `AIProvider` (hosts, default models, wire format), `AIKeys` (keychain) |
| `AIAssist.swift` | `Assistant` conversation object, the first-use notice, `Browser.summarizePage()/askAboutPage()`, `AssistantPanel`, `AISettings` |
| `AIClient.swift` | Network requests to remote/local-app providers, SSE streaming |
| `AIPage.swift` | What text is read from the page, the system prompt and fence, the injection heuristics, the "stray" check on answers |
| `AISignIn.swift` | OpenRouter OAuth-with-PKCE sign-in |
| `AIEngine.swift` | Downloading, verifying, launching and talking to the on-device engine; `AIDownload` |
| `Engine/search-ai-engine.cpp`, `engine.sh`, `Engine/engine.entitlements` | The engine program (llama.cpp at a pinned commit) and its build |

## Flow of one request

1. `Browser.startAssistant(summary:)` checks: shipped or testing, the add-on is on and a provider chosen (otherwise it opens Settings › AI), the tab is an `http`/`https` page, and — for a **private tab** — only a local provider is allowed. "On this Mac" also requires the engine to be `.ready`.
2. An `Assistant` is created for the tab. It reads the page with `AIPage.read(tab)` and, for a summary, asks immediately.
3. The first time a **remote** provider is used, `AIAssist.notice(for:)` says what will be sent (page text, address, question) and the request waits until the user agrees; agreement is remembered per provider under the `ai.told.<provider>` setting.
4. The key is read from the keychain right before sending and dropped with the request. The stream comes either from `AIEngine.shared.stream` (on this Mac) or from `AIClient.shared.stream`.
5. Pieces are appended to the current turn. An answer longer than `Assistant.longest` (16,000 characters) is cut off.
6. When the turn finishes, `AIPage.strays` runs off the main thread and marks web addresses, emails and phone numbers in the answer that the page did not have. A failed turn is removed from the message history so it does not shape later questions.

Nothing is persisted: closing the panel discards the conversation.

## Providers and keys

<!-- openwiki: broken internal link [/openwiki/testing/bench-and-test-worlds.md] link "/openwiki/testing/bench-and-test-worlds.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
`AIProvider.base` is the **only** host a provider's requests go to. Remote providers use https on their API host; Ollama (`127.0.0.1:11434`) and LM Studio (`127.0.0.1:1234`) use loopback http; `thisMac` never goes over the network. In a test run every provider can be pointed at a loopback mock server (`AIProvider.mock`, set by `./bench ai mock URL`). `./bench ai …` also stores test keys, reads a tab as `AIPage` would, runs the stray check, drives sign-in, points at a test engine and model folder, and summarizes or asks on a tab (see [bench](/openwiki/testing/bench-and-test-worlds.md)).

Requests come in three wire formats (`AIProvider.Wire`): OpenAI chat completions (OpenAI, OpenRouter, Ollama, LM Studio), Anthropic messages, Gemini `streamGenerateContent`. Answers are capped at 2048 output tokens. OpenRouter requests ask for zero-data-retention providers only (`provider.zdr`).

`AIKeys` keeps keys in the **data protection keychain** under service `com.officecommun.search.ai`, account `provider@host`, `WhenUnlockedThisDeviceOnly`, never synchronizable. Only the last four characters are stored as the item comment, so Settings can show a hint without reading the key. A build without Search's access-group entitlement (a source build) gets `errSecMissingEntitlement` and keeps **no** key rather than storing it somewhere weaker. Test runs keep keys in memory only.

## The isolated client (`AIClient`)

- Its own ephemeral `URLSession`: no cookies, cache, or credential storage, TLS 1.2+, 60 s request / 300 s resource timeouts.
- `AIClient.allowed(_:for:)` permits only https to the provider's host, or http/https to loopback for local providers; URLs with user/password are refused. The app allows arbitrary loads for pages, so this check, not App Transport Security, is the guard.
- **Redirects are always refused**, so a key can never follow a redirect to another host.
- The key goes in a header (`x-api-key`, `x-goog-api-key`, or `Authorization: Bearer`), never the URL.
- Nothing about a request is logged; provider error bodies are truncated to 4 KB and any echoed key is removed before being shown.

## Page text and prompt-injection framing (`AIPage`)

The page is read by a script run in **Search's own content world** (`Web.world`), which page scripts cannot reach. It keeps only text a person could see: hidden, transparent, tiny, clipped "screen-reader only", off-screen, or same-colour-as-background text is dropped, as are form inputs, passwords, other frames and other tabs. It prefers the article (as Reader finds it). Text over `AIPage.limit` (24,000 chars, ~6k tokens) keeps the first two-thirds and last third with a `[…]` marker.

In the prompt the page — including its title and its address stripped of query, fragment and credentials — sits between `<page-…>` markers made fresh for each conversation (`newFence()`); any copy of the marker inside the page is removed. The system prompt tells the model the fenced text is the website's, not the user's, never to follow instructions in it, to answer only from the page, and to output plain text with no added links, numbers or emails.

`addressesAI` flags text that looks written for a model ("ignore previous instructions", `System:` lines, ChatML tokens, "you are an AI…"), and the panel warns the answer may have been steered. The code is explicit that framing "helps and guarantees nothing"; the real limits are that the model can only return text and that strays are flagged.

## OpenRouter sign-in (`AISignIn`)

OAuth with PKCE, no client secret. `start(in:)` makes a 32-byte random verifier, opens `openrouter.ai/auth` in a foreground tab with an S256 challenge, and remembers the flow (tab id, verifier, start time) in memory. The callback URL `https://officecommun.com/search/ai/callback` is **never loaded**: `intercept` takes it in the navigation policy only if it is a main-frame load in the flow's own tab, arriving from openrouter.ai, within 10 minutes. The code is exchanged for a key (`AIClient.exchange`) and saved like a pasted key; the tab is closed on success.

## On-device engine (`AIEngine`)

Neither the engine nor the model ships in the app. Turning on "On this Mac" downloads:

- the **engine**, as offered by the signed update feed (`ai.engine` in the appcast, parsed in `Updater`), with version, URL, SHA-256 and size (< 64 MB);
- the **model**, Qwen3 1.7B Q4_K_M GGUF, from a pinned Hugging Face URL with pinned size and SHA-256 (`AIEngine.model`).

`AIDownload.fetch` refuses redirects and checks size and hash. Files live under `<Store.folder>/AI/Engine/<version>/` and `AI/Models/<sha256>.gguf`. Only Apple Silicon is supported (`#if arch(arm64)`); an Intel build translated by Rosetta is detected via `sysctl.proc_translated`.

Before every launch:

- `trusted(_:)` validates the engine's static signature (strict, all architectures) against Office Commun's Developer ID for `com.officecommun.search.ai-engine` (`Updater.developerID`), or just the identifier in a test run, and requires the **only** entitlement to be `com.apple.security.app-sandbox`.
- `openModel` opens the model, hashes the opened file, and hands that descriptor to the engine as fd 3, so the file can't be swapped between check and use.
- `spawn` uses `posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_START_SUSPENDED`, passing only stdin, stdout, `/dev/null` as stderr, and the model fd, with no environment. It disclaims responsibility so the engine answers for itself in TCC. The suspended process is checked again (`trustedRunning(pid)`) before it is resumed.
- The engine has two minutes to report ready, and is stopped after five idle minutes.

**Engine protocol** (newline-delimited JSON over stdio, documented at the top of `search-ai-engine.cpp`): requests `{"id","system","messages","max_tokens":768,"temperature":0.2}` and `{"stop":id}`; replies `{"ready":true,"context":…}`, `{"id","piece"}`, `{"id","done":true,…}`, `{"id","error"}`. The engine builds Qwen3's ChatML prompt with thinking disabled and tokenizes page/user text as plain text, never as control tokens, so a page containing `<|im_end|>` cannot end its turn.

`engine.sh` fetches llama.cpp at a pinned tag/commit, verifies it, builds static arm64 (Metal) and x86_64 (CPU) with no network code, links the helper, strips, and signs with hardened runtime + sandbox. Ad-hoc signed engines are accepted only in test runs. Output goes to `build/engine/`.

## Related

<!-- openwiki: broken internal link [/openwiki/page/page-tools.md] link "/openwiki/page/page-tools.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Page tools](/openwiki/page/page-tools.md) — Reader, whose article detection AIPage reuses.
<!-- openwiki: broken internal link [/openwiki/operations/self-update.md] link "/openwiki/operations/self-update.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Self-update](/openwiki/operations/self-update.md) — the signed feed that offers the engine and the Developer ID requirement.
<!-- openwiki: broken internal link [/openwiki/operations/build-and-release.md] link "/openwiki/operations/build-and-release.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Build and release](/openwiki/operations/build-and-release.md) — signing and entitlements.
