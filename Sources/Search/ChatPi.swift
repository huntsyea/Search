import Foundation

// What a chat needs of pi, as one seam: a way to start one on a session and
// hear everything it says, and a way to name a chat. The app's is pi itself,
// in its RPC mode (`ChatPi.rpc`); the tests' is a scripted one, so the chat's
// asks, pauses, stops and lines can be checked without a provider.

/// Everything a chat's pi says, in the order it says it, on the main actor.
enum PiSays {
    /// A session event: a line of pi's output that isn't a response.
    case event([String: Any])
    /// A call to one of the browser's tools, answered with `reply` exactly once.
    case tool([String: Any], reply: ([String: Any]) -> Void)
    /// A tool call pi gave up on (Stop) while Search was still on it.
    case cancel
    /// pi ended, and why if it said. Nothing is heard after it, and the
    /// link's requests fail from then on. It may come before `start` returns.
    case exit(String?)
}

/// One running pi, as the chat holds it.
@MainActor
protocol PiLink: AnyObject {
    /// A command, and its response's data; throws when pi refuses it or has ended.
    func request(_ command: [String: Any]) async throws -> [String: Any]
    /// Let go of it: pi is asked to end, and `.exit` follows.
    func stop()
}

@MainActor
struct ChatPi {
    /// pi started on `session` (a session file), or on a new session when nil,
    /// with `hear` told everything it says from then on.
    var start: (_ session: String?, _ hear: @escaping (PiSays) -> Void) async throws -> PiLink
    /// A chat's name, in a few words, from its first message and the page it
    /// was sent on; nil when none came.
    var title: (_ words: String, _ page: String?) async -> String?
}

// MARK: - the app's pi

extension ChatPi {
    /// The app's pi: the person's own, in its RPC mode, on a session file.
    static let rpc = ChatPi(
        start: { session, hear in
            let process = PiProcess()
            process.onEvent = { hear(.event($0)) }
            process.onTool = { call, reply in hear(.tool(call, reply: reply)) }
            process.onCancel = { hear(.cancel) }
            process.onExit = { hear(.exit($0)) }
            let folder = Chats.folder
            try FileManager.default.createDirectory(at: Chats.sessions, withIntermediateDirectories: true)
            let tools = folder.appendingPathComponent("search-browser.mjs")
            try AgentTools.extensionSource.write(to: tools, atomically: true, encoding: .utf8)
            // The person's own pi — their providers, models and keys, which
            // can come from their packages — but only the browser's tools:
            // none of pi's own (no shell, no files), none of their
            // extensions' or MCP servers', no skills or project files that
            // would tell it to use them.
            var arguments = ["--mode", "rpc", "--session-dir", Chats.sessions.path]
                + Pi.confined(tools: AgentTools.names)
                + ["--extension", tools.path, "--system-prompt", AgentTools.systemPrompt]
            if let session {
                arguments += ["--session", session]
            } else {
                // A new chat starts on the model chosen in Settings › AI (else
                // pi's own default); an earlier one keeps what its session used.
                if let chosen = Store.settings.string(forKey: Chats.modelKey), !chosen.isEmpty { arguments += ["--model", chosen] }
            }
            try await Task.detached(priority: .userInitiated) {
                try process.start(arguments: arguments, directory: folder, environment: ["SEARCH_CHAT": "1"])
            }.value
            return process
        },
        title: { words, page in
            await PiOnce.title(for: words, on: page)
        }
    )
}

// MARK: - pi as the chat's agent

extension ChatAgent {
    /// pi as a chat's agent, over `pi` — nil: its RPC mode, as the app runs it,
    /// a scripted pi in tests.
    static func pi(_ pi: ChatPi? = nil) -> ChatAgent {
        let pi = pi ?? .rpc
        return ChatAgent(name: "pi", start: { session, hear in
            try await PiAgent.start(pi, session, hear)
        }, title: { words, page in
            await pi.title(words, page)
        })
    }
}

/// One running pi, as the chat's agent: it turns what pi says (PiSays, pi's
/// RPC events) into what a chat hears (AgentSays), and the chat's requests
/// back into pi's commands. Pi's wire never leaves this file.
@MainActor
private final class PiAgent: AgentLink {
    private let hear: (AgentSays) -> Void
    /// This pi's own, so a pi started again can't name an item an earlier one named.
    private let run = String(UUID().uuidString.prefix(8))
    private var link: PiLink?
    private var session: String?
    private var messageCount = 0
    /// Content blocks of the assistant message streaming now, by index.
    private var streaming: [Int: String] = [:]
    private var models: [(provider: String, id: String, name: String, reasoning: Bool)] = []
    /// What pi uses now, as its answers last said: kept so a refused or
    /// failed ask doesn't clear what was known.
    private var current: String?
    private var thinking: String?
    private var levels: [String] = []

    private init(hear: @escaping (AgentSays) -> Void) {
        self.hear = hear
    }

