import Foundation

// The ACP adapters Search sets up for agents that don't speak ACP
// themselves, and where they live (docs/design/agents.md, "Claude Code and
// Codex: ACP adapters"): Zed's adapters, npm packages installed at a pinned
// version into Search's own folder, with the person's npm and node.

/// An ACP adapter Search sets up for an agent that doesn't speak ACP itself.
struct Adapter: Equatable {
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
    static func script(_ adapter: Adapter) -> URL {
        folder(adapter)
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(adapter.package, isDirectory: true)
            .appendingPathComponent(adapter.entry)
    }

    /// Whether it is set up: its script is there.
    static func isSetUp(_ adapter: Adapter) -> Bool {
        FileManager.default.fileExists(atPath: script(adapter).path)
    }

    /// npm install of exactly that version into its folder, with the login
    /// shell's environment and npm from its PATH — five minutes at most, off
    /// the main thread. Its own scripts never run (--ignore-scripts): nothing
    /// of the package runs until the agent is started. A failure throws the
    /// last line npm wrote.
    static func setUp(_ adapter: Adapter) async throws {
        let folder = folder(adapter)
        guard let npm = npmForTests ?? LoginShell.find("npm") else {
            throw ChildProcess.Failure(why: "Setting up \(adapter.agent) needs npm — install Node.js, then try again.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let arguments = ["install", "--prefix", folder.path, "--ignore-scripts", "--no-audit",
                         "--no-fund", "--omit=dev", "--loglevel=error",
                         "\(adapter.package)@\(adapter.version)"]
        let environment = LoginShell.environment
        _ = try await Task.detached(priority: .userInitiated) {
            let child = try ChildProcess.spawn(npm, arguments, in: folder, environment: environment, bridge: false)
            return try child.finish(deadline: 300, name: "npm")
        }.value
        // npm can end well with nothing installed (a proxy page, say): the
        // point of it all is the script.
        guard isSetUp(adapter) else {
            throw ChildProcess.Failure(why: "\(adapter.agent)'s adapter didn't install — try again.")
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
    /// home's file, not from the environment. The home is made and the files
    /// kept; auth.json is never copied.
    static func codexEnvironment() -> [String: String] {
        let home = codexHome()
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Atomically: it is Search's own file, written afresh each time the
        // spec is built, so a half-written one is never read.
        try? codexConfig.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let link = home.appendingPathComponent("auth.json")
        // A link already there is left alone, even one whose target is gone.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil,
           !FileManager.default.fileExists(atPath: link.path) {
            let person = personCodexHome().appendingPathComponent("auth.json")
            if FileManager.default.fileExists(atPath: person.path) {
                try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: person)
            }
        }
        return ["CODEX_HOME": home.path]
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
