# Right sidebar: extension panels and an agent that drives the browser

Status: design, branch `sidebar-agent`. Off by default behind a Settings switch, as every new behaviour is (CONTRIBUTING.md).

## What we're building

A **utility sidebar** on the side of the window away from the tabs, holding one thing at a time:

1. **An extension's side panel** — Chrome's `sidePanel` API, which today opens the panel page as an ordinary tab (`ExtensionShims.openPanel`).
2. **Chat** — an agent you talk to about what's on screen, which can **read and act on any tab** (navigate, click, type, open and close tabs, read text, take pictures), like Dia, Arc's Max or Aside. The agent is an external program spoken to over **ACP** (Agent Client Protocol), or pi's own RPC mode.

The held-back AI add-on (Summarize Page / Ask About This Page…, gated by `AI.shipped = false`) folds into this: its panel goes, its parts stay.

## Decisions (14 Oct 2026)

| Question | Answer |
|---|---|
| Tabs down the right and the utility sidebar? | The utility sidebar moves to the left. It always sits opposite the tab column; with tabs across the top it sits on the right. |
| Which tabs may the agent touch? | Any tab, read and write — not only tabs of its own. |
| Which agents? | ACP agents (opencode, omp, hermes, grok, Claude Code via its ACP adapter, …) and pi. |
| The held-back AI add-on? | Folded into the chat. |
| Agents' own shell/file tools? | Off. The chat agent gets Search's browser tools only. pi is the first-class agent (`--no-builtin-tools`, tools via its extension API); ACP agents run with their tools disabled where they allow it, and their permission requests for anything else are refused by default. A per-agent "let it use its own tools" switch, off, for whoever wants a coding agent in the sidebar. |
| Do chats survive a restart? | Yes, and there are many: a history of chats, each resumable. |
| Per window, or one chat? | Many chats, switched between, as Claude in Chrome does (below). |

## Following Claude in Chrome

Read from its side panel's UI strings (`fcoeoabgfenejglbffodgkkbkcdhcgfn` 1.0.100), what it does and what we take:

