import Foundation

// ACP agents, spoken to as a client (docs/design/agents.md, "ACP, the client
// side"); this file is the wire.

/// An error an ACP agent answered with.
struct ACPError: LocalizedError {
    let code: Int
    let message: String
    let data: Any?
    var errorDescription: String? {
        // Some agents say only "Internal error" and put the real reason in
        // data; show both, kept short.
        var text = message
        if let detail = ACPError.detail(data) { text += "\n" + detail }
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
    }
    /// ACP's "auth_required": the agent wants the person to sign in first.
    static let authRequired = -32000

    /// What `data` says of why, when it does.
    private static func detail(_ data: Any?) -> String? {
        if let text = data as? String, !text.isEmpty { return text }
        guard let object = data as? [String: Any] else { return nil }
        for key in ["details", "message"] {
            if let text = object[key] as? String, !text.isEmpty { return text }
        }
        return nil
    }
}

/// The agent wants the person to sign in first, and how it can be done.
struct AgentSignIn: LocalizedError {
    struct Method: Equatable {
        let id: String
        let name: String
        let description: String?
        /// The command to run in a terminal, when the method is one the
        /// person runs themselves; nil when the agent does it itself.
        let terminal: [String]?
        /// Variables that command needs set, when it has any.
        let environment: [String: String]
    }
    let agent: String
    let methods: [Method]
    /// True when the method Search tried was rejected: the agent's remembered
    /// sign-in no longer works, and is forgotten.
    var stale = false
    var errorDescription: String? { "\(agent) needs you to sign in first." }
}

extension AgentSignIn {
    /// How the agent says it can be signed in, from initialize's `authMethods`:
    /// a method the agent runs itself (asked with `authenticate`), one run in
    /// a terminal, or one that only needs a variable set.
    static func methods(_ raw: Any?, path: String, arguments: [String]) -> [Method] {
        (raw as? [[String: Any]] ?? []).compactMap { method in
            guard let id = method["id"] as? String, let name = method["name"] as? String else { return nil }
            // The client runs the agent's own program with the same launch
            // settings it starts it with, plus the method's own args.
            let terminal = method["type"] as? String == "terminal"
                ? [path] + arguments + (method["args"] as? [String] ?? [])
                : nil
            return Method(id: id, name: name, description: method["description"] as? String,
                          terminal: terminal, environment: AgentSignIn.environment(method["env"]))
        }
    }

    /// A method's `env`: an object, or a list of `{name, value}`.
    static func environment(_ raw: Any?) -> [String: String] {
        if let object = raw as? [String: String] { return object }
        var out: [String: String] = [:]
        for pair in raw as? [[String: Any]] ?? [] {
            if let name = pair["name"] as? String, let value = pair["value"] as? String { out[name] = value }
        }
        return out
    }
}

/// One ACP agent's process, spoken to in JSON-RPC 2.0 a line at a time, on a LineProcess.
final class ACPConnection: @unchecked Sendable {
    /// A notification from the agent (session/update), on the main thread, in the order it was said.
    var onNotification: ((_ method: String, _ params: [String: Any]) -> Void)?
    /// A request from the agent, on the main thread, in order; `respond` exactly once with a result, or an ACPError.
    var onRequest: ((_ method: String, _ params: [String: Any], _ respond: @escaping (Result<Any, ACPError>) -> Void) -> Void)?
    /// The agent ended, and why if it said: on the main thread, after everything it said.
    var onExit: ((String?) -> Void)?

    /// Tests record what a real agent said, to replay it. Nil in the app.
    nonisolated(unsafe) static var recorder: ((_ direction: String, _ message: Any) -> Void)?

    private let process = LineProcess()
    private let lock = NSLock()
    private var waiting: [Int: (Result<Any, Error>) -> Void] = [:]
    private var nextID = 0
    private var name = "the agent"

    var running: Bool { process.running }

    func start(_ path: String, _ arguments: [String], in directory: URL, environment: [String: String]) throws {
        let child = try ChildProcess.spawn(path, arguments, in: directory, environment: environment, bridge: false)
        name = URL(fileURLWithPath: path).lastPathComponent
        process.onLine = { [weak self] object in
            // Every line on the main thread, in order, responses included: a
            // session/update said before a response is heard before the
            // request that response ends returns.
            DispatchQueue.main.async { self?.line(object) }
        }
        process.onEnd = { [weak self] why in
            DispatchQueue.main.async { self?.ended(why) }
        }
        process.start(child)
    }

