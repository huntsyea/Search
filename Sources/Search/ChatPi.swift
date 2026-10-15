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