| Claude in Chrome | Here |
|---|---|
| A chat works in a **tab group** it owns ("Claude is active in this tab group"); it can see every tab in the group | Each chat gets a **tab group** of its own (tab groups exist, `TabGroup`), named after the chat; tabs it opens go there; you can drag a tab in to share it. It may still act on any tab, as decided, with permission. |
| **Ask before acting** / **Act without asking** ("Skip permissions") | The same two modes per chat; the second needs a confirmation the first time. |
| Per-site grants: **Allow once**, **Always allow actions on this site**, **Allow for all chats**; a list of approved sites, revocable | Allow once / This chat / Always, kept per registrable domain (`agent.site.<domain>`); the Always sites are listed in Settings › AI, each with Forget, and Forget All. |
| **Pauses on a navigation to another domain** ("paused due to a navigation from X to Y") | Same: crossing to a site not yet allowed pauses the turn with a card. |
| Won't buy, create accounts or solve captchas without you | Not taken: no hard-coded limits (see Phase 3); the person's ask/act switch is the control. |
| **Plan mode**: drafts a plan, you **Approve plan** before it acts | Later phase; ACP has `plan` updates already. |
| Steps shown as compact lines: "Navigate to …", "Clicked", "Read page", "Find: …", screenshots with the click marked; **Hide steps** | The same tool-call lines from ACP `tool_call` updates; a picture with the click point for click/type steps. |
| **Stop**, **Pause**/**Resume**; "Claude had to pause" | Stop cancels. Pause (in the pill over the page and under the composer) holds pi before its next step — reading included — until Resume; Stop while paused ends the held step as "Stopped.". A step already under way finishes. |
| Chats saved; **Clear chat**; compaction | Chat history in the header's menu; new chat; compaction where the agent supports it. |
| `/` shortcuts, scheduled tasks, record a workflow | Not in the first version. |
| Model selector | pi's models (`get_available_models`), grouped by provider, in the composer's footer; thinking levels for models that reason. The choice sets this chat's model only (`set_model`, `set_thinking_level`). New chats start on the model set in Settings › Chat (`chat.model` → `--model`), else pi's default. |
| Suggested prompts | Pills over the box for the page in front: "Summarize this page" always, and three things pi suggests for that page, from its text (`PageSuggestions`, one `pi --print` run per address, kept while Search runs; model `chat.suggest.model`; off with `chat.suggests`). Clicking one sends it. |
| Chat titles | The first message's start at once, then 3–5 words from pi (`PiOnce.title`, model `chat.title.model`), given the page's title too; also set as the pi session's name. |

## Phase 0 — the sidebar shell

- `Preferences.utilitySidebar` (Settings › Tabs, off by default) and `utilityWidth` (resizable, remembered; 300–640, default 380).
- `Browser.utility: UtilityPane?` — `.chat` or `.extension(id)`; nil when closed. Per window; the last pane is remembered (`utility.last`).
- Layout in `ContentView`: a column opposite the tab column; the page (or `SplitStage`) gives up that width; with the page as a card, the column sits on the window's ground beside the card. The address field centres on the page between both columns; the peek layer and bookmarks bar keep clear of it.
- Hidden while a page fills the screen; unaffected by ⌘S folding (that folds the tabs, not this).
- View › Show Sidebar Panel (⌥⌘B), and a button in the tab row/column when the switch is on.
- `./bench probe` reports `utility`, `utilityWidth`, `utilityFrame`; `./bench ui utility chat|ext:<id>|off`.

## Phase 1 — extension side panels

- The panel page loads in a `WKWebView` built from the extension's `webViewConfiguration` (as `ExtensionPopup` does), presented to WebKit through a `WKWebExtensionTab` adapter (as `PopupPage` is) so the panel's `chrome.tabs.query({active: true, currentWindow: true})` answers the window's tab.
- Paths: `panelPath` per extension and per tab (`sidePanel.setOptions({tabId, path})`), `enabled: false` hiding it; the panel follows the active tab when its path is per tab.
- `setPanelBehavior({openPanelOnActionClick})` already recorded (`panelOnClick`); `sidePanel.open` honoured only from a user gesture (`Extensions.justUsed`); `sidePanel.close`; `onOpened`/`onClosed` events.
- The header lists every extension with a panel; one panel view kept per extension while it is open, released when closed.
- Test with Claude in Chrome, Bitwarden, Grammarly, and a minimal unpacked panel extension under `Tests/`.

## Phase 2 — chat, the client side

### The agent process

- **ACP**: JSON-RPC 2.0 over the agent's stdio. Search is the client: `initialize` (client capabilities: no `fs`, no `terminal`), `session/new` (with `cwd` and `mcpServers`), `session/prompt`, streamed `session/update` (message chunks, thoughts, tool calls, plans), `session/request_permission`, `session/cancel`.
- **pi**: `pi-acp` (the npm ACP adapter, used by Zed) does **not** pass ACP `mcpServers` through to pi, so browser tools wouldn't reach it. pi is spoken to directly instead, as bb does: `pi --mode rpc --no-session --no-builtin-tools --extension <search-tools.js>`, JSON lines (`prompt`, `steer`, `abort`, `get_state`, events), with an extension that registers the browser tools and calls back into Search.
- Agents are found on the user's login-shell `PATH` (an app started from the Dock doesn't inherit it) plus known install places; Settings › Chat lists what was found and lets you add a custom command.
- One process per chat; stopped when the chat closes or after idle time. Started with only what it needs; no Search secrets in its environment.

### The browser tools (MCP)

- One **browser-control core** extracted from `Bench.swift`'s command handling, used by both the bench socket and the agent. Commands it already has: list tabs, open, go, wait, text, eval, click, type, submit, key, tap, picture.
- Exposed to ACP agents as an **MCP server over stdio**: the Search binary itself in a helper mode (`Search --mcp <socket> <token>`), bridging stdio to a per-chat Unix socket inside Search's folder, mode 0600, same-uid check, one-time token. No new dependency.
- Tools (first cut): `tabs_list`, `tab_read` (visible text, as `AIPage` reads it, fenced), `tab_screenshot`, `tab_open`, `tab_navigate`, `tab_close`, `tab_select`, `page_click`, `page_type`, `page_press`, `page_scroll`, `page_find`, `page_query` (elements with roles, names and a stable ref, from Search's own content world).
- Element references come from an accessibility-style snapshot built in `Web.world`, not raw CSS selectors the page could steer.

### The panel

- Messages stream in; tool calls show as compact lines ("Clicked “Sign in” on github.com"); permission requests as cards with Allow once / Allow for this site / Deny.
- The current tab (and any tab you @-mention) is attached as context.
- From the add-on: page reading and injection fencing (`AIPage`), the stray-address check, keychain-held keys (`AIKeys`) for agents that want one, the on-device engine (later, as a provider).

## Phase 3 — acting

Decided 14 Oct 2026: **no hard-coded guardrails** — not around passwords, private tabs, kinds of page, purchases or anything else. The only control is the person's, per chat:

- **Ask before acting** (the default): each act shows a card — Allow once, This chat (the site, for the rest of the chat), Always (the site, every chat, `agent.site.<domain>`), Deny. Acts waiting together are asked in turn; a refusal tells the agent to stop and ask.
- **Act without asking**: no cards.
- A pill over the page while the agent acts or waits for an answer, with Pause/Resume and Stop (`abort`, waiting asks refused).
- The tab pi acts in is marked: a sparkle on its row and an outline round its page, until the turn settles, is stopped, or pi exits.
- Page content is still handed to the agent fenced as the website's words, so it knows what it is reading.

Tools: browser_find (elements with references kept in Search's own world), browser_open, browser_navigate (address, back, forward, reload), browser_select, browser_close, browser_click, browser_type (native setter + input events; select options; contenteditable), browser_press, browser_scroll. Clicks and keys are DOM events from Search's own world, not system input, so pages that insist on a trusted click (file pickers, pop-ups) won't take them; a link to a new tab is opened as one. Tabs the agent opens go in a tab group of the chat's when groups are on.

## Phase 4 — polish

pi parity with ACP agents, model/mode pickers (ACP `configOptions`), session history (`session/load`), the held-back add-on's providers as a built-in agent, tests: probe tests through the bench for the sidebar and panels; a stub ACP agent (a small script under `Tests/`) driving the tools in a test world.

## Files

| New | Purpose |
|---|---|
| `UtilitySidebar.swift` | the column, header, resize edge, pane switching |
| `SidePanels.swift` | extension panel views and their tab adapter |
| `ACPClient.swift` | JSON-RPC over stdio, sessions, updates, permissions |
| `PiClient.swift` | pi RPC mode |
| `AgentTools.swift` | the browser-control core and the MCP bridge |
| `ChatPanel.swift` | the chat UI |

Changed: `App.swift` (layout), `Prefs.swift`, `Browser.swift` (`utility`), `Shortcuts.swift`, `ExtensionShims.swift` (`sidePanel.*`), `Bench.swift` (core extracted), `Settings.swift`, `WhatsNew.swift`.

## Chat history

**A chat is a pi session.** pi keeps the whole conversation itself (an append-only JSONL tree), and its RPC mode has what a chat list needs: `new_session`, `switch_session {sessionPath}`, `get_messages` (to draw a chat reopened), `set_session_name`, `compact`, `fork`. So Search keeps no transcript, only a small index, `chats.json` in the Store folder: per chat its id, title, agent, pi session path, tab group, permission mode, and when it was last used.

- pi runs with `--session-dir <Store.folder>/Chats`, so the browser's chats don't mix with the sessions of pi in a terminal, and a test world's stay in the test world.
- Not `--no-session` (bb's choice, because bb keeps its own transcripts).
- Site grants are Search's (`agent.<origin>` settings), not the session's.
- ACP agents: a chat is their session too, reopened with `session/load` where the agent offers it (`loadSession` capability). One that doesn't keeps its chats only while Search runs.

## Sort Tabs

A button beside the bookmarks (`SortDoor`, TabSort.swift), off until switched on in Settings › AI. pi gets each loose tab's title and address — never page text, so sleeping tabs count — in one `pi --print` run on the model set there (`tabs.sort.model`), and answers with groups by topic. Applied at once: new groups of two tabs or more, and tabs added to the person's own groups by name; their groups are never renamed or emptied. Pins, private tabs and the bench's tabs stay put; a Split View pair moves together. The line that says what happened has Undo (`Browser.restoreGroups`), which puts every tab back in its group and place. Tab groups are switched on if they were off. `./bench sorttabs seed|run|undo|state` drives it in a test world.

Settings › Chat became Settings › AI (the page's case is still `.chat`): the sidebar panel, the chat's three models, page suggestions, the sites allowed for good, and Sort Tabs with its model.