    /// pi started on `session`, or on a new session when it is nil or gone,
    /// telling `hear` everything it says from then on — the session's history
    /// first, as it was said live.
    static func start(_ pi: ChatPi, _ session: String?, _ hear: @escaping (AgentSays) -> Void) async throws -> AgentLink {
        let agent = PiAgent(hear: hear)
        // A session file that is gone is started anew, as if nil: pi would
        // otherwise refuse to start.
        let file = session.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        let link = try await pi.start(file) { [weak agent] said in
            // A pi let go of is told no, so it stops waiting on a call the
            // chat will never answer; one the chat holds is heard here.
            guard let agent else {
                if case let .tool(_, reply) = said {
                    reply(["content": [["type": "text", "text": "Stopped."]], "isError": true, "details": ["summary": "Stopped."]])
                }
                return
            }
            agent.heard(said)
        }
        agent.link = link
        agent.session = file
        if file != nil {
            do {
                let data = try await link.request(["type": "get_messages"])
                agent.replay(data["messages"] as? [[String: Any]] ?? [])
            } catch {
                // The history is part of starting: a pi that can't give it
                // is let go of, and the start reports why.
                link.stop()
                throw error
            }
        }
        // Asked without waiting, as the chat does: the model menu fills in
        // behind the first message.
        Task { await agent.learnOptions() }
        return agent
    }

    private func heard(_ said: PiSays) {
        switch said {
        case let .event(event):
            translate(event)
        case let .tool(call, reply):
            hear(.tool(call, reply: reply))
        case .cancel:
            hear(.cancel)
        case let .exit(why):
            hear(.exit(why))
        }
    }

