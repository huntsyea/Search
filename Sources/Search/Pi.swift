import Foundation

// pi, the agent behind the chat (see docs/design/right-sidebar-and-agent.md).
//
// pi runs as a program of its own, in its RPC mode: one JSON object per line
// on its standard input and output — commands in; responses, and the
// session's events as they happen, out. Search is the client, as bb is.
//
// It is started with none of its own tools — no shell, no files, none of the
// person's own extensions, skills or MCP servers — and with Search's
// extension (AgentTools.extension) giving it the browser's tools instead.
// That extension talks back over two more pipes, descriptors 3 (pi to
// Search) and 4 (Search to pi), which only this process and pi hold: a tool
// call never goes through a socket anyone else could reach.
//
// Its sessions are kept in Search's own folder (Chats/sessions), apart from
// the person's pi in a terminal, and a test world's apart from the browser's.
//
// Finding and starting a program in general — the login shell's environment
// and a child process — is LoginShell's and ChildProcess's now. What's here
// is pi's own: its flags, and its RPC process.

/// Finding, confining and starting pi: the one place the app goes to it.
enum Pi {
    struct Failure: LocalizedError {
        let why: String
        var errorDescription: String? { why }
    }

    /// A model pi can use, as `pi --list-models` lists it.
    struct Model: Hashable, Identifiable {
        let provider: String
        let id: String
        var key: String { provider + "/" + id }
    }

    /// A fake pi, for tests: when set, it is the pi started, with Search's
    /// own environment and no login shell asked. Nil in the app.
    nonisolated(unsafe) static var executable: URL?

    /// The flags that keep pi to Search's own tools: only `tools` (none at
    /// all when empty), and none of the person's MCP servers, skills, prompt
    /// templates, context files or themes.
    static func confined(tools: [String]) -> [String] {
        tools.isEmpty
            ? ["--no-tools", "--no-mcp", "--no-skills", "--no-prompt-templates", "--no-context-files", "--no-themes"]
            : ["--tools", tools.joined(separator: ","), "--no-mcp", "--no-skills", "--no-prompt-templates", "--no-context-files", "--no-themes"]
    }

    /// Where pi is, and the environment it expects: the one the person's
    /// login shell has. An app opened from the Dock doesn't get the shell's
    /// PATH, so pi — and the node it runs on — wouldn't be found without it.
    /// Looked up once a run, off the main thread.
    nonisolated(unsafe) private static var found: (path: String, environment: [String: String])?
    private static let lock = NSLock()

    static func locate() -> (path: String, environment: [String: String])? {
        if let executable {
            return FileManager.default.isExecutableFile(atPath: executable.path)
                ? (executable.path, ProcessInfo.processInfo.environment)
                : nil
        }
        lock.lock()
        defer { lock.unlock() }
        if let found { return found }
        guard let pi = LoginShell.find("pi") else { return nil }
        found = (pi, LoginShell.environment)
        return found
    }

    /// pi started with `arguments` in `directory`: stdin, stdout and stderr
    /// on pipes, and with `bridge` the extension's two pipes on 3 and 4.
    /// Nothing else Search has open goes with it.
    static func spawn(_ arguments: [String], in directory: URL,
                      environment extra: [String: String] = [:], bridge: Bool) throws -> ChildProcess {
        guard let (pi, base) = locate() else {
            throw Failure(why: "pi isn't installed — npm install -g @earendil-works/pi-coding-agent, then try again")
        }
        var environment = base
        extra.forEach { environment[$0] = $1 }
        return try ChildProcess.spawn(pi, arguments, in: directory, environment: environment, bridge: bridge)
    }

    /// `pi <arguments>` run to its end with stdin empty, in the temporary
    /// folder; its stdout. Thirty seconds at most, then it is ended.
    static func print(_ arguments: [String], deadline: TimeInterval = 30) throws -> String {
        let child = try spawn(arguments, in: URL(fileURLWithPath: NSTemporaryDirectory()), bridge: false)
        do {
            return try child.finish(deadline: deadline, name: "pi")
        } catch let failure as ChildProcess.Failure {
            throw Failure(why: failure.why)
        }
    }

    /// `pi --list-models`, read into models: its table's first line is the
    /// header; each other line is provider, model id, then more columns. Ten
    /// seconds at most, so a hung pi can't leave Settings' spinner up.
    static func models(deadline: TimeInterval = 10) throws -> [Model] {
        let child = try spawn(["--list-models"], in: URL(fileURLWithPath: NSTemporaryDirectory()), bridge: false)
        let table: String
        do {
            table = try child.finish(deadline: deadline, name: "pi")
        } catch let failure as ChildProcess.Failure {
            throw Failure(why: failure.why)
        }
        return table.split(separator: "\n").dropFirst().compactMap { line in
            let cells = line.split(whereSeparator: \.isWhitespace)
            guard cells.count >= 2 else { return nil }
            return Model(provider: String(cells[0]), id: String(cells[1]))
        }
    }
}

