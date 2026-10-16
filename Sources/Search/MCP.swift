import Foundation
import Security

// Search's browser tools as an MCP server (Model Context Protocol, JSON-RPC
// 2.0), for ACP agents: pi has its own extension (AgentTools.extensionSource),
// but every other agent takes tools only this way (docs/design/agents.md).
//
// This is the protocol alone: messages in, messages out. The socket they
// travel on is elsewhere — a thin `Search --mcp` carries MCP's bytes to the
// chat's socket, and nothing here touches it. Each `tools/call` goes where
// pi's calls go, `AgentTools.run`, so asking, pausing and marking stay the
// catalogue's, not this file's.

/// One chat's MCP server: the agent's messages in, and the answers it is
/// owed back out, with the browser's tools behind them.
@MainActor
final class MCPServer {
    /// The protocol versions it speaks, newest first.
    static let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private let call: ([String: Any], @escaping @MainActor () -> Bool, @escaping ([String: Any]) -> Void) -> Void
    private let cancel: () -> Void
    private let send: ([String: Any]) -> Void

    /// Requests waiting on a tool call, by the key made from their id — kind
    /// and all, so 7 and "7" are different: the original id is kept to echo.
    private var waiting: [String: Any] = [:]
    /// Calls the agent gave up on: their reply, when it comes, isn't sent.
    private var cancelled: Set<String> = []

    /// call: a tool call in the shape pi's extension sends — ["kind": "tool",
    ///   "id": <String>, "name": ..., "args": [...]] — with a way to ask
    ///   whether the agent has given it up, answered once with what
    ///   AgentTools.run answers (content, isError, details).
    /// cancel: a call given up on by the agent (the person's Stop), as pi's "cancel".
    /// send: a message to the agent.
    init(call: @escaping ([String: Any], @escaping @MainActor () -> Bool, @escaping ([String: Any]) -> Void) -> Void,
         cancel: @escaping () -> Void,
         send: @escaping ([String: Any]) -> Void) {
        self.call = call
        self.cancel = cancel
        self.send = send
    }

    /// One message from the agent: a request is answered through `send`; a
    /// notification isn't. What isn't a valid JSON-RPC message is answered
    /// with the error it earns.
    func receive(_ message: Any) {
        guard let message = message as? [String: Any], message["jsonrpc"] as? String == "2.0" else {
            return invalid()
        }
        // A response to something we asked: we ask nothing, so there's
        // nothing to match it to.
        guard let method = message["method"] as? String else { return }
        // A notification carries no id, so nothing is owed for it.
        guard message.keys.contains("id") else { return notification(method, message) }
        guard let id = message["id"] else { return invalid() }
        guard MCPServer.allowedID(id) else { return invalid() }
        request(method, id: id, message)
    }

    /// A line that isn't JSON at all.
    func unreadable() {
        send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
    }

    /// The connection is gone: every call still waiting is given up on, and
    /// the catalogue is told once, so nothing held by Pause acts later.
    func close() {
        guard !waiting.isEmpty else { return }
        cancelled.formUnion(waiting.keys)
        waiting.removeAll()
        cancel()
    }

    // MARK: - requests

