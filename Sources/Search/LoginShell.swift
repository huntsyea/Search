import Foundation

/// The person's login shell's environment, as their agents expect it: an app opened from the Dock doesn't get the
/// shell's PATH, so programs installed with npm, bun, Homebrew, … wouldn't be found without it.
enum LoginShell {
    nonisolated(unsafe) private static var cached: [String: String]?
    private static let lock = NSLock()

    /// For tests: the environment to use instead of the login shell's, so a
    /// variable it inherits can be set without touching the person's shell.
    nonisolated(unsafe) static var environmentForTests: [String: String]?

    /// The environment, with the usual install places added to PATH when the shell's missed them. Looked up once a
    /// run (five seconds at most), off the main thread; Search's own environment when the shell can't be read.
    static var environment: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let environmentForTests { return environmentForTests }
        if let cached { return cached }
        var environment = loginEnvironment() ?? ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Where agents are put by their installers, in case the shell's PATH missed it.
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin"]
        let path = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        let search = path + extra.filter { !path.contains($0) }
        environment["PATH"] = search.joined(separator: ":")
        cached = environment
        return environment
    }

    /// The first executable called `name` on that PATH.
    static func find(_ name: String) -> String? {
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return path.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Forget what the shell said, so the next look asks it again: a program
    /// installed since Search started is found without a restart.
    static func forget() {
        lock.lock()
        cached = nil
        lock.unlock()
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
