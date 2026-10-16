import Foundation

// The ACP adapters Search sets up for agents that don't speak ACP
// themselves, and where they live (docs/design/agents.md, "Claude Code and
// Codex: ACP adapters"): Zed's adapters, npm packages installed at a pinned
// version into Search's own folder, with the person's npm and node.

/// An ACP adapter Search sets up for an agent that doesn't speak ACP itself.
struct Adapter: Equatable, Hashable {
    let agent: String        // "claude", "codex"
    let package: String      // "@agentclientprotocol/claude-agent-acp"
    let version: String      // "0.91.0"
    let entry: String        // path inside the package: "dist/index.js"
}

enum Adapters {
    static let claude = Adapter(agent: "claude", package: "@agentclientprotocol/claude-agent-acp",
                                version: "0.91.0", entry: "dist/index.js")
    static let codex = Adapter(agent: "codex", package: "@agentclientprotocol/codex-acp",
                               version: "2.2.2", entry: "dist/index.js")

    /// Claude's meta for session/new: the system prompt Search's tools are
    /// described in, and Claude's own tools off — none of the person's
    /// settings, hooks, plugins or MCP servers, only Search's MCP server.
    static var claudeMeta: [String: Any] {
        ["systemPrompt": AgentTools.systemPrompt,
         "claudeCode": ["options": ["tools": [String](), "settingSources": [String](), "strictMcpConfig": true]]]
    }

    /// Where one is set up: Store.folder/Agents/<agent>-<version>, so a new
    /// pinned version sits beside the old.
    static func folder(_ adapter: Adapter) -> URL {
        Store.folder.appendingPathComponent("Agents", isDirectory: true)
            .appendingPathComponent("\(adapter.agent)-\(adapter.version)", isDirectory: true)
    }

    /// Its program: <folder>/node_modules/<package>/<entry>.
    static func script(_ adapter: Adapter) -> URL { script(adapter, in: folder(adapter)) }

    static func script(_ adapter: Adapter, in base: URL) -> URL {
        base.appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(adapter.package, isDirectory: true)
            .appendingPathComponent(adapter.entry)
    }

    /// Whether it is set up: its script and the package's own manifest at the
    /// pinned version are both there, so a half-finished install isn't it.
    static func isSetUp(_ adapter: Adapter) -> Bool { isInstalled(adapter, in: folder(adapter)) }

