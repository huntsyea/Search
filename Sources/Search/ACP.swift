import Foundation

// ACP agents, spoken to as a client (docs/design/agents.md, "ACP, the client
// side"); this file is the wire.

/// An error an ACP agent answered with.
struct ACPError: LocalizedError {
    let code: Int
    let message: String
    let data: Any?
    var errorDescription: String? { message }
    /// ACP's "auth_required": the agent wants the person to sign in first.
    static let authRequired = -32000
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
    /// ended first.
    func request(_ method: String, _ params: [String: Any]) async throws -> Any {
        let id = newID()
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        ACPConnection.recorder?("out", message)
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            waiting[id] = { continuation.resume(with: $0) }
            lock.unlock()
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
    /// What session/new and session/load carry as `_meta`, for agents that take settings there (Claude's adapter:
    /// its own tools off). Nil: none.
    var sessionMeta: [String: Any]? = nil
}

extension ChatAgent {
    /// An ACP agent as a chat's agent.
    static func acp(_ spec: ACPSpec) -> ChatAgent {
        ChatAgent(name: spec.name, start: { session, hear in
            try await ACPAgent.start(spec, session, hear)
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
    private var currentText: (id: String, kind: Chat.Item.Kind)?
    private var pendingUser: String?
    private var options: [AgentOption] = []
    /// Whether the model option came from the legacy `models` result, set with session/set_model.
    private var legacyModels = false
    /// A browser tool's summary by the tool's name, FIFO: taken when its step ends.
    private var summaries: [String: [String]] = [:]
    /// Each toolCallId's browser tool name, or nil for the agent's own; an
    /// absent id was never seen.
    private var toolNames: [String: String?] = [:]
    /// Summaries from an earlier run, by tool call id, for a reopened chat.
    private var keptSteps: [String: String] = [:]

    private init(_ spec: ACPSpec, _ hear: @escaping (AgentSays) -> Void) {
        self.spec = spec
        self.hear = hear
    }

    static func start(_ spec: ACPSpec, _ session: String?, _ hear: @escaping (AgentSays) -> Void) async throws -> AgentLink {
        let agent = ACPAgent(spec, hear)
        // Agents run in one empty folder of the chats' own, the same each
        // time: an agent keeps its sessions by folder, and an empty one gives
        // its own tools nothing of the person's.
        let folder = Chats.folder.appendingPathComponent("Workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // The browser's tools, over MCP, on a door only this chat reaches.
        guard let door = MCPDoor(call: { [weak agent] call, givenUp, reply in
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
        agent.door = door

        let connection = ACPConnection()
        connection.onNotification = { [weak agent] method, params in agent?.updated(method, params) }
        connection.onRequest = { [weak agent] method, params, respond in agent?.asked(method, params, respond) }
        connection.onExit = { [weak agent] why in agent?.ended(why) }
        agent.connection = connection

        var environment = LoginShell.environment
        spec.environment.forEach { environment[$0] = $1 }

        do {
            try connection.start(spec.path, spec.arguments, in: folder, environment: environment)

            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            let initialized = try await connection.request("initialize", [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
                "clientInfo": ["name": "search", "title": "Search", "version": version],
            ])
            let capabilities = (initialized as? [String: Any])?["agentCapabilities"] as? [String: Any]
            agent.loadSession = capabilities?["loadSession"] as? Bool ?? false

            var sessionParams: [String: Any] = ["cwd": folder.path, "mcpServers": [door.server]]
            if let meta = spec.sessionMeta { sessionParams["_meta"] = meta }
            if let session, agent.loadSession {
                // The session being loaded is known before its updates come,
                // so they are taken for it.
                agent.session = session
                agent.keptSteps = ACPAgent.readSteps(session)
                sessionParams["sessionId"] = session
                let result = try await connection.request("session/load", sessionParams)
                agent.flushedUser()
                agent.learn(result as? [String: Any] ?? [:])
            } else {
                let result = try await connection.request("session/new", sessionParams)
                let answer = result as? [String: Any] ?? [:]
                agent.session = answer["sessionId"] as? String
                if let id = agent.session { agent.hear(.session(id)) }
                agent.learn(answer)
            }
        } catch {
            connection.stop()
            door.close()
            if let acp = error as? ACPError, acp.code == ACPError.authRequired {
                throw ChildProcess.Failure(why: "\(spec.name) needs you to sign in first.")
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
            pendingUser = (pendingUser ?? "") + chunk(update["content"])
        case "agent_message_chunk":
            flushedUser()
            putChunk(.assistant, chunk(update["content"]))
        case "agent_thought_chunk":
            flushedUser()
            putChunk(.thinking, chunk(update["content"]))
        case "tool_call":
            flushedUser()
            finishedText()
            let id = update["toolCallId"] as? String ?? ""
            let name = browserTool(update)
            toolNames[id] = name
            if let name {
                hear(.toolStarted(id: id, name: name, args: update["rawInput"] as? [String: Any] ?? [:]))
            } else {
                hear(.toolStarted(id: id, name: update["title"] as? String ?? "A tool of its own", args: [:]))
            }
            if let status = update["status"] as? String, status == "completed" || status == "failed" {
                endTool(id, failed: status == "failed", content: update["content"])
            }
        case "tool_call_update":
            guard let id = update["toolCallId"] as? String,
                  let status = update["status"] as? String, status == "completed" || status == "failed" else { return }
            endTool(id, failed: status == "failed", content: update["content"])
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
    /// kind, else in a new one, the last being done.
    private func putChunk(_ kind: Chat.Item.Kind, _ text: String) {
        if currentText?.kind != kind {
            finishedText()
            counter += 1
            currentText = (id: "\(run)-\(counter)", kind: kind)
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

    /// A step finished: its line from the browser tool's own answer when it was
    /// one, else what the agent said.
    private func endTool(_ id: String, failed: Bool, content: Any?) {
        guard let entry = toolNames[id] else { return }
        var detail = toolDetail(content)
        var summary: String?
        if let name = entry {
            if let live = takeSummary(name) {
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

    private func takeSummary(_ name: String) -> String? {
        guard var list = summaries[name], !list.isEmpty else { return nil }
        let first = list.removeFirst()
        summaries[name] = list
        return first
    }

    /// Where a reopened chat's step lines are kept, beside the chats.
    private static func stepsFile(_ session: String) -> URL {
        let safe = String(session.map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber) || character == "_" || character == "-"
                ? character : "_"
        })
        return Chats.folder.appendingPathComponent("Steps", isDirectory: true).appendingPathComponent(safe + ".json")
    }

    private static func readSteps(_ session: String) -> [String: String] {
        guard let data = try? Data(contentsOf: stepsFile(session)),
              let steps = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return steps
    }

    /// Keep a tool call's line with the chat's session, for when it is reopened.
    private func recordStep(_ id: String, _ summary: String) {
        guard let session else { return }
        let file = ACPAgent.stepsFile(session)
        Disk.write(file) {
            let kept = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            var steps = kept
            steps[id] = summary
            return try? JSONEncoder().encode(steps)
        }
    }

    /// The browser's tool name an update names, if any: Claude's adapter says
    /// it under `_meta`, the rest in the title (or a tool name).
    private func browserTool(_ update: [String: Any]) -> String? {
        var candidates: [String] = []
        if let meta = update["_meta"] as? [String: Any],
           let claude = meta["claudeCode"] as? [String: Any],
           let tool = claude["toolName"] as? String { candidates.append(tool) }
        if let title = update["title"] as? String { candidates.append(title) }
        if let tool = update["toolName"] as? String { candidates.append(tool) }
        if let name = update["name"] as? String { candidates.append(name) }
        let stripped = candidates.map { ACPAgent.stripped($0) }
        // A known name the candidate equals or ends with, longest first; else
        // one it merely contains.
        for test in [{ (name: String, text: String) in text == name || text.hasSuffix(name) },
                     { (name: String, text: String) in text.contains(name) }] {
            var best: String?
            for name in AgentTools.names where stripped.contains(where: { test(name, $0) }) {
                if best.map({ name.count > $0.count }) ?? true { best = name }
            }
            if let best { return best }
        }
        return nil
    }

    /// A candidate without the server's prefix, so "search_browser_tabs" and
    /// "mcp__search__browser_tabs" both come out as the tool's name.
    private static func stripped(_ text: String) -> String {
        for prefix in ["mcp__search__", "search_", "search/", "search."] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }
        return text
    }

    /// The text of a tool update's content blocks, joined.
    private func toolDetail(_ content: Any?) -> String {
        (content as? [[String: Any]] ?? []).compactMap { item -> String? in
            guard item["type"] as? String == "content",
                  let inner = item["content"] as? [String: Any],
                  inner["type"] as? String == "text" else { return nil }
            return inner["text"] as? String
        }.joined(separator: "\n")
    }

    // MARK: - options

    /// What the agent offers, from either `configOptions` or the legacy `models`.
    private func learn(_ result: [String: Any]) {
        if let raw = result["configOptions"] as? [[String: Any]] {
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
        let browser = knownBrowserTool(id) || browserTool(toolCall) != nil
        // Search asks the person for a browser tool itself; an agent's own
        // tools are refused, since it is given only the browser's.
        let wanted = browser ? ["allow_once", "allow_always"] : ["reject_once", "reject_always"]
        let available = params["options"] as? [[String: Any]] ?? []
        for kind in wanted {
            if let option = available.first(where: { $0["kind"] as? String == kind }),
               let optionId = option["optionId"] as? String {
                respond(.success(["outcome": ["outcome": "selected", "optionId": optionId]]))
                return
            }
        }
        respond(.success(["outcome": ["outcome": "cancelled"]]))
    }

    private func knownBrowserTool(_ id: String) -> Bool {
        if case .some(.some) = toolNames[id] { return true }
        return false
    }

    /// A tool call the agent makes: the chat runs it in its window, and its
    /// line is kept for when the step ends.
    private func called(_ call: [String: Any], _ givenUp: @escaping @MainActor () -> Bool,
                        _ reply: @escaping ([String: Any]) -> Void) {
        let name = call["name"] as? String ?? ""
        hear(.tool(call, givenUp: givenUp, reply: { [weak self] result in
            if let summary = (result["details"] as? [String: Any])?["summary"] as? String {
                self?.summaries[name, default: []].append(summary)
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