    private func request(_ method: String, id: Any, _ message: [String: Any]) {
        switch method {
        case "initialize":
            let params = message["params"] as? [String: Any] ?? [:]
            // The agent's version if it is one we know, else our newest:
            // the agent settles on what it can use from this answer.
            let asked = params["protocolVersion"] as? String ?? ""
            let version = MCPServer.versions.contains(asked) ? asked : MCPServer.versions[0]
            answer(id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "search", "title": "Search",
                               "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"],
                "instructions": AgentTools.systemPrompt,
            ])
        case "ping":
            answer(id, [:])
        case "tools/list":
            answer(id, ["tools": AgentTools.mcpTools])
        case "tools/call":
            callTool(id, message)
        default:
            fail(id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// A tool call: named and vetted here, then handed to the catalogue,
    /// which answers once.
    private func callTool(_ id: Any, _ message: [String: Any]) {
        let params = message["params"] as? [String: Any] ?? [:]
        guard let name = params["name"] as? String else {
            return fail(id, code: -32602, message: "Invalid params: name must be a string")
        }
        // Absent arguments mean none; anything but an object is a mistake.
        let args: [String: Any]
        if let given = params["arguments"] {
            guard let object = given as? [String: Any] else {
                return fail(id, code: -32602, message: "Invalid params: arguments must be an object")
            }
            args = object
        } else {
            args = [:]
        }
        guard AgentTools.names.contains(name) else {
            return fail(id, code: -32602, message: "Unknown tool: \(name)")
        }
        let key = MCPServer.key(id)
        waiting[key] = id
        call(["kind": "tool", "id": key, "name": name, "args": args],
             { [weak self] in self?.cancelled.contains(key) ?? true },
             { [weak self] reply in self?.answered(key, reply) })
    }

    /// What the catalogue answered, sent on unless the agent gave the call
    /// up while it ran. pi's `details` are the chat's own — the step it
    /// shows — so the agent gets only the content and the error flag.
    private func answered(_ key: String, _ reply: [String: Any]) {
        guard let id = waiting.removeValue(forKey: key) else { return }
        guard cancelled.remove(key) == nil else { return }
        answer(id, ["content": reply["content"] ?? [], "isError": reply["isError"] as? Bool ?? false])
    }

    // MARK: - notifications

    private func notification(_ method: String, _ message: [String: Any]) {
        // The person's Stop, from the agent's side: a call still waiting is
        // remembered, so the reply it no longer wants isn't sent, and the
        // catalogue is told to stop.
        guard method == "notifications/cancelled",
              let params = message["params"] as? [String: Any],
              let requestId = params["requestId"] else { return }
        let key = MCPServer.key(requestId)
        guard waiting[key] != nil else { return }
        cancelled.insert(key)
        cancel()
    }

    // MARK: - ids and envelopes

    /// Whether a request's id is one JSON-RPC allows: a string, or an
    /// integer. A bool is an NSNumber too, and a float, null and an object
    /// are none of them.
    private static func allowedID(_ id: Any) -> Bool {
        if id is String { return true }
        guard let number = id as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return !CFNumberIsFloatType(number)
    }

    /// A request's id as a key: the integer 7 and the string "7" are
    /// different requests, and are answered apart.
    private static func key(_ id: Any) -> String {
        if let text = id as? String { return "s:\(text)" }
        if let number = id as? NSNumber { return "n:\(number.intValue)" }
        return "x:\(id)"
    }

    /// A message that isn't JSON-RPC 2.0, or a request whose id isn't one.
    private func invalid() {
        send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid Request"]])
    }

    // MARK: - out

    private func answer(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func fail(_ id: Any, code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }
}

/// Where one chat's agent reaches its browser tools: a socket in Search's
/// folder that only this user can open, and a token the agent is given in the
/// command that starts `Search --mcp`. Each connection that gives the token
/// first is an MCP session of its own (an agent may start its server again).
@MainActor
final class MCPDoor {
    let path: String
    let token: String

    /// The binary the helper mode runs as: Search itself. A test can put a
    /// built copy here first, as `Pi.executable` does for pi.
    nonisolated(unsafe) static var executableOverride: String?

    static var executable: String {
        if let executableOverride { return executableOverride }
        return Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    private let call: ([String: Any], @escaping @MainActor () -> Bool, @escaping ([String: Any]) -> Void) -> Void
    private let cancel: () -> Void
    private var listener: Int32 = -1
    private var accepting: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]

    /// The MCP server entry an ACP `session/new` takes: Search itself, as the
    /// helper for this chat.
    var server: [String: Any] {
        ["name": "search", "command": MCPDoor.executable,
         "args": ["--mcp", path, token], "env": [String]()]
    }

    init?(call: @escaping ([String: Any], @escaping @MainActor () -> Bool, @escaping ([String: Any]) -> Void) -> Void,
          cancel: @escaping () -> Void) {
        self.call = call
        self.cancel = cancel
        // A folder only this user can look in, and a socket named at random:
        // a guessable path in a shared folder would be an invitation.
        let folder = Store.folder.appendingPathComponent("MCP", isDirectory: true)
        path = folder.appendingPathComponent(MCPDoor.randomHex(8) + ".sock").path
        token = MCPDoor.randomHex(32)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            // One made by an older run, or under a wider umask, may be looser.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        } catch {
            return nil
        }
        guard let listener = UnixSocket.listen(at: path) else { return nil }
        self.listener = listener
        // Accepted sockets inherit this one flag, so even a peer that has
        // already gone can't take Search down with a write — the accepted
        // socket itself would refuse to be flagged by then.
        _ = fcntl(listener, F_SETNOSIGPIPE, 1)
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .main)
        source.setEventHandler { [weak self] in self?.accept() }
        // A cancelled source finishes later, so the fd is closed here, once
        // the dispatch system is done with it — never right after cancel().
        source.setCancelHandler { Darwin.close(listener) }
        source.resume()
        accepting = source
    }

