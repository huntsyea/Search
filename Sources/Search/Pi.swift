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

/// Where pi is, and the environment it expects: the one the person's login
/// shell has. An app opened from the Dock doesn't get the shell's PATH, so
/// pi — and the node it runs on — wouldn't be found without it.
enum PiFinder {
    /// Looked up once a run, off the main thread.
    nonisolated(unsafe) private static var found: (path: String, environment: [String: String])?
    private static let lock = NSLock()

    static func locate() -> (path: String, environment: [String: String])? {
        lock.lock()
        defer { lock.unlock() }
        if let found { return found }
        var environment = loginEnvironment() ?? ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Where pi is put by its installers, in case the shell's PATH missed it.
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin"]
        let path = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        let search = path + extra.filter { !path.contains($0) }
        environment["PATH"] = search.joined(separator: ":")
        guard let pi = search.map({ $0 + "/pi" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        found = (pi, environment)
        return found
    }

    /// The login shell's environment, read with `env -0` after a marker, so
    /// whatever a profile prints first is left out. Five seconds at most.
    private static func loginEnvironment() -> [String: String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf '\\0__SEARCH_ENV__\\0'; /usr/bin/env -0"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchTime.now() + 5
        let reading = DispatchSemaphore(value: 0)
        var data = Data()
        DispatchQueue.global(qos: .userInitiated).async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            reading.signal()
        }
        if reading.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return nil
        }
        let marker = Data("\0__SEARCH_ENV__\0".utf8)
        guard let range = data.range(of: marker) else { return nil }
        var out: [String: String] = [:]
        for entry in data[range.upperBound...].split(separator: 0) {
            guard let text = String(data: Data(entry), encoding: .utf8), let equals = text.firstIndex(of: "=") else { continue }
            out[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return out.isEmpty ? nil : out
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

    private var pid: pid_t = 0
    private var input: FileHandle?
    private var bridgeOut: FileHandle?
    private var output: FileHandle?
    private var bridgeIn: FileHandle?
    private var errors: FileHandle?
    private var stdoutCarry = Data()
    private var bridgeCarry = Data()
    private var stderrTail = ""
    private var waiting: [String: (Result<[String: Any], Error>) -> Void] = [:]
    private var nextID = 0
    private let lock = NSLock()

    var running: Bool { pid != 0 }

    /// `arguments` follow `pi`; the extension and the session flags are the caller's.
    func start(arguments: [String], directory: URL, environment extra: [String: String]) throws {
        guard let (pi, base) = PiFinder.locate() else {
            throw Failure(why: "pi isn't installed — npm install -g @earendil-works/pi-coding-agent, then try again")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let toPi = Pipe(), fromPi = Pipe(), errPi = Pipe(), bridgeFromPi = Pipe(), bridgeToPi = Pipe()

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, toPi.fileHandleForReading.fileDescriptor, 0)
        posix_spawn_file_actions_adddup2(&actions, fromPi.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&actions, errPi.fileHandleForWriting.fileDescriptor, 2)
        // The extension's pipes: 3 for what pi says, 4 for what Search answers.
        posix_spawn_file_actions_adddup2(&actions, bridgeFromPi.fileHandleForWriting.fileDescriptor, 3)
        posix_spawn_file_actions_adddup2(&actions, bridgeToPi.fileHandleForReading.fileDescriptor, 4)
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        // Only those five: nothing else Search has open goes with it.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = [pi] + arguments
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        var environment = base
        extra.forEach { environment[$0] = $1 }
        var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0)=\($1)") } + [nil]
        defer { cEnv.forEach { free($0) } }

        var child: pid_t = 0
        let status = posix_spawn(&child, pi, &actions, &attributes, &cArgs, &cEnv)
        toPi.fileHandleForReading.closeFile()
        fromPi.fileHandleForWriting.closeFile()
        errPi.fileHandleForWriting.closeFile()
        bridgeFromPi.fileHandleForWriting.closeFile()
        bridgeToPi.fileHandleForReading.closeFile()
        guard status == 0 else { throw Failure(why: "pi couldn't be started (\(status))") }
        pid = child
        // A write to a pi that has just gone fails, rather than taking Search with it.
        _ = fcntl(toPi.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        _ = fcntl(bridgeToPi.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        input = toPi.fileHandleForWriting
        bridgeOut = bridgeToPi.fileHandleForWriting
        output = fromPi.fileHandleForReading
        bridgeIn = bridgeFromPi.fileHandleForReading
        errors = errPi.fileHandleForReading

        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { handle.readabilityHandler = nil; self.ended(); return }
            self.take(data, into: &self.stdoutCarry) { self.line($0) }
        }
        bridgeIn?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self.take(data, into: &self.bridgeCarry) { self.bridgeLine($0) }
        }
        errors?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { handle.readabilityHandler = nil; return }
            // The last few lines, for saying why it stopped; never parsed.
            let text = String(decoding: data, as: UTF8.self)
            self.lock.lock()
            self.stderrTail = String((self.stderrTail + text).suffix(2000))
            self.lock.unlock()
        }
    }

    /// Lines split on LF alone: JSON strings may hold U+2028 and U+2029.
    private func take(_ data: Data, into carry: inout Data, line: (Data) -> Void) {
        carry.append(data)
        while let newline = carry.firstIndex(of: 0x0A) {
            var record = carry[carry.startIndex..<newline]
            if record.last == 0x0D { record = record.dropLast() }
            carry.removeSubrange(carry.startIndex...newline)
            if !record.isEmpty { line(Data(record)) }
        }
    }

    private func line(_ data: Data) {
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
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
                send(["type": "extension_ui_response", "id": id, "cancelled": true])
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
            guard send(command) else {
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

    @discardableResult
    private func send(_ command: [String: Any]) -> Bool {
        guard let input, var data = try? JSONSerialization.data(withJSONObject: command) else { return false }
        data.append(0x0A)
        do { try input.write(contentsOf: data) } catch { return false }
        return true
    }

    /// Asked to stop: stdin closed is pi's orderly shutdown; a moment later,
    /// if it is still there, it is told to go.
    func stop() {
        guard pid != 0 else { return }
        try? input?.close()
        input = nil
        let child = pid
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if kill(child, 0) == 0 { kill(child, SIGTERM) }
        }
    }

    private func ended() {
        let child = pid
        guard child != 0 else { return }
        pid = 0
        var status: Int32 = 0
        waitpid(child, &status, 0)
        lock.lock()
        let pending = waiting
        waiting = [:]
        let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.unlock()
        pending.values.forEach { $0(.failure(Failure(why: "pi stopped"))) }
        bridgeIn?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        let why = tail.isEmpty ? nil : String(tail.split(separator: "\n").last ?? "")
        DispatchQueue.main.async { self.onExit?(why) }
    }

    deinit { if pid != 0 { kill(pid, SIGTERM) } }
}
