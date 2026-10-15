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

    /// pi started with `arguments` in `directory`: stdin, stdout and stderr
    /// on pipes, and with `bridge` the extension's two pipes on 3 and 4.
    /// Nothing else Search has open goes with it.
    static func spawn(_ arguments: [String], in directory: URL,
                      environment extra: [String: String] = [:], bridge: Bool) throws -> Child {
        guard let (pi, base) = locate() else {
            throw Failure(why: "pi isn't installed — npm install -g @earendil-works/pi-coding-agent, then try again")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let toPi = Pipe(), fromPi = Pipe(), errPi = Pipe()
        let bridgeFromPi = bridge ? Pipe() : nil
        let bridgeToPi = bridge ? Pipe() : nil

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
        if let bridgeFromPi, let bridgeToPi {
            posix_spawn_file_actions_adddup2(&actions, bridgeFromPi.fileHandleForWriting.fileDescriptor, 3)
            posix_spawn_file_actions_adddup2(&actions, bridgeToPi.fileHandleForReading.fileDescriptor, 4)
        }
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        // Only those five: nothing else Search has open goes with it. And a
        // process group of pi's own, so a signal reaches whatever pi started
        // too, and nothing it leaves behind can hold its stdout open.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

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
        bridgeFromPi?.fileHandleForWriting.closeFile()
        bridgeToPi?.fileHandleForReading.closeFile()
        guard status == 0 else { throw Failure(why: "pi couldn't be started (\(status))") }
        // A write to a pi that has just gone fails, rather than taking Search with it.
        _ = fcntl(toPi.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        if let bridgeToPi { _ = fcntl(bridgeToPi.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) }
        return Child(pid: child,
                     input: toPi.fileHandleForWriting,
                     output: fromPi.fileHandleForReading,
                     errors: errPi.fileHandleForReading,
                     bridgeIn: bridgeFromPi?.fileHandleForReading,
                     bridgeOut: bridgeToPi?.fileHandleForWriting)
    }

    /// `pi <arguments>` run to its end with stdin empty, in the temporary
    /// folder; its stdout. Thirty seconds at most, then it is ended.
    static func print(_ arguments: [String], deadline: TimeInterval = 30) throws -> String {
        let child = try spawn(arguments, in: URL(fileURLWithPath: NSTemporaryDirectory()), bridge: false)
        return try child.finish(deadline: deadline)
    }

    /// `pi --list-models`, read into models: its table's first line is the
    /// header; each other line is provider, model id, then more columns. Ten
    /// seconds at most, so a hung pi can't leave Settings' spinner up.
    static func models(deadline: TimeInterval = 10) throws -> [Model] {
        let child = try spawn(["--list-models"], in: URL(fileURLWithPath: NSTemporaryDirectory()), bridge: false)
        let table = try child.finish(deadline: deadline)
        return table.split(separator: "\n").dropFirst().compactMap { line in
            let cells = line.split(whereSeparator: \.isWhitespace)
            guard cells.count >= 2 else { return nil }
            return Model(provider: String(cells[0]), id: String(cells[1]))
        }
    }
}

extension Pi {
    /// One started pi, and the ends of its pipes Search holds.
    final class Child: @unchecked Sendable {
        let pid: pid_t
        let input: FileHandle        // pi's stdin, written by Search
        let output: FileHandle       // pi's stdout
        let bridgeIn: FileHandle?    // fd 3: what Search's extension says (bridge only)
        let bridgeOut: FileHandle?   // fd 4: Search's answers (bridge only)

        private let errors: FileHandle
        private let tailLock = NSLock()
        private var tail = ""
        private let finished = DispatchSemaphore(value: 0)
        // Whether `wait()` has reaped pi, its status once reaped, and whether
        // its deadline passed. One lock guards all three, and every kill with
        // them.
        private let stateLock = NSLock()
        private var reaped = false
        private var exitStatus: Int32 = 0
        private var timedOut = false

        init(pid: pid_t, input: FileHandle, output: FileHandle, errors: FileHandle,
             bridgeIn: FileHandle?, bridgeOut: FileHandle?) {
            self.pid = pid
            self.input = input
            self.output = output
            self.errors = errors
            self.bridgeIn = bridgeIn
            self.bridgeOut = bridgeOut
            // Read the tail itself: nobody else wants it, and it must drain so
            // pi is never left blocked writing.
            errors.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard let self else { return }
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    self.finished.signal()
                    return
                }
                // The last few lines, for saying why it stopped; never parsed.
                let text = String(decoding: data, as: UTF8.self)
                self.tailLock.lock()
                self.tail = String((self.tail + text).suffix(2000))
                self.tailLock.unlock()
            }
        }

        /// The last 2000 characters pi wrote to stderr; never parsed.
        var errorTail: String {
            tailLock.lock()
            defer { tailLock.unlock() }
            return tail
        }

        /// Waits for pi to end, then up to a second for the rest of its
        /// stderr; its exit status. Called again, it returns the same status
        /// at once.
        @discardableResult func wait() -> Int32 {
            stateLock.lock()
            if reaped {
                let status = exitStatus
                stateLock.unlock()
                return status
            }
            stateLock.unlock()
            // Block until pi has exited, without reaping it yet: its pid, and
            // its group, stay ours to signal until the reap below. Waited on
            // outside the lock, so a signal never waits for this.
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
            stateLock.lock()
            if !reaped {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                exitStatus = status
                reaped = true
            }
            let status = exitStatus
            stateLock.unlock()
            _ = finished.wait(timeout: .now() + 1)
            return status
        }

        /// Signals pi and everything it started — the whole process group.
        /// The kill is inside the lock: once `wait()` has reaped pi, its pid,
        /// and the group, may belong to someone else.
        func signal(_ signal: Int32) {
            stateLock.lock()
            if !reaped { kill(-pid, signal) }
            stateLock.unlock()
        }

        /// The deadline passed: ask pi to go, and remember that it did. Not
        /// once `wait()` has reaped it, so a late timer can't fail a run that
        /// has already ended well.
        private func expire() {
            stateLock.lock()
            if !reaped {
                timedOut = true
                kill(-pid, SIGTERM)
            }
            stateLock.unlock()
        }
    }
}