    /// The chat's socket is gone: no more agents reach its tools.
    func close() {
        accepting?.cancel()
        accepting = nil
        // Closed by the source's cancel handler, not here.
        listener = -1
        connections.values.forEach { $0.close() }
        connections = [:]
        unlink(path)
    }

    // No deinit: it can't touch the listener or the connections, which are
    // the main actor's, so the chat calls close() when it lets the door go.

    private func accept() {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        // Only this user, as the bench says for its own socket.
        guard UnixSocket.peerIsMe(fd) else {
            Darwin.close(fd)
            return
        }
        // A write to a gone agent fails; it must not take Search with it.
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        let connection = Connection(fd: fd, token: token, call: call, cancel: cancel) { [weak self] fd in
            self?.connections[fd] = nil
        }
        connections[fd] = connection
    }

    /// Random hex from the system's own randomness; a UUID if that can't be
    /// had (weaker, but there is nothing better to do).
    private static func randomHex(_ bytes: Int) -> String {
        var raw = [UInt8](repeating: 0, count: bytes)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes, &raw) == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        return raw.map { String(format: "%02x", $0) }.joined()
    }
}

/// One agent's session on a door: the token first, then MCP lines, each
/// answered on the same fd. A connection that never gives the token is shut
/// at once, and one whose agent goes quietly is forgotten.
@MainActor
private final class Connection {
    private let fd: Int32
    private let token: String
    private let call: ([String: Any], @escaping @MainActor () -> Bool, @escaping ([String: Any]) -> Void) -> Void
    private let cancel: () -> Void
    private let gone: (Int32) -> Void
    private let source: DispatchSourceRead
    /// The fd's sources: it is closed only once every one of them has
    /// finished cancelling, which a dispatch source does late.
    private let group: DispatchGroup
    private var bytes = Data()
    private var server: MCPServer?
    /// Lines for the agent that the socket hasn't taken yet, and a source
    /// that wakes us when it will take more.
    private var pending = Data()
    private var writer: DispatchSourceWrite?
    private var open = true

