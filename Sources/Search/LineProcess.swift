import Foundation

/// A program Search talks to a line of JSON at a time over its stdin and stdout, and how it is let go of: the same
/// for pi and for every ACP agent.
final class LineProcess: @unchecked Sendable {
    /// Each line of its stdout, parsed as JSON (lines that aren't are let go), in order, off the main thread.
    var onLine: ((Any) -> Void)?
    /// It ended, and the last line of its stderr if it wrote one. Off the main thread, once, after every line.
    var onEnd: ((String?) -> Void)?

    private var child: ChildProcess?
    private var pid: pid_t = 0
    private var input: FileHandle?
    private var output: FileHandle?
    private var stdoutCarry = Data()
    private let lock = NSLock()
    /// Writes to the program's stdin, one at a time: a program that has
    /// stopped reading can't hold the main thread.
    private let writeQueue = DispatchQueue(label: "search.line-process.write")

    var running: Bool { pid != 0 }

    /// Holds `child` from now on: its stdout is read from here.
    func start(_ child: ChildProcess) {
        lock.lock()
        self.child = child
        pid = child.pid
        input = child.input
        lock.unlock()
        output = child.output

        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { handle.readabilityHandler = nil; self.ended(); return }
            LineProcess.take(data, into: &self.stdoutCarry) { self.line($0) }
        }
    }

    /// Lines split on LF alone: JSON strings may hold U+2028 and U+2029.
    static func take(_ data: Data, into carry: inout Data, line: (Data) -> Void) {
        carry.append(data)
        while let newline = carry.firstIndex(of: 0x0A) {
            var record = carry[carry.startIndex..<newline]
            if record.last == 0x0D { record = record.dropLast() }
            carry.removeSubrange(carry.startIndex...newline)
            if !record.isEmpty { line(Data(record)) }
        }
    }

    private func line(_ data: Data) {
        guard let record = try? JSONSerialization.jsonObject(with: data) else { return }
        onLine?(record)
    }

    /// One object as a line on its stdin; false when it has gone. The write
    /// happens on a queue of its own: a full pipe waits there, not here.
    @discardableResult func send(_ object: Any) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        data.append(0x0A)
        lock.lock()
        let input = self.input
        if let input {
            writeQueue.async { [weak self] in
                do { try input.write(contentsOf: data) } catch { self?.closeInput() }
            }
        }
        lock.unlock()
        return input != nil
    }

    /// A write failed: the program has gone, so its input is closed too.
    private func closeInput() {
        lock.lock()
        let input = self.input
        self.input = nil
        lock.unlock()
        input?.closeFile()
    }

    /// Asked to stop: stdin closed is its orderly shutdown; `grace` seconds
    /// later, if it is still there, SIGTERM, and two seconds after that
    /// SIGKILL, so even one that ignores the first still goes.
    func stop(grace: TimeInterval = 3) {
        // The child is taken under the lock, before stdin is closed: closing
        // it can end its stdout, and `ended()` could clear `child` first. The
        // close waits on the write queue, after whatever was queued for it;
        // the signals don't, so a write stuck on a full pipe is freed when
        // the program is signalled.
        lock.lock()
        let child = self.child
        let alive = pid != 0
        let input = self.input
        self.input = nil
        if let input { writeQueue.async { input.closeFile() } }
        lock.unlock()
        guard let child, alive else { return }
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
        // stdout closing means it is done talking, not that it has gone: one
        // that closed it and stayed is still ended, a few seconds at most.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            child.signal(SIGTERM)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
            child.signal(SIGKILL)
        }
        child.wait()
        let tail = child.errorTail.trimmingCharacters(in: .whitespacesAndNewlines)
        let why = tail.isEmpty ? nil : String(tail.split(separator: "\n").last ?? "")
        onEnd?(why)
    }

    deinit {
        lock.lock()
        let child = self.child
        lock.unlock()
        child?.signal(SIGTERM)
        if let child {
            // Held until reaped: a connection dropped before its program
            // ended leaves no zombie.
            DispatchQueue.global().async { _ = child.wait() }
        }
    }
}