/// One pi process, for one chat.
final class PiProcess: @unchecked Sendable {
    struct Failure: LocalizedError {
        let why: String
        var errorDescription: String? { why }
    }

    /// A session event, a line of stdout that isn't a response.
    var onEvent: ((_ event: [String: Any]) -> Void)?
    /// A tool call from Search's extension: answer with `reply`.
    var onTool: ((_ call: [String: Any], _ reply: @escaping ([String: Any]) -> Void) -> Void)?
    /// The process ended, and why if it said.
    var onExit: ((_ why: String?) -> Void)?
    /// A tool call pi gave up on.
    var onCancel: (() -> Void)?

    private let process = LineProcess()
    private var bridgeOut: FileHandle?
    private var bridgeIn: FileHandle?
    private var bridgeCarry = Data()
    private var waiting: [String: (Result<[String: Any], Error>) -> Void] = [:]
    private var nextID = 0
    private let lock = NSLock()

    var running: Bool { process.running }

    /// `arguments` follow `pi`; the extension and the session flags are the caller's.
    func start(arguments: [String], directory: URL, environment extra: [String: String]) throws {
        let child: ChildProcess
        do {
            child = try Pi.spawn(arguments, in: directory, environment: extra, bridge: true)
        } catch let failure as Pi.Failure {
            throw Failure(why: failure.why)
        }
        process.onLine = { [weak self] object in self?.line(object) }
        process.onEnd = { [weak self] why in self?.ended(why) }
        bridgeOut = child.bridgeOut
        bridgeIn = child.bridgeIn
        process.start(child)

        bridgeIn?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { handle.readabilityHandler = nil; return }
            LineProcess.take(data, into: &self.bridgeCarry) { self.bridgeLine($0) }
        }
    }

    private func line(_ object: Any) {
        guard let record = object as? [String: Any] else { return }
        if record["type"] as? String == "response", let id = record["id"] as? String {
            lock.lock()
            let done = waiting.removeValue(forKey: id)
            lock.unlock()
            if record["success"] as? Bool == true {
                done?(.success(record["data"] as? [String: Any] ?? [:]))
            } else {
                done?(.failure(Failure(why: record["error"] as? String ?? "pi refused that")))
            }
            return
        }
        // An extension asking for a dialog through the RPC protocol: none is
        // offered yet, so it is answered as cancelled rather than left waiting.
        if record["type"] as? String == "extension_ui_request", let id = record["id"] as? String {
            let method = record["method"] as? String ?? ""
            if ["select", "confirm", "input", "editor"].contains(method) {
                process.send(["type": "extension_ui_response", "id": id, "cancelled": true])
            }
            return
        }
        DispatchQueue.main.async { self.onEvent?(record) }
    }

    private func bridgeLine(_ data: Data) {
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // A call given up on (Stop) while Search was still on it — asking
        // the person, say.
        if record["kind"] as? String == "cancel" {
            DispatchQueue.main.async { self.onCancel?() }
            return
        }
        guard record["kind"] as? String == "tool", let id = record["id"] else { return }
        DispatchQueue.main.async {
            guard let onTool = self.onTool else {
                return self.answer(["kind": "tool-result", "id": id, "isError": true,
                                    "content": [["type": "text", "text": "The browser isn't there any more."]]])
            }
            onTool(record) { [weak self] result in
                var reply = result
                reply["kind"] = "tool-result"
                reply["id"] = id
                self?.answer(reply)
            }
        }
    }

    private func answer(_ reply: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: reply) else { return }
        data.append(0x0A)
        try? bridgeOut?.write(contentsOf: data)
    }

    /// A command, and its response's data.
    func request(_ command: [String: Any]) async throws -> [String: Any] {
        let id = newID()
        var command = command
        command["id"] = id
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            waiting[id] = { continuation.resume(with: $0) }
            lock.unlock()
            guard process.send(command) else {
                lock.lock()
                let done = waiting.removeValue(forKey: id)
                lock.unlock()
                done?(.failure(Failure(why: "pi isn't running")))
                return
            }
        }
    }

    private func newID() -> String {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        return "search-\(nextID)"
    }

    /// Asked to stop. See LineProcess.
    func stop() { process.stop() }

    /// The same, after `grace` seconds rather than three (for tests).
    func stop(grace: TimeInterval) { process.stop(grace: grace) }

    /// Its stdout ended: fail what waits, stop reading the bridge, and say why.
    private func ended(_ why: String?) {
        lock.lock()
        let pending = waiting
        waiting = [:]
        lock.unlock()
        pending.values.forEach { $0(.failure(Failure(why: "pi stopped"))) }
        bridgeIn?.readabilityHandler = nil
        DispatchQueue.main.async { self.onExit?(why) }
    }
}

extension PiProcess: PiLink {}
