# Choosing the chat's agent: pi and every ACP agent, found as bb finds them

Status: design, agreed 15 Oct 2026; building on branch `bb/agents-pi-and-every-acp-agent-discovered-thr_4ym88zxjvc`, merged into `sidebar-agent` a phase at a time. Follows [right-sidebar-and-agent.md](right-sidebar-and-agent.md), whose chat runs pi only.

## What changes for the person

Every agent CLI on their login PATH shows up beside pi. A new chat starts on the agent chosen in Settings › AI (pi unless changed), or on the one picked in the chat's footer before the first message is sent; from then on the chat runs on that agent, reopened or not. The suggestion pills, chat titles and Sort Tabs get an agent setting of their own, starting on pi. Nothing changes for anyone who never picks another agent, and all of it stays behind the sidebar's switch.

## Decided

| Question | Answer |
|---|---|
| What may an agent use? | Search's browser tools only, for every agent. ACP client capabilities `fs` and `terminal` off; the agent's own tools switched off by config where it allows; every permission request for anything but a browser tool refused; run in an empty folder of the chat's own. |
| An agent whose own tools can't all be switched off? | Listed anyway, with a plain note in Settings › AI of what still applies ("its own read-only tools may still run, in an empty folder"). |
| Which agents in the first version? | All: pi, the native-ACP ones (opencode, omp, grok, hermes, gemini, cursor-agent, kimi, droid when installed), Claude Code and Codex through their ACP adapters, and custom ones. |
| Claude Code and Codex: ACP adapters, or native as bb does? | ACP adapters, pinned (`@agentclientprotocol/claude-agent-acp` 0.91.0, `@agentclientprotocol/codex-acp` 2.2.2): one code path. A native adapter can join behind the same seam later if one falls short. |
| How do the adapters get there? | Search installs the pinned version into its own folder (`Agents/`) with the person's npm, `--ignore-scripts`, the first time that agent is chosen — **Set up** in the picker and in Settings — as Zed manages its adapters; then runs it with their node. No `npx` at launch. |
| How do browser tools reach ACP agents? | An MCP server over stdio, given in `session/new`: the one transport every ACP agent must accept (hermes accepts nothing else). |
| pi too? | No: pi keeps its extension on fds 3/4, with its clean cancel. Both routes end in `AgentTools.run`, so asking, pausing, marking and gathering stay in one place. |
| Where does a chat's history live? | In the agent's own session, as with pi: Search keeps only the index. Reopened with `session/load`; an agent without `loadSession` keeps its chats only while Search runs. |
| The picker? | A menu in the composer's footer, left of the model menu: every agent found, changeable until the first message, then fixed. Settings › AI: "Agent for new chats" (pi). The chat list shows each chat's agent. |
| Discovery? | A known table, as bb has, matched against the login PATH (`Pi.locate`'s login-shell lookup), once a run, off the main thread; **Refresh** in Settings › AI. Each found agent can be hidden there. |
| Custom agents? | "Add agent…" in Settings › AI: a name and a command line, spoken to over ACP under the same rules. No environment editor. |
| Sign-in? | Not probed ahead. When `session/new` answers ACP's `auth_required`, the chat shows a card: **Sign in** (ACP `authenticate`, for a method of type `agent`), else **Open in Terminal** with the agent's own login command; and **Try again**. Settings shows each agent's last known state: Ready, Needs sign-in, Not used yet. |
| Model and mode menus? | The footer's model menu shows what the chat's agent offers as ACP `configOptions` (model, thought level), set with `session/set_config_option`. Modes stay hidden: they exist to unlock the agent's own tools. An agent's last chosen model is remembered for its next chat; "Model for new chats" stays pi's. |
| The side prompts? | Settings › AI: an agent for suggestions, titles and Sort Tabs (pi), and its model. Another agent there gets a one-shot run over ACP. |

## The seam: the chat talks to its agent as a conversation

Today `Chat` reads pi's RPC messages itself (ChatPi.swift, PR #3: the seam at pi's messages, chosen while there was one adapter). With ACP there are two real adapters, so the seam moves up to the conversation, where both can meet it (Design A of three; B — the adapter owning the transcript — would write "settled" and "Stopped." twice; C — ACP as the chat's language — would make pi, the default, the translated one).

```swift
/// Everything a chat's agent says, in order, on the main actor.
enum AgentSays {
    case user(String)                                       // a message of the person's (reopened)
    case text(id: String, delta: String, done: Bool)        // the answer, streaming
    case thinking(id: String, delta: String, done: Bool)
    case toolStarted(id: String, name: String, args: [String: Any])
    case toolEnded(id: String, failed: Bool, summary: String?, detail: String)
    case settled(Ending?)                                   // nil: finished; or stopped, failed(why)
    case options([AgentOption])                             // what the agent offers: models, thought levels
    case named(String)                                      // a title the agent gave
    case status(String?)                                    // "Retrying…"
    case tool(call: [String: Any], reply: ([String: Any]) -> Void)  // a browser tool, by either route
    case cancelTool                                         // a call given up on (Stop)
    case ended(why: String?)                                // nothing after it
}

/// One running agent, as the chat holds it.
protocol AgentLink: AnyObject {
    func prompt(_ text: String) async throws   // returns once the agent has the message
    func cancel()                               // Stop
    func set(_ option: String, to value: String) async throws
    func stop()                                 // let go: .ended follows
}

/// What a chat needs of an agent kind: the app's adapters are pi's RPC and ACP;
/// the tests' a scripted agent.
struct ChatAgent {
    var start: (_ session: String?, _ hear: @escaping (AgentSays) -> Void) async throws -> (link: AgentLink, session: String?)
    var title: (_ words: String, _ page: String?) async -> String?
}
```

- A reopened chat's history arrives as the same events (pi: its `get_messages` translated; ACP: `session/load`'s replayed updates), so the live and reopened chat can't drift apart (PR #11's bug).
- Every rule of the chat stays in `Chat`: busy, settle, "Stopped.", asks, pause, marks, gather. Every wire detail stays in its adapter.
- Tests: `ChatTests` drive a scripted agent emitting `AgentSays`; each adapter is tested against its real wire — `PiTranscripts` (pi's lines → events) and new ACP transcripts recorded from real agents (ACP lines → events).

## The browser tools over MCP

- `MCPServer` (in the app) speaks MCP: `initialize` (protocol negotiated, up to 2025-11-25), `tools/list` from the catalogue, `tools/call` → `.tool(call, reply)` on the chat's link, `notifications/cancelled` → `.cancelTool`, `ping`. Each tool's annotations come from its kind: reads → `readOnlyHint`; acts → `destructiveHint` where the tool is destructive. A picture goes back as image content; a refusal as `isError`.
- `Search --mcp <socket> <token>` is only a pipe: the Search binary, started by the agent as its stdio MCP server, connects to the chat's socket, sends the token, then copies bytes both ways. Nothing of MCP in it.
- The socket: one per chat, in a 0700 folder of Search's, mode 0600; the peer's uid checked (`getpeereid`); the token one-time and per chat. The agent's environment carries nothing of Search's.

## ACP, the client side

- `initialize`: protocol 1; `clientCapabilities` `fs` read/write false, `terminal` false; `clientInfo` Search and its version.
- `session/new`: `cwd` an empty folder of the chat's (`Chats/agents/<chat id>`), `mcpServers` Search's stdio server; per agent, the options that switch its own tools off and pre-allow Search's (Claude: `_meta.claudeCode.options.tools: []` and `_meta.systemPrompt`; grok: `--disallowed-tools`; opencode: a permission-deny config in `OPENCODE_CONFIG_CONTENT`, with `OPENCODE_CLIENT=acp`; the rest established per agent in phase 4 and noted in Settings).
- `session/prompt`: the `<browser>` context then the person's words, as text. Its answer's `stopReason` settles the chat: `end_turn` finished; `cancelled` stopped; `refusal`, `max_tokens`, `max_turn_requests` a line saying so.
- `session/update`: `user_message_chunk`, `agent_message_chunk`, `agent_thought_chunk`, `tool_call`, `tool_call_update`, `config_option_update`, `session_info_update` (a title) → `AgentSays`; `plan`, `available_commands_update`, `current_mode_update` ignored for now.
- `session/request_permission`: a browser tool's → allowed once (the catalogue asks the person itself); anything else → the reject option; while cancelling → `cancelled`.
- `fs/*`, `terminal/*`, anything unknown → "method not found".
- `session/cancel` on Stop; `session/set_config_option` for the model menu; `authenticate` for sign-in.
- One agent process per chat, stopped when the chat closes, as pi is: stdin closed, then SIGTERM, then SIGKILL, to its process group.
- A one-shot run: spawn, `initialize`, `session/new` with no MCP servers and tools off, the model set, one `session/prompt` (the system prompt ahead of the words), its text collected, the process stopped. Thirty seconds at most, as `PiOnce`.

## Phases

Each a pull request of its own, into `sidebar-agent`; pi the default throughout.

1. **The seam**, with pi as its first adapter: `AgentSays`, `AgentLink`, `ChatAgent`; the pi adapter translates RPC events and `get_messages`; `ScriptedPi` becomes the scripted agent; no change in behaviour.
2. **Browser tools over MCP**: `MCPServer`, the socket, `Search --mcp`; tested end to end with a script as the MCP client.
3. **The ACP adapter**, and a scripted ACP test agent (a script under `Tests/`, no tokens): sessions, updates, load, cancel, permissions mapped and own tools refused, config options.
4. **Discovery and choosing**: the agent table, Settings › AI's agents (found, hidden, custom, sign-in state, what each can't switch off), the footer's picker, the chat list's agent, the sign-in card.
5. **Claude Code and Codex**: the pinned adapters, Set up, their tool-off options.
6. **The side prompts' agent**: the setting, and the one-shot run over ACP.