    /// Whether an install in `base` landed whole: the entry script and the
    /// package's package.json naming exactly the pinned version.
    static func isInstalled(_ adapter: Adapter, in base: URL) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: script(adapter, in: base).path) else { return false }
        let manifest = base.appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(adapter.package, isDirectory: true)
            .appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String else { return false }
        return version == adapter.version
    }

    /// One install at a time per adapter: a second caller waits for the one
    /// already running rather than starting its own.
    @MainActor private static var runningSetUps: [Adapter: Task<Void, Error>] = [:]

    /// npm install of exactly that version into a staging folder beside the
    /// final one, with the login shell's environment and npm from its PATH —
    /// five minutes at most, off the main thread. Its own scripts never run
    /// (--ignore-scripts): nothing of the package runs until the agent is
    /// started. It must exit well and land whole, then the final folder is
    /// replaced by the staging one; any failure leaves the final folder as it
    /// was and removes the staging one.
    @MainActor
    static func setUp(_ adapter: Adapter) async throws {
        if let running = runningSetUps[adapter] { return try await running.value }
        let task = Task { try await install(adapter) }
        runningSetUps[adapter] = task
        defer { runningSetUps[adapter] = nil }
        try await task.value
    }

    nonisolated private static func install(_ adapter: Adapter) async throws {
        guard let npm = npmForTests ?? LoginShell.find("npm") else {
            throw ChildProcess.Failure(why: "Setting up \(adapter.agent) needs npm — install Node.js, then try again.")
        }
        let final = folder(adapter)
        let staging = final.deletingLastPathComponent()
            .appendingPathComponent(final.lastPathComponent + ".partial-" + String(UUID().uuidString.prefix(8)),
                                    isDirectory: true)
        let arguments = ["install", "--prefix", staging.path, "--ignore-scripts", "--no-audit",
                         "--no-fund", "--omit=dev", "--loglevel=error",
                         "\(adapter.package)@\(adapter.version)"]
        let environment = LoginShell.environment
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            _ = try await Task.detached(priority: .userInitiated) {
                let child = try ChildProcess.spawn(npm, arguments, in: staging, environment: environment, bridge: false)
                return try child.finish(deadline: 300, name: "npm", requireSuccess: true)
            }.value
            // npm can end well with nothing installed (a proxy page, say), or
            // with a part of it: the point of the install is the whole package.
            guard isInstalled(adapter, in: staging) else {
                throw ChildProcess.Failure(why: "\(adapter.agent)'s adapter didn't install — try again.")
            }
            // The old set-up folder goes only for a new one whole enough to
            // replace it.
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: staging, to: final)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// For tests: the npm to run instead of the PATH's.
    nonisolated(unsafe) static var npmForTests: String?

    // MARK: - Codex's own home

    /// Search's own Codex home: none of the person's config, MCP servers,
    /// plugins or skills come with it; only their sign-in is linked in.
    static func codexHome() -> URL {
        Store.folder.appendingPathComponent("Agents", isDirectory: true)
            .appendingPathComponent("codex-home", isDirectory: true)
    }

    /// For tests: the person's own Codex home, in place of the login
    /// environment's CODEX_HOME or ~/.codex.
    nonisolated(unsafe) static var codexHomeForTests: String?

    /// Where the person's own Codex keeps its sign-in.
    static func personCodexHome() -> URL {
        if let hooked = codexHomeForTests { return URL(fileURLWithPath: hooked) }
        if let set = LoginShell.environment["CODEX_HOME"], !set.isEmpty { return URL(fileURLWithPath: set) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    /// Codex's environment in Search's own home: the person's sign-in, a
    /// symlink, so their sign-in is used and one done here is theirs too; and
    /// Search's config.toml, because Codex reads these settings only from its
    /// home's file, not from the environment. Throwing: a home that can't be
    /// made or linked stops the start.
    static func codexEnvironment() throws -> [String: String] {
        let home = codexHome()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try codexConfig.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try linkCodexAuth()
        return ["CODEX_HOME": home.path]
    }

    /// Keep Search's `auth.json` a link to the person's own, so their sign-in
    /// is used and one done here is theirs too. A link to the right file is
    /// kept; a link anywhere else is replaced. A regular file is a sign-in
    /// made here (or one Codex wrote in place of the link): if the person has
    /// none, it becomes theirs; if they have one, theirs is kept and ours
    /// goes. Codex is assumed to write auth.json in place, following the
    /// link; if a write ever replaced it, the next start puts the person's
    /// file first again.
    static func linkCodexAuth() throws {
        let manager = FileManager.default
        let ours = codexHome().appendingPathComponent("auth.json")
        let theirs = personCodexHome().appendingPathComponent("auth.json")
        if let target = try? manager.destinationOfSymbolicLink(atPath: ours.path) {
            if URL(fileURLWithPath: target).standardizedFileURL == theirs.standardizedFileURL { return }
            try manager.removeItem(at: ours)
            try manager.createSymbolicLink(at: ours, withDestinationURL: theirs)
            return
        }
        if manager.fileExists(atPath: ours.path) {
            if manager.fileExists(atPath: theirs.path) {
                try manager.removeItem(at: ours)
            } else {
                try manager.createDirectory(at: theirs.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.moveItem(at: ours, to: theirs)
            }
            try manager.createSymbolicLink(at: ours, withDestinationURL: theirs)
            return
        }
        // Nothing: link, even if theirs isn't there yet — a sign-in in Search
        // then writes theirs.
        try manager.createDirectory(at: theirs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: ours, withDestinationURL: theirs)
    }

    /// Codex's own config, in Search's own home. Its shell and the rest of
    /// its own tools are off; what's left asks first, and Search refuses it.
    /// Code mode stays on: this Codex's models call every tool, Search's MCP
    /// tools included, through code mode's `exec` — a JavaScript runtime that
    /// calls tools, not a shell — so with it off Search's tools couldn't be
    /// reached at all.
    static let codexConfig = """
    # Written by Search for its chats' Codex; changes are lost.
    sandbox_mode = "read-only"
    approval_policy = "on-request"
    web_search = "disabled"

    [features]
    shell_tool = false
    unified_exec = false
    apps = false
    browser_use = false
    computer_use = false
    multi_agent = false
    multi_agent_v2 = false
    plugins = false
    view_image = false
    hooks = false
    skill_search = false
    tool_suggest = false
    sleep_tool = false
    goals = false
    image_generation = false
    """
}