    init(fd: Int32, token: String,
         call: @escaping ([String: Any], @escaping @MainActor () -> Bool, @escaping ([String: Any]) -> Void) -> Void,
         cancel: @escaping () -> Void,
         gone: @escaping (Int32) -> Void) {
        self.fd = fd
        self.token = token
        self.call = call
        self.cancel = cancel
        self.gone = gone
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let group = DispatchGroup()
        self.group = group
        group.enter()
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.read() }
        source.setCancelHandler { group.leave() }
        source.resume()
    }

    private func read() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(fd, &chunk, chunk.count)
        if count < 0, errno == EAGAIN { return }
        guard count > 0 else { return close() }
        bytes.append(contentsOf: chunk[0..<count])
        // A line that never ends is not a message.
        if bytes.count > 8 * 1024 * 1024, !bytes.contains(0x0A) { return close() }
        while let newline = bytes.firstIndex(of: 0x0A) {
            var line = bytes[bytes.startIndex..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            bytes.removeSubrange(bytes.startIndex...newline)
            take(Data(line))
            guard open else { return }
        }
    }

    /// The first line is the token; every line after it is a message of this
    /// connection's own session.
    private func take(_ line: Data) {
        guard let server else {
            guard tokenMatches(line) else { return close() }
            self.server = MCPServer(call: call, cancel: cancel) { [weak self] message in self?.say(message) }
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: line) else { return server.unreadable() }
        server.receive(object)
    }

    /// The token, compared without stopping early: a mismatch shouldn't say
    /// how much of it was right.
    private func tokenMatches(_ line: Data) -> Bool {
        let wanted = Data(token.utf8)
        guard line.count == wanted.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(line, wanted) { difference |= a ^ b }
        return difference == 0
    }

    /// A line for the agent. Kept, not forced out here: the main thread
    /// waits for nobody, so an agent that has stopped reading — a big
    /// picture, a hung agent — can't freeze Search.
    private func say(_ message: [String: Any]) {
        guard open, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        pending.append(data)
        // An agent that has read nothing for this much hasn't just paused.
        if pending.count > 64 * 1024 * 1024 { return close() }
        flush()
    }

    /// Write what the socket will take. When it is full, wait for the socket
    /// to say it can take more rather than sitting in a loop here.
    private func flush() {
        while open, !pending.isEmpty {
            let written = pending.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(fd, base, raw.count)
            }
            if written > 0 {
                pending.removeFirst(written)
                continue
            }
            if written < 0, errno == EAGAIN {
                if writer == nil {
                    let group = self.group
                    group.enter()
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
                    source.setEventHandler { [weak self] in self?.flush() }
                    source.setCancelHandler { group.leave() }
                    source.resume()
                    writer = source
                }
                return
            }
            // Anything else — and a zero write — is the socket refusing: done.
            return close()
        }
        writer?.cancel()
        writer = nil
    }

    func close() {
        guard open else { return }
        open = false
        // The catalogue first: a call held by Pause is told it was given up.
        server?.close()
        writer?.cancel()
        writer = nil
        if !source.isCancelled { source.cancel() }
        // The fd waits for every source's cancellation to finish.
        let socket = fd
        group.notify(queue: .main) { Darwin.close(socket) }
        gone(fd)
    }
}

/// The helper behind `Search --mcp`: bytes between the agent's stdin and
/// stdout and the chat's socket, and nothing else. It runs before AppKit, on
/// no actor, so the browser's world is never built for it.
enum MCPPipe {
    static func run(socket: String, token: String) -> Int32 {
        // A write to a socket whose reader is gone fails; it must not end the
        // helper with a signal it can't answer.
        signal(SIGPIPE, SIG_IGN)
        guard let fd = UnixSocket.connect(to: socket) else { return 1 }
        guard write(fd, Data((token + "\n").utf8)) else {
            Darwin.close(fd)
            return 1
        }
        // The agent's input into the socket on a thread of its own, so its
        // ending only shuts our writing side; the socket's answers out to the
        // agent's output here, until the socket ends.
        let into = Thread {
            copy(from: STDIN_FILENO, to: fd) { shutdown(fd, SHUT_WR) }
        }
        into.start()
        copy(from: fd, to: STDOUT_FILENO) {}
        Darwin.close(fd)
        return 0
    }

    /// Copy until the source ends (zero bytes) or fails, then `then`.
    private static func copy(from source: Int32, to sink: Int32, then: () -> Void) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(source, &buffer, buffer.count)
            if count == 0 { then(); return }
            if count < 0 {
                if errno == EINTR { continue }
                then()
                return
            }
            guard write(sink, Data(buffer[0..<count])) else { then(); return }
        }
    }

    /// All of `data`, or false when the other end is gone.
    @discardableResult
    private static func write(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let n: Int = Darwin.write(fd, base + sent, raw.count - sent)
                if n <= 0 {
                    if errno == EINTR { continue }
                    return false
                }
                sent += n
            }
            return true
        }
    }
}