    /// One line of pi's output, said as the conversation: the same events the
    /// chat read itself before, now said instead of drawn.
    private func translate(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "message_start":
            guard let message = event["message"] as? [String: Any] else { return }
            if message["role"] as? String == "user" {
                // The chat takes its own context off again when it draws it.
                hear(.user(Chat.text(of: message["content"])))
            } else if message["role"] as? String == "assistant" {
                messageCount += 1
                streaming = [:]
            }
        case "message_update":
            guard let update = event["assistantMessageEvent"] as? [String: Any],
                  let index = update["contentIndex"] as? Int else { return }
            let kind = update["type"] as? String ?? ""
            let delta = update["delta"] as? String ?? ""
            if kind == "text_delta" {
                put(index, .assistant, delta, whole: false, done: false)
            } else if kind == "thinking_delta" {
                put(index, .thinking, delta, whole: false, done: false)
            } else if kind == "text_end", let content = update["content"] as? String {
                put(index, .assistant, content, whole: true, done: true)
            } else if kind == "thinking_end", let content = update["content"] as? String {
                put(index, .thinking, content, whole: true, done: true)
            }
        case "message_end":
            guard let message = event["message"] as? [String: Any], message["role"] as? String == "assistant" else { return }
            for id in streaming.values { hear(.done(id: id)) }
            if let end = PiAgent.ending(message) { hear(.line(kind: end.kind, text: end.text)) }
        case "tool_execution_start":
            guard let call = event["toolCallId"] as? String else { return }
            hear(.toolStarted(id: call, name: event["toolName"] as? String ?? "", args: event["args"] as? [String: Any] ?? [:]))
        case "tool_execution_end":
            guard let call = event["toolCallId"] as? String else { return }
            let result = event["result"] as? [String: Any] ?? [:]
            hear(.toolEnded(id: call, failed: event["isError"] as? Bool ?? false,
                            summary: (result["details"] as? [String: Any])?["summary"] as? String,
                            detail: Chat.text(of: result["content"])))
        case "auto_retry_start":
            hear(.status("Retrying…"))
        case "auto_retry_end":
            hear(.status(nil))
        case "session_info_changed":
            if let name = event["name"] as? String, !name.isEmpty { hear(.named(name)) }
        case "agent_settled":
            hear(.settled)
        default:
            break
        }
    }

    /// Words of the item streaming at `index`: the id it is known by is the
    /// message it belongs to and its place in it, so an item reopened is the
    /// same item.
    private func put(_ index: Int, _ kind: Chat.Item.Kind, _ text: String, whole: Bool, done: Bool) {
        let id = "\(run)-\(messageCount)-\(index)"
        streaming[index] = id
        hear(.text(id: id, kind: kind, text: text, whole: whole, done: done))
    }

    /// The session's history as pi kept it, said the way it was said live.
    private func replay(_ messages: [[String: Any]]) {
        for (n, message) in messages.enumerated() {
            switch message["role"] as? String {
            case "user":
                hear(.user(Chat.text(of: message["content"])))
            case "assistant":
                for (i, block) in (message["content"] as? [[String: Any]] ?? []).enumerated() {
                    switch block["type"] as? String {
                    case "text":
                        let text = block["text"] as? String ?? ""
                        if !text.isEmpty { hear(.text(id: "m\(n)-\(i)", kind: .assistant, text: text, whole: true, done: true)) }
                    case "thinking":
                        let text = block["thinking"] as? String ?? ""
                        if !text.isEmpty { hear(.text(id: "m\(n)-\(i)", kind: .thinking, text: text, whole: true, done: true)) }
                    case "toolCall":
                        let id = block["id"] as? String ?? "\(n)-\(i)"
                        hear(.toolStarted(id: id, name: block["name"] as? String ?? "",
                                          args: block["arguments"] as? [String: Any] ?? [:]))
                    default:
                        break
                    }
                }
                if let end = PiAgent.ending(message) { hear(.line(kind: end.kind, text: end.text)) }
            case "toolResult":
                guard let call = message["toolCallId"] as? String else { continue }
                hear(.toolEnded(id: call, failed: message["isError"] as? Bool ?? false,
                                summary: (message["details"] as? [String: Any])?["summary"] as? String,
                                detail: Chat.text(of: message["content"])))
            default:
                break
            }
        }
        messageCount = messages.count
    }

    /// The line an assistant message ends on, live or reopened: the person's
    /// Stop, or the model failing; none when it just finished.
    private static func ending(_ message: [String: Any]) -> (kind: Chat.Item.Kind, text: String)? {
        var stop = message["stopReason"] as? String
        // Stopped between steps, the request in flight fails as an error:
        // still the person's Stop, not a failure.
        if stop == "error", (message["errorMessage"] as? String)?.localizedCaseInsensitiveContains("aborted") == true { stop = "aborted" }
        switch stop {
        case "error": return (.error, message["errorMessage"] as? String ?? "The model couldn't answer.")
        case "aborted": return (.note, "Stopped.")
        default: return nil
        }
    }

    // MARK: - the chat's requests

    func prompt(_ text: String) async throws {
        guard let link else { throw PiProcess.Failure(why: "pi isn't running") }
        _ = try await link.request(["type": "prompt", "message": text])
        // The session file pi keeps the chat in, once it has one: the chat
        // lists it from then on.
        if session == nil, let state = try? await link.request(["type": "get_state"]),
           let file = state["sessionFile"] as? String {
            session = file
            hear(.session(file))
        }
    }

    func cancel() {
        guard let link else { return }
        Task { _ = try? await link.request(["type": "abort"]) }
    }

    func set(_ option: String, to value: String) async throws {
        guard let link else { throw PiProcess.Failure(why: "pi isn't running") }
        switch option {
        case "model":
            // pi wants the provider and id apart, not the menu's one value.
            if let m = models.first(where: { $0.provider + "/" + $0.id == value }) {
                _ = try await link.request(["type": "set_model", "provider": m.provider, "modelId": m.id])
            } else if let cut = value.firstIndex(of: "/") {
                // The list may not have come yet (the menu still shows the
                // last pi's): the value itself names a provider and an id.
                _ = try await link.request(["type": "set_model", "provider": String(value[..<cut]),
                                            "modelId": String(value[value.index(after: cut)...])])
            } else {
                throw PiProcess.Failure(why: "pi has no model \(value)")
            }
        case "thinking":
            _ = try await link.request(["type": "set_thinking_level", "level": value])
        default:
            throw PiProcess.Failure(why: "pi has no option \(option)")
        }
        await learnState()
    }

    func name(_ title: String) {
        guard let link else { return }
        Task { _ = try? await link.request(["type": "set_session_name", "name": title]) }
    }

    func stop() { link?.stop() }

    // MARK: - options

    /// What pi has to offer, asked as it starts: its models, then what this
    /// chat uses now.
    func learnOptions() async {
        if let list = try? await link?.request(["type": "get_available_models"]),
           let raw = list["models"] as? [[String: Any]] {
            models = raw.compactMap { m in
                guard let provider = m["provider"] as? String, let id = m["id"] as? String else { return nil }
                return (provider: provider, id: id, name: m["name"] as? String ?? id, reasoning: m["reasoning"] as? Bool ?? false)
            }
        }
        await learnState()
    }

    /// What pi uses now, said as the chat's options. Every ask is `try?`, and
    /// an ask that didn't come leaves what was known in place.
    private func learnState() async {
        if let state = try? await link?.request(["type": "get_state"]) {
            if let m = state["model"] as? [String: Any], let provider = m["provider"] as? String, let id = m["id"] as? String {
                // A model pi uses that its list didn't name — an earlier
                // chat's, say — is added, so the menu can name it.
                if !models.contains(where: { $0.provider == provider && $0.id == id }) {
                    models.append((provider: provider, id: id, name: m["name"] as? String ?? id, reasoning: m["reasoning"] as? Bool ?? false))
                }
                current = provider + "/" + id
            }
            if let level = state["thinkingLevel"] as? String { thinking = level }
        }
        if let data = try? await link?.request(["type": "get_available_thinking_levels"]),
           let list = data["levels"] as? [String] {
            levels = list
        }
        var options = [AgentOption(
            id: "model", name: "Model", category: .model, current: current,
            choices: models.map { AgentOption.Choice(value: $0.provider + "/" + $0.id, name: $0.name, group: $0.provider) }
        )]
        // How hard it thinks only means something for a model that reasons.
        let reasons = models.first { $0.provider + "/" + $0.id == current }?.reasoning ?? false
        if reasons, !levels.isEmpty {
            options.append(AgentOption(
                id: "thinking", name: "Thinking", category: .thought, current: thinking,
                choices: levels.map { AgentOption.Choice(value: $0, name: $0.capitalized) }
            ))
        }
        hear(.options(options))
    }
}