extension Pi.Child {
    /// stdin closed, stdout read to its end, pi waited for. At `deadline` pi
    /// is sent SIGTERM, and SIGKILL two seconds later if still there. Throws
    /// when the deadline passed, or when pi failed without printing
    /// anything: why, from the last line of its stderr.
    func finish(deadline: TimeInterval) throws -> String {
        try? input.close()
        let queue = DispatchQueue.global(qos: .userInitiated)
        let terminate = DispatchSource.makeTimerSource(queue: queue)
        terminate.schedule(deadline: .now() + deadline)
        terminate.setEventHandler { [weak self] in self?.expire() }
        terminate.resume()
        let force = DispatchSource.makeTimerSource(queue: queue)
        force.schedule(deadline: .now() + deadline + 2)
        force.setEventHandler { [weak self] in self?.signal(SIGKILL) }
        force.resume()
        // A signal only asks pi to go; its stdout closing is not pi ending —
        // it can close it and hang, or keep ignoring SIGTERM. So wait for the
        // process itself, and only then stop the timers.
        let data = output.readDataToEndOfFile()
        let status = wait()
        terminate.cancel()
        force.cancel()
        stateLock.lock()
        let late = timedOut
        stateLock.unlock()
        if late {
            throw Pi.Failure(why: "pi took longer than \(Int(deadline)) seconds")
        }
        let text = String(decoding: data, as: UTF8.self)
        if status != 0, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lines = errorTail.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            throw Pi.Failure(why: lines.last ?? "pi stopped")
        }
        return text
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

    private var child: Pi.Child?
    private var pid: pid_t = 0
    private var input: FileHandle?
    private var bridgeOut: FileHandle?
    private var output: FileHandle?
    private var bridgeIn: FileHandle?
    private var stdoutCarry = Data()
    private var bridgeCarry = Data()
    private var waiting: [String: (Result<[String: Any], Error>) -> Void] = [:]
    private var nextID = 0
    private let lock = NSLock()

    var running: Bool { pid != 0 }

    /// `arguments` follow `pi`; the extension and the session flags are the caller's.
    func start(arguments: [String], directory: URL, environment extra: [String: String]) throws {
        let child: Pi.Child
        do {
            child = try Pi.spawn(arguments, in: directory, environment: extra, bridge: true)
        } catch let failure as Pi.Failure {
            throw Failure(why: failure.why)
        }
        lock.lock()
        self.child = child
        pid = child.pid
        lock.unlock()
        input = child.input
        bridgeOut = child.bridgeOut
        output = child.output
        bridgeIn = child.bridgeIn

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

    /// Asked to stop: stdin closed is pi's orderly shutdown; three seconds
    /// later, if it is still there, SIGTERM, and two seconds after that
    /// SIGKILL, so even a pi that ignores the first still goes.
    func stop() { stop(grace: 3) }

    /// The same, after `grace` seconds rather than three (for tests).
    func stop(grace: TimeInterval) {
        // The child is taken under the lock, before stdin is closed: closing
        // it can end pi's stdout, and `ended()` could clear `child` first.
        lock.lock()
        let child = self.child
        let alive = pid != 0
        lock.unlock()
        guard let child, alive else { return }
        try? input?.close()
        input = nil
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            child.signal(SIGTERM)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace + 2) {
            child.signal(SIGKILL)
        }
    }

    private func ended() {
        lock.lock()
        let child = self.child
        let alive = pid != 0
        self.child = nil
        pid = 0
        lock.unlock()
        guard let child, alive else { return }
        // stdout closing means pi is done talking, not that it has gone: a pi
        // that closed it and stayed is still ended, a few seconds at most.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            child.signal(SIGTERM)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
            child.signal(SIGKILL)
        }
        child.wait()
        lock.lock()
        let pending = waiting
        waiting = [:]
        let tail = child.errorTail.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.unlock()
        pending.values.forEach { $0(.failure(Failure(why: "pi stopped"))) }
        bridgeIn?.readabilityHandler = nil
        let why = tail.isEmpty ? nil : String(tail.split(separator: "\n").last ?? "")
        DispatchQueue.main.async { self.onExit?(why) }
    }

    deinit {
        lock.lock()
        let child = self.child
        lock.unlock()
        child?.signal(SIGTERM)
    }
}
