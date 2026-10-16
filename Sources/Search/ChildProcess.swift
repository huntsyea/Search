import Foundation

/// One started program, and the ends of its pipes Search holds.
final class ChildProcess: @unchecked Sendable {
    struct Failure: LocalizedError {
        let why: String
        var errorDescription: String? { why }
    }

    let pid: pid_t
    let input: FileHandle        // the program's stdin, written by Search
    let output: FileHandle       // the program's stdout
    let bridgeIn: FileHandle?    // fd 3: what Search's extension says (bridge only)
    let bridgeOut: FileHandle?   // fd 4: Search's answers (bridge only)

    private let errors: FileHandle
    private let tailLock = NSLock()
    private var tail = ""
    private let finished = DispatchSemaphore(value: 0)
    // Whether `wait()` has reaped the program, its status once reaped, and
    // whether its deadline passed. One lock guards all three, and every kill
    // with them.
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
        // the program is never left blocked writing.
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

    /// The last 2000 characters the program wrote to stderr; never parsed.
    var errorTail: String {
        tailLock.lock()
        defer { tailLock.unlock() }
        return tail
    }

    /// Waits for the program to end, then up to a second for the rest of its
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
        // Block until the program has exited, without reaping it yet: its pid,
        // and its group, stay ours to signal until the reap below. Waited on
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

    /// Signals the program and everything it started — the whole process
    /// group. The kill is inside the lock: once `wait()` has reaped it, its
    /// pid, and the group, may belong to someone else.
    func signal(_ signal: Int32) {
        stateLock.lock()
        if !reaped { kill(-pid, signal) }
        stateLock.unlock()
    }

    /// The deadline passed: ask the program to go, and remember that it did.
    /// Not once `wait()` has reaped it, so a late timer can't fail a run that
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

extension ChildProcess {
    /// `path` started with `arguments` in `directory` and `environment`: stdin, stdout and stderr on pipes, and with
    /// `bridge` two more pipes on descriptors 3 and 4. Nothing else Search has open goes with it, and it gets a
    /// process group of its own, so a signal reaches whatever it starts too.
    static func spawn(_ path: String, _ arguments: [String], in directory: URL,
                      environment: [String: String], bridge: Bool) throws -> ChildProcess {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let toChild = Pipe(), fromChild = Pipe(), errChild = Pipe()
        let bridgeFromChild = bridge ? Pipe() : nil
        let bridgeToChild = bridge ? Pipe() : nil

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, toChild.fileHandleForReading.fileDescriptor, 0)
        posix_spawn_file_actions_adddup2(&actions, fromChild.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&actions, errChild.fileHandleForWriting.fileDescriptor, 2)
        // The extension's pipes: 3 for what the program says, 4 for what Search answers.
        if let bridgeFromChild, let bridgeToChild {
            posix_spawn_file_actions_adddup2(&actions, bridgeFromChild.fileHandleForWriting.fileDescriptor, 3)
            posix_spawn_file_actions_adddup2(&actions, bridgeToChild.fileHandleForReading.fileDescriptor, 4)
        }
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        // Only those five: nothing else Search has open goes with it. And a
        // process group of its own, so a signal reaches whatever it started
        // too, and nothing it leaves behind can hold its stdout open.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = [path] + arguments
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0)=\($1)") } + [nil]
        defer { cEnv.forEach { free($0) } }

        var child: pid_t = 0
        let status = posix_spawn(&child, path, &actions, &attributes, &cArgs, &cEnv)
        toChild.fileHandleForReading.closeFile()
        fromChild.fileHandleForWriting.closeFile()
        errChild.fileHandleForWriting.closeFile()
        bridgeFromChild?.fileHandleForWriting.closeFile()
        bridgeToChild?.fileHandleForReading.closeFile()
        guard status == 0 else {
            throw Failure(why: "\(URL(fileURLWithPath: path).lastPathComponent) couldn't be started (\(status))")
        }
        // A write to a program that has just gone fails, rather than taking Search with it.
        _ = fcntl(toChild.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        if let bridgeToChild { _ = fcntl(bridgeToChild.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) }
        return ChildProcess(pid: child,
                            input: toChild.fileHandleForWriting,
                            output: fromChild.fileHandleForReading,
                            errors: errChild.fileHandleForReading,
                            bridgeIn: bridgeFromChild?.fileHandleForReading,
                            bridgeOut: bridgeToChild?.fileHandleForWriting)
    }
}

extension ChildProcess {
    /// stdin closed, stdout read to its end, the program waited for. At
    /// `deadline` it is sent SIGTERM, and SIGKILL two seconds later if still
    /// there. Throws when the deadline passed, or when the program failed
    /// without printing anything: why, from the last line of its stderr. With
    /// `requireSuccess`, any non-zero exit throws — even one that printed to
    /// stdout — so a caller that needs a real success can ask for it.
    func finish(deadline: TimeInterval, name: String, requireSuccess: Bool = false) throws -> String {
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
        // A signal only asks the program to go; its stdout closing is not it
        // ending — it can close it and hang, or keep ignoring SIGTERM. So wait
        // for the process itself, and only then stop the timers.
        let data = output.readDataToEndOfFile()
        let status = wait()
        terminate.cancel()
        force.cancel()
        stateLock.lock()
        let late = timedOut
        stateLock.unlock()
        if late {
            throw Failure(why: "\(name) took longer than \(Int(deadline)) seconds")
        }
        let text = String(decoding: data, as: UTF8.self)
        if status != 0, requireSuccess || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw Failure(why: ChildProcess.lastLine(errorTail) ?? ChildProcess.lastLine(text) ?? "\(name) stopped")
        }
        return text
    }

    /// The last line of `text` that isn't blank; nil when all are.
    private static func lastLine(_ text: String) -> String? {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }
}