    /// A request, and its result; throws its ACPError, or a ChildProcess.Failure "\(name) stopped" when the agent
    /// ended first. Past `timeout`, it fails as one that didn't answer.
    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval? = nil) async throws -> Any {
        let id = newID()
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        ACPConnection.recorder?("out", message)
        let name = name
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            waiting[id] = { continuation.resume(with: $0) }
            lock.unlock()
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let done = self.waiting.removeValue(forKey: id)
                    self.lock.unlock()
                    done?(.failure(ChildProcess.Failure(why: "\(name) didn't answer \(method)")))
                }
            }
            guard process.send(message) else {
                lock.lock()
                let done = waiting.removeValue(forKey: id)
                lock.unlock()
                done?(.failure(ChildProcess.Failure(why: "\(name) stopped")))
                return
            }
        }
    }

    func notify(_ method: String, _ params: [String: Any]) {
        let message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        ACPConnection.recorder?("out", message)
        process.send(message)
    }

    func stop(grace: TimeInterval = 3) { process.stop(grace: grace) }

    // MARK: - what the agent says

    private func line(_ object: Any) {
        ACPConnection.recorder?("in", object)
        guard let message = object as? [String: Any] else { return }
        if let method = message["method"] as? String {
            let params = message["params"] as? [String: Any] ?? [:]
            if let id = message["id"] {
                handleRequest(method, params, id: id)
            } else {
                onNotification?(method, params)
            }
            return
        }
        guard let key = message["id"] as? Int else { return }
        lock.lock()
        let done = waiting.removeValue(forKey: key)
        lock.unlock()
        guard let done else { return }
        if let error = message["error"] as? [String: Any] {
            done(.failure(ACPError(code: error["code"] as? Int ?? -32603,
                                   message: error["message"] as? String ?? "The agent refused that.",
                                   data: error["data"])))
        } else {
            done(.success(message["result"] ?? [:]))
        }
    }

    /// A request from the agent: onRequest answers it, or "method not found".
    private func handleRequest(_ method: String, _ params: [String: Any], id: Any) {
        guard let onRequest else {
            return respond(id, .failure(ACPError(code: -32601, message: "Method not found", data: nil)))
        }
        let once = Once()
        onRequest(method, params) { [weak self] result in
            guard once.claim() else { return }
            self?.respond(id, result)
        }
    }

    /// A result or an ACPError, written once.
    private func respond(_ id: Any, _ result: Result<Any, ACPError>) {
        let message: [String: Any]
        switch result {
        case .success(let value):
            message = ["jsonrpc": "2.0", "id": id, "result": value]
        case .failure(let error):
            var payload: [String: Any] = ["code": error.code, "message": error.message]
            if let data = error.data { payload["data"] = data }
            message = ["jsonrpc": "2.0", "id": id, "error": payload]
        }
        ACPConnection.recorder?("out", message)
        process.send(message)
    }

    private func newID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        return nextID
    }

    /// It ended: everything still waiting fails, then onExit, on main, after
    /// the lines already queued.
    private func ended(_ why: String?) {
        lock.lock()
        let pending = waiting
        waiting = [:]
        lock.unlock()
        pending.values.forEach { $0(.failure(ChildProcess.Failure(why: "\(name) stopped"))) }
        onExit?(why)
    }

    /// Answers one request once, however many times the handler responds.
    private final class Once {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

/// An ACP agent as Search starts it: one it found on the person's PATH, or one they added.
struct ACPSpec {
    let id: String
    let name: String
    let path: String
    let arguments: [String]
    var environment: [String: String] = [:]
    /// Variables to remove from the child's environment after the merge, for
    /// an adapter whose own variable could run another binary (Codex's
    /// CODEX_PATH, Claude Code's CLAUDE_CODE_EXECUTABLE).
    var unsetEnvironment: [String] = []
    /// The adapter shapes a structural tool identity is trusted from. Empty
    /// for every agent whose adapter isn't known to send one.
    var structuralTools: StructuralTools = []
    /// Whether the agent is given Search's browser tools over MCP. False for
    /// a side prompt's run: it is asked one question with no tools at all.
    var browserTools = true
    /// What session/new and session/load carry as `_meta`, for agents that take settings there (Claude's adapter:
    /// its own tools off). Nil: none.
    var sessionMeta: [String: Any]? = nil
    /// Config options to set as each session starts, by the option's id (Codex's sandbox: "mode" read-only). One the
    /// session doesn't list is skipped.
    var startOptions: [String: String] = [:]
    /// The method the person signed in with before, when there is one: after initialize, Search asks `authenticate`
    /// with it before a new session.
    var signIn: String? = nil
}

/// The adapter shapes Search trusts a structural tool identity from: Codex
/// names the server and tool, Claude Code its prefixed tool name. An adapter
/// not listed here can never have its rawInput or meta taken for one of
/// Search's tools.
struct StructuralTools: OptionSet, Sendable, Equatable {
    let rawValue: Int
    static let codex = StructuralTools(rawValue: 1 << 0)
    static let claude = StructuralTools(rawValue: 1 << 1)
}

extension ACPSpec {
    /// The environment a started child gets: the login shell's, the spec's
    /// own on top, and anything the spec unsets removed — an inherited
    /// CODEX_PATH could otherwise run another binary.
    func childEnvironment() -> [String: String] {
        var environment = LoginShell.environment
        self.environment.forEach { environment[$0] = $1 }
        for name in unsetEnvironment { environment.removeValue(forKey: name) }
        return environment
    }
}

extension ACPSpec: Equatable {
    /// The same launch and environment. `sessionMeta` isn't compared: it holds
    /// agent-specific settings that aren't Equatable.
    static func == (a: ACPSpec, b: ACPSpec) -> Bool {
        a.id == b.id && a.name == b.name && a.path == b.path
            && a.arguments == b.arguments && a.environment == b.environment
            && a.startOptions == b.startOptions && a.structuralTools == b.structuralTools
            && a.unsetEnvironment == b.unsetEnvironment && a.browserTools == b.browserTools
    }
}

/// How long a start waits on the agent; the session one is short in tests.
enum ACPTimeouts {
    nonisolated(unsafe) static var initialize: TimeInterval = 30
    nonisolated(unsafe) static var session: TimeInterval = 60
    /// A start option set after a session opens (Codex's mode, say).
    nonisolated(unsafe) static var startOption: TimeInterval = 30
    /// A sign-in may wait on the person in a browser: minutes, not seconds.
    nonisolated(unsafe) static var authenticate: TimeInterval = 300
}

extension ChatAgent {
    /// An ACP agent as a chat's agent.
    static func acp(_ spec: ACPSpec) -> ChatAgent {
        ChatAgent(name: spec.name, start: { chat, session, hear in
            try await ACPAgent.start(spec, chat, session, hear)
        }, title: { words, page in
            await PiOnce.title(for: words, on: page)
        })
    }
}

/// One ACP agent as the chat's agent: what it says (ACP's session/update and
/// its requests) as what a chat hears (AgentSays), and the chat's requests as
/// ACP's. ACP's wire never leaves this file.
@MainActor
private final class ACPAgent: AgentLink {
    /// One tool call as its updates build it up.
    private struct ToolState {
        var browser: String?
        var title: String?
        var rawInput: [String: Any]?
        var content: Any?
        /// What the agent said the tool does ("execute", "read", …), as its
        /// first word on it or any later one.
        var kind: String?
        /// Whether one of Search's tools was identified structurally (the
        /// agent named its server and tool, or Claude's prefixed name): a
        /// permission request for one is let through whatever kind it calls.
        var structural = false
    }

    private let spec: ACPSpec
    private let hear: (AgentSays) -> Void
    /// This agent's own, so one started again can't name an item an earlier one named.
    private let run = String(UUID().uuidString.prefix(8))
    private var connection: ACPConnection?
    private var door: MCPDoor?
    private var session: String?
    private var loadSession = false
    private var hasEnded = false
    private var cancelling = false
    private var counter = 0
    private var currentText: (id: String, kind: Chat.Item.Kind, messageId: String?)?
    private var pendingUser: String?
    private var options: [AgentOption] = []
    /// Whether the model option came from the legacy `models` result, set with session/set_model.
    private var legacyModels = false
    /// A browser tool's summary by its name and arguments, FIFO: taken when its step ends.
    private var summaries: [String: [String]] = [:]
    /// Each tool call, by id, as its updates build it up.
    private var tools: [String: ToolState] = [:]
    /// Summaries from an earlier run, by tool call id, for a reopened chat.
    private var keptSteps: [String: String] = [:]
    /// Every config option id the agent listed, the categories Search hides
    /// ("mode", say) included: a start option may name one of those.
    private var configOptionIDs: Set<String> = []

    private init(_ spec: ACPSpec, _ hear: @escaping (AgentSays) -> Void) {
        self.spec = spec
        self.hear = hear
    }

    static func start(_ spec: ACPSpec, _ chat: UUID, _ session: String?, _ hear: @escaping (AgentSays) -> Void) async throws -> AgentLink {
        let agent = ACPAgent(spec, hear)
        // Agents run in an empty folder of the chat's own, the same each time:
        // an agent keeps its sessions by folder, and an empty one gives its
        // own tools nothing of the person's.
        let folder = Chats.workspace(chat)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // The browser's tools, over MCP, on a door only this chat reaches. A
        // one-shot (browserTools false) is given none at all.
        var door: MCPDoor?
        if spec.browserTools {
            guard let opened = MCPDoor(call: { [weak agent] call, givenUp, reply in
                guard let agent else {
                    return reply(["content": [["type": "text", "text": "Stopped."]], "isError": true,
                                  "details": ["summary": "Stopped."]])
                }
                agent.called(call, givenUp, reply)
            }, cancel: { [weak agent] in
                agent?.hear(.cancel)
            }) else {
                throw ChildProcess.Failure(why: "Search couldn't open the browser's tools for \(spec.name).")
            }
            door = opened
            agent.door = opened
        }

        let connection = ACPConnection()
        connection.onNotification = { [weak agent] method, params in agent?.updated(method, params) }
        connection.onRequest = { [weak agent] method, params, respond in agent?.asked(method, params, respond) }
        connection.onExit = { [weak agent] why in agent?.ended(why) }
        agent.connection = connection

        let environment = spec.childEnvironment()

        // How the agent can be signed in, from initialize: needed both to
        // sign in again with the method the person used before and to say how
        // when the agent asks for a sign-in.
        var methods: [AgentSignIn.Method] = []

        do {
            try connection.start(spec.path, spec.arguments, in: folder, environment: environment)

            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            let initialized = try await connection.request("initialize", [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
                "clientInfo": ["name": "search", "title": "Search", "version": version],
            ], timeout: ACPTimeouts.initialize)
            let answer = initialized as? [String: Any] ?? [:]
            let capabilities = answer["agentCapabilities"] as? [String: Any]
            agent.loadSession = capabilities?["loadSession"] as? Bool ?? false
            methods = AgentSignIn.methods(answer["authMethods"], path: spec.path, arguments: spec.arguments)

            // The method the person used before, when the agent still lists
            // it: signed in again, so this session opens without a card.
            if let wanted = spec.signIn, methods.contains(where: { $0.id == wanted }) {
                do {
                    _ = try await connection.request("authenticate", ["methodId": wanted], timeout: ACPTimeouts.authenticate)
                } catch {
                    // The remembered method no longer works: forgot it, and
                    // ask the person to sign in again.
                    throw AgentSignIn(agent: spec.name, methods: methods, stale: true)
                }
            }

            // No door, no servers: a one-shot is asked without any tool.
            var sessionParams: [String: Any] = ["cwd": folder.path, "mcpServers": door.map { [$0.server] } ?? []]
            if let meta = spec.sessionMeta { sessionParams["_meta"] = meta }
            if let session, agent.loadSession {
                // The session being loaded is known before its updates come,
                // so they are taken for it.
                agent.session = session
                agent.keptSteps = ACPAgent.readSteps(session)
                sessionParams["sessionId"] = session
                let result = try await connection.request("session/load", sessionParams, timeout: ACPTimeouts.session)
                agent.flushedUser()
                agent.finishedText()
                agent.learn(result as? [String: Any] ?? [:])
            } else {
                let result = try await connection.request("session/new", sessionParams, timeout: ACPTimeouts.session)
                let answer = result as? [String: Any] ?? [:]
                agent.session = answer["sessionId"] as? String
                if let id = agent.session { agent.hear(.session(id)) }
                agent.learn(answer)
            }
            try await agent.applyStartOptions()
        } catch {
            connection.stop()
            door?.close()
            if let acp = error as? ACPError, acp.code == ACPError.authRequired {
                throw AgentSignIn(agent: spec.name, methods: methods)
            }
            throw error
        }
        return agent
    }

    // MARK: - what the agent says

    private func updated(_ method: String, _ params: [String: Any]) {
        guard method == "session/update" else { return }
        if let id = params["sessionId"] as? String, id != session { return }
        guard let update = params["update"] as? [String: Any] else { return }
        switch update["sessionUpdate"] as? String {
        case "user_message_chunk":
            // A message of the person's starts a text item of its own, however
            // the last answer ended.
            finishedText()
            pendingUser = (pendingUser ?? "") + chunk(update["content"])
        case "agent_message_chunk":
            flushedUser()
            putChunk(.assistant, chunk(update["content"]), messageId: update["messageId"] as? String)
        case "agent_thought_chunk":
            flushedUser()
            putChunk(.thinking, chunk(update["content"]), messageId: update["messageId"] as? String)
        case "tool_call":
            flushedUser()
            finishedText()
            let id = update["toolCallId"] as? String ?? ""
            if tools[id] == nil { startTool(id, update) } else { mergeTool(id, update) }
            if let status = update["status"] as? String, status == "completed" || status == "failed" {
                endTool(id, failed: status == "failed")
            }
        case "tool_call_update":
            let id = update["toolCallId"] as? String ?? ""
            if tools[id] == nil { startTool(id, update) } else { mergeTool(id, update) }
            guard let status = update["status"] as? String, status == "completed" || status == "failed" else { return }
            endTool(id, failed: status == "failed")
        case "config_option_update":
            if let list = update["configOptions"] { learn(["configOptions": list]) }
        case "session_info_update":
            if let title = update["title"] as? String, !title.isEmpty { hear(.named(title)) }
        default:
            break
        }
    }

    /// The text of a content block: ACP sends one, pi's tools send an array.
    private func chunk(_ content: Any?) -> String {
        if let block = content as? [String: Any] { return block["text"] as? String ?? "" }
        return Chat.text(of: content)
    }

    /// The person's message so far, said as soon as the agent says anything else.
    private func flushedUser() {
        if let text = pendingUser, !text.isEmpty { hear(.user(text)) }
        pendingUser = nil
    }

    /// Words of the answer: put in the item streaming now when it is the same
    /// message and kind, else in a new one, the last being done.
    private func putChunk(_ kind: Chat.Item.Kind, _ text: String, messageId: String?) {
        let changed = currentText?.kind != kind
            || (messageId != nil && currentText?.messageId != messageId)
        if changed {
            finishedText()
            counter += 1
            currentText = (id: "\(run)-\(counter)", kind: kind, messageId: messageId)
        }
        if let currentText {
            hear(.text(id: currentText.id, kind: kind, text: text, whole: false, done: false))
        }
    }

    /// The text item now streaming, if any, won't change again.
    private func finishedText() {
        if let currentText { hear(.done(id: currentText.id)) }
        currentText = nil
    }

    /// A step begun: what the agent said of it, kept as its updates come.
    private func startTool(_ id: String, _ update: [String: Any]) {
        let browser = browserTool(update)
        let title = update["title"] as? String
        let rawInput = ACPAgent.toolArguments(update)
        tools[id] = ToolState(browser: browser, title: title, rawInput: rawInput, content: update["content"],
                              kind: update["kind"] as? String,
                              structural: structuralBrowserTool(update) != nil)
        if let browser {
            hear(.toolStarted(id: id, name: browser, args: rawInput ?? [:]))
        } else {
            hear(.toolStarted(id: id, name: title ?? "A tool of its own", args: [:]))
        }
    }

    /// What later updates say of a step already begun.
    private func mergeTool(_ id: String, _ update: [String: Any]) {
        guard var state = tools[id] else { return }
        if let title = update["title"] as? String { state.title = title }
        if let rawInput = ACPAgent.toolArguments(update) { state.rawInput = rawInput }
        if let content = update["content"] { state.content = content }
        if let kind = update["kind"] as? String { state.kind = kind }
        if state.browser == nil, let browser = browserTool(update) { state.browser = browser }
        // Recompute on anything that could identify it or contradict it: a
        // later update naming another server or tool clears it.
        if update["rawInput"] != nil || update["_meta"] != nil || update["title"] != nil {
            state.structural = structuralBrowserTool(update) != nil
        }
        tools[id] = state
    }

    /// A tool call's own arguments: Codex names the server and tool in
    /// `rawInput` and nests the arguments under "arguments" there; every
    /// other agent's `rawInput` is them. Nil when there is no rawInput.
    private static func toolArguments(_ update: [String: Any]) -> [String: Any]? {
        guard let rawInput = update["rawInput"] as? [String: Any] else { return nil }
        if rawInput["server"] as? String == "search",
           let tool = rawInput["tool"] as? String,
           AgentTools.names.contains(tool) {
            return rawInput["arguments"] as? [String: Any] ?? [:]
        }
        return rawInput
    }

    /// A step finished: its line from the browser tool's own answer when it was
    /// one, else what the agent said.
    private func endTool(_ id: String, failed: Bool) {
        guard let state = tools[id] else { return }
        var detail = toolDetail(state.content)
        var summary: String?
        if let name = state.browser {
            if let live = takeSummary(name, state.rawInput) {
                summary = live
                recordStep(id, live)
            } else {
                summary = keptSteps[id]
            }
        } else if failed, detail.isEmpty {
            detail = "Search gives \(spec.name) only the browser's tools."
        }
        hear(.toolEnded(id: id, failed: failed, summary: summary, detail: detail))
    }

    /// The summary for a browser tool's call: its own when the arguments are
    /// known, else the only one waiting for that tool.
    private func takeSummary(_ name: String, _ rawInput: [String: Any]?) -> String? {
        if let rawInput {
            let key = ACPAgent.summaryKey(name, rawInput)
            guard var list = summaries[key], !list.isEmpty else { return nil }
            let first = list.removeFirst()
            summaries[key] = list
            return first
        }
        let keys = summaries.keys.filter { $0.hasPrefix(name + "|") }
        let waiting = keys.reduce(0) { $0 + (summaries[$1]?.count ?? 0) }
        guard waiting == 1, let key = keys.first(where: { !(summaries[$0]?.isEmpty ?? true) }) else { return nil }
        var list = summaries[key] ?? []
        let first = list.removeFirst()
        summaries[key] = list
        return first
    }

    /// A tool and its arguments, as one key: the same tool with other
    /// arguments is another call, and its line is another line.
    private static func summaryKey(_ name: String, _ args: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])) ?? Data()
        return name + "|" + (String(data: data, encoding: .utf8) ?? "")
    }

    private static func readSteps(_ session: String) -> [String: String] {
        guard let data = try? Data(contentsOf: Chats.stepsFile(session)),
              let steps = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return steps
    }

    /// Keep a tool call's line with the chat's session, for when it is
    /// reopened: the whole of what is kept, so a write that follows another
    /// loses nothing.
    private func recordStep(_ id: String, _ summary: String) {
        guard let session else { return }
        keptSteps[id] = summary
        let snapshot = keptSteps
        Disk.write(Chats.stepsFile(session)) { try? JSONEncoder().encode(snapshot) }
    }

    /// The browser's tool name an update names, if any: a structurally
    /// identified call first (the agent named its server and tool, or
    /// Claude's prefixed name), else an exact name in the title or a tool
    /// name. A title that merely mentions one is the agent's own words, not
    /// the tool.
    private func browserTool(_ update: [String: Any]) -> String? {
        if let structural = structuralBrowserTool(update) { return structural }
        var candidates: [String] = []
        if let meta = update["_meta"] as? [String: Any],
           let claude = meta["claudeCode"] as? [String: Any],
           let tool = claude["toolName"] as? String { candidates.append(tool) }
        if let title = update["title"] as? String { candidates.append(title) }
        if let tool = update["toolName"] as? String { candidates.append(tool) }
        if let name = update["name"] as? String { candidates.append(name) }
        for candidate in candidates {
            let name = ACPAgent.stripped(candidate)
            if AgentTools.names.contains(name) { return name }
        }
        return nil
    }

    /// Whether an update is structurally one of Search's own tools, for the
    /// adapters this spec trusts: Codex names the server and tool there and
    /// marks the call as an MCP one; Claude's adapter names it as
    /// "mcp__search__<name>". An adapter not trusted here never is, whatever
    /// its rawInput or meta says.
    private func structuralBrowserTool(_ update: [String: Any]) -> String? {
        if spec.structuralTools.contains(.codex), let name = ACPAgent.codexNamesTool(update) { return name }
        if spec.structuralTools.contains(.claude), let name = ACPAgent.claudeNamesTool(update) { return name }
        return nil
    }

    /// Codex's structural shape: the server and tool in `rawInput`, marked as
    /// one of its MCP tool calls.
    private static func codexNamesTool(_ update: [String: Any]) -> String? {
        guard let meta = update["_meta"] as? [String: Any], meta["is_mcp_tool_call"] as? Bool == true else { return nil }
        guard let rawInput = update["rawInput"] as? [String: Any],
              rawInput["server"] as? String == "search",
              let tool = rawInput["tool"] as? String,
              AgentTools.names.contains(tool) else { return nil }
        return tool
    }

    /// Claude's adapter's structural shape: the tool under its meta as
    /// "mcp__search__<name>".
    private static func claudeNamesTool(_ update: [String: Any]) -> String? {
        guard let meta = update["_meta"] as? [String: Any],
              let claude = meta["claudeCode"] as? [String: Any],
              let tool = claude["toolName"] as? String,
              tool.hasPrefix("mcp__search__") else { return nil }
        let name = String(tool.dropFirst("mcp__search__".count))
        return AgentTools.names.contains(name) ? name : nil
    }

    /// Whether a permission request is for one of Search's own tools: its own
    /// toolCall says so, or — for Codex, whose request names no tool, only
    /// that it approves one — the step it names is already known as
    /// structural and the request is marked as an MCP approval.
    private func requestIsStructural(_ toolCall: [String: Any], known: Bool) -> Bool {
        if structuralBrowserTool(toolCall) != nil { return true }
        if spec.structuralTools.contains(.codex),
           let meta = toolCall["_meta"] as? [String: Any],
           meta["is_mcp_tool_approval"] as? Bool == true,
           known {
            return true
        }
        return false
    }

    /// A candidate without the server's prefix, so "search_browser_tabs",
    /// "mcp__search__browser_tabs" and "mcp.search.browser_tabs" all come
    /// out as the tool's name.
    private static func stripped(_ text: String) -> String {
        for prefix in ["mcp__search__", "mcp.search.", "search_", "search/", "search."] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }
        return text
    }

    /// The text of a tool update's content blocks, joined: a change or a
    /// command run is said too, so it can't vanish.
    private func toolDetail(_ content: Any?) -> String {
        (content as? [[String: Any]] ?? []).compactMap { item -> String? in
            switch item["type"] as? String {
            case "content":
                guard let inner = item["content"] as? [String: Any], inner["type"] as? String == "text" else { return nil }
                return inner["text"] as? String
            case "diff":
                return "Changed \(item["path"] as? String ?? "")"
            case "terminal":
                return "Ran a command"
            default:
                return nil
            }
        }.joined(separator: "\n")
    }

    // MARK: - options

    /// What the agent offers, from either `configOptions` or the legacy `models`.
    private func learn(_ result: [String: Any]) {
        if let raw = result["configOptions"] as? [[String: Any]] {
            // Every id is kept, not only the categories Search shows: a start
            // option may name one it hides, as Codex's "mode".
            configOptionIDs = Set(raw.compactMap { $0["id"] as? String })
            let parsed = raw.compactMap { option -> AgentOption? in
                guard let id = option["id"] as? String,
                      let category = option["category"] as? String,
                      let kind = ACPAgent.category(category) else { return nil }
                return AgentOption(id: id, name: option["name"] as? String ?? id, category: kind,
                                   current: option["currentValue"] as? String,
                                   choices: ACPAgent.choices(option["options"]))
            }
            legacyModels = false
            options = parsed
            hear(.options(parsed))
            return
        }
        if let models = result["models"] as? [String: Any] {
            let choices = (models["availableModels"] as? [[String: Any]] ?? []).compactMap { model -> AgentOption.Choice? in
                guard let id = model["modelId"] as? String else { return nil }
                return AgentOption.Choice(value: id, name: model["name"] as? String ?? id, group: nil)
            }
            let option = AgentOption(id: "model", name: "Model", category: .model,
                                     current: models["currentModelId"] as? String, choices: choices)
            legacyModels = true
            options = [option]
            hear(.options([option]))
        }
    }

    /// Set the config options an agent wants at every session start (its
    /// sandbox, say), each only when this session listed that option. A
    /// session that doesn't is left as the agent started it.
    private func applyStartOptions() async throws {
        guard let connection, let session else { return }
        for (id, value) in spec.startOptions where configOptionIDs.contains(id) {
            let result = try await connection.request("session/set_config_option",
                                                      ["sessionId": session, "configId": id, "value": value],
                                                      timeout: ACPTimeouts.startOption)
            learn(result as? [String: Any] ?? [:])
        }
    }

    private static func category(_ raw: String) -> AgentOption.Category? {
        // Modes are how an agent's own tools are let back in: never offered.
        switch raw {
        case "model": return .model
        case "thought_level": return .thought
        default: return nil
        }
    }

    /// A config option's choices, plain or in groups.
    private static func choices(_ raw: Any?) -> [AgentOption.Choice] {
        var out: [AgentOption.Choice] = []
        for item in raw as? [[String: Any]] ?? [] {
            if let group = item["group"] as? String, let inner = item["options"] as? [[String: Any]] {
                for choice in inner {
                    guard let value = choice["value"] as? String else { continue }
                    out.append(AgentOption.Choice(value: value, name: choice["name"] as? String ?? value, group: group))
                }
            } else if let value = item["value"] as? String {
                out.append(AgentOption.Choice(value: value, name: item["name"] as? String ?? value, group: nil))
            }
        }
        return out
    }

    // MARK: - the chat's requests

    func prompt(_ text: String) async throws {
        guard let connection, let session else { throw ChildProcess.Failure(why: "\(spec.name) isn't running") }
        cancelling = false
        // ACP agents don't say the person's message back while it is live.
        hear(.user(text))
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await connection.request("session/prompt",
                                                          ["sessionId": session, "prompt": [["type": "text", "text": text]]])
                self.finished(result as? [String: Any] ?? [:])
            } catch {
                self.finished(error: error)
            }
        }
    }

    func cancel() {
        cancelling = true
        guard let connection, let session else { return }
        connection.notify("session/cancel", ["sessionId": session])
    }

    func set(_ option: String, to value: String) async throws {
        guard let connection, let session else { throw ChildProcess.Failure(why: "\(spec.name) isn't running") }
        if legacyModels, option == "model" {
            _ = try await connection.request("session/set_model", ["sessionId": session, "modelId": value])
            options = options.map { existing in
                var updated = existing
                if updated.id == "model" { updated.current = value }
                return updated
            }
            hear(.options(options))
        } else {
            let result = try await connection.request("session/set_config_option",
                                                      ["sessionId": session, "configId": option, "value": value])
            learn(result as? [String: Any] ?? [:])
        }
    }

    func name(_ title: String) {
        // ACP has no way to rename a session from the client.
    }

    func stop() {
        connection?.stop()
        door?.close()
    }

    /// The answer is done: whatever was pending, then the line it ends on.
    private func finished(_ result: [String: Any]) {
        guard !hasEnded else { return }
        flushedUser()
        finishedText()
        switch result["stopReason"] as? String {
        case "cancelled": hear(.line(kind: .note, text: "Stopped."))
        case "refusal": hear(.line(kind: .error, text: "\(spec.name) refused to answer."))
        case "max_tokens": hear(.line(kind: .error, text: "The answer ran out of room."))
        case "max_turn_requests": hear(.line(kind: .error, text: "\(spec.name) took too many steps."))
        default: break
        }
        hear(.settled)
    }

    private func finished(error: Error) {
        guard !hasEnded else { return }
        flushedUser()
        finishedText()
        hear(.line(kind: .error, text: error.localizedDescription))
        hear(.settled)
    }

    // MARK: - what the agent asks

    private func asked(_ method: String, _ params: [String: Any], _ respond: @escaping (Result<Any, ACPError>) -> Void) {
        guard method == "session/request_permission" else {
            respond(.failure(ACPError(code: -32601, message: "Search doesn't offer \(method).", data: nil)))
            return
        }
        if cancelling {
            respond(.success(["outcome": ["outcome": "cancelled"]]))
            return
        }
        let toolCall = params["toolCall"] as? [String: Any] ?? [:]
        let id = toolCall["toolCallId"] as? String ?? ""
        // The kind the request says, else the one the step was begun with:
        // a request that leaves it out doesn't make a command harmless.
        let kind = toolCall["kind"] as? String ?? tools[id]?.kind
        // One of Search's own tools identified structurally — the agent
        // named its server and tool, or Claude's prefixed name — is let
        // through whatever kind it calls it: the kind is then the agent's
        // label for a tool the catalogue asks the person about itself. One
        // identified only by an exact name in a title is let through only
        // when its kind runs nothing of the Mac's; a title that is the
        // agent's own words is never enough. Allow once only, as the
        // catalogue asks itself.
        let known = tools[id]?.structural ?? false
        let structural = requestIsStructural(toolCall, known: known) || known
        let harmless = kind.map { ["other", "read", "fetch", "search"].contains($0) } ?? true
        let named = browserTool(toolCall) != nil || knownBrowserTool(id)
        let browser = structural || (named && harmless)
        let available = params["options"] as? [[String: Any]] ?? []
        let allowed = browser ? firstOption(available, kinds: ["allow_once"]) : nil
        let chosen = allowed ?? firstOption(available, kinds: ["reject_once", "reject_always"])
        guard let chosen else {
            respond(.success(["outcome": ["outcome": "cancelled"]]))
            return
        }
        respond(.success(["outcome": ["outcome": "selected", "optionId": chosen]]))
    }

    private func firstOption(_ options: [[String: Any]], kinds: [String]) -> String? {
        for kind in kinds {
            if let option = options.first(where: { $0["kind"] as? String == kind }),
               let optionId = option["optionId"] as? String {
                return optionId
            }
        }
        return nil
    }

    private func knownBrowserTool(_ id: String) -> Bool {
        tools[id]?.browser != nil
    }

    /// A tool call the agent makes: the chat runs it in its window, and its
    /// line is kept for when the step ends.
    private func called(_ call: [String: Any], _ givenUp: @escaping @MainActor () -> Bool,
                        _ reply: @escaping ([String: Any]) -> Void) {
        let name = call["name"] as? String ?? ""
        let key = ACPAgent.summaryKey(name, call["args"] as? [String: Any] ?? [:])
        hear(.tool(call, givenUp: givenUp, reply: { [weak self] result in
            if let summary = (result["details"] as? [String: Any])?["summary"] as? String {
                self?.summaries[key, default: []].append(summary)
            }
            reply(result)
        }))
    }

    private func ended(_ why: String?) {
        door?.close()
        guard !hasEnded else { return }
        hasEnded = true
        hear(.exit(why))
    }
}
