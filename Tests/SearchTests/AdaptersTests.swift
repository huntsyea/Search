import Foundation
import XCTest
@testable import Search

/// The ACP adapters Search sets up for Claude Code and Codex, and the two as
/// agents (Adapters.swift, Agents.swift): docs/design/agents.md, "Claude Code
/// and Codex: ACP adapters". A fake npm stands in for the person's, so nothing
/// is downloaded; a fake PATH stands in for the login shell's.
@MainActor
final class AdaptersTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private var folder: URL!
    private var chats: [Chat] = []

    override func setUp() async throws {
        try await super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("adapters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Adapters.npmForTests = nil
        Adapters.codexHomeForTests = nil
        // Nothing set up from an earlier test.
        try? FileManager.default.removeItem(at: Adapters.folder(Adapters.claude))
        try? FileManager.default.removeItem(at: Adapters.folder(Adapters.codex))
        try? FileManager.default.removeItem(at: Adapters.codexHome())
    }

    override func tearDown() async throws {
        for chat in chats { Chats.delete(chat) }
        chats = []
        Adapters.npmForTests = nil
        Adapters.codexHomeForTests = nil
        Agents.searchPathForTests = nil
        Chat.piForTests = nil
        Store.settings.removeObject(forKey: Agents.customKey)
        Store.settings.removeObject(forKey: Agents.hiddenKey)
        Store.settings.removeObject(forKey: Chats.agentKey)
        for key in Store.settings.dictionaryRepresentation().keys
        where key.hasPrefix("chat.agents.signin.") || key.hasPrefix("chat.agents.state.")
            || key.hasPrefix("chat.agents.model.") {
            Store.settings.removeObject(forKey: key)
        }
        LoginShell.forget()
        try? FileManager.default.removeItem(at: folder)
        try await super.tearDown()
    }

    // MARK: - setting one up

    /// A fake npm: it writes the arguments it was given to `args`, then makes
    /// the package's entry script and package.json inside the folder it was
    /// told to install into. It is a /bin/sh script, so no npm or node is
    /// needed to test setUp. `delay` makes it slow; `installsThenFails` writes
    /// everything and still exits 1.
    private func fakeNpm(failWith error: String? = nil, installsThenFails: Bool = false,
                         delay: Int = 0) throws -> (script: URL, args: URL) {
        let script = folder.appendingPathComponent("npm-\(UUID().uuidString)")
        let args = folder.appendingPathComponent("args-\(UUID().uuidString)")
        let body: String
        if let error {
            body = """
            #!/bin/sh
            echo '\(error)' >&2
            exit 1
            """
        } else {
            let wait = delay > 0 ? "sleep \(delay)\n" : ""
            let fail = installsThenFails ? "exit 1\n" : ""
            body = """
            #!/bin/sh
            \(wait)printf '%s\\n' "$@" >> '\(args.path)'
            prefix=""
            last=""
            prev=""
            for arg in "$@"; do
              if [ "$prev" = "--prefix" ]; then prefix="$arg"; fi
              prev="$arg"
              last="$arg"
            done
            package="${last%@*}"
            version="${last##*@}"
            mkdir -p "$prefix/node_modules/$package/dist"
            : > "$prefix/node_modules/$package/dist/index.js"
            printf '{"version":"%s"}' "$version" > "$prefix/node_modules/$package/package.json"
            \(fail)
            """
        }
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, args)
    }

    func testSetUpInstallsThePinnedAdapter() async throws {
        let (npm, log) = try fakeNpm()
        Adapters.npmForTests = npm.path
        let adapter = Adapters.claude
        let expected = Adapters.folder(adapter)

        try await Adapters.setUp(adapter)

        XCTAssertTrue(Adapters.isSetUp(adapter))
        XCTAssertTrue(FileManager.default.fileExists(atPath: Adapters.script(adapter).path))

        // Exactly the pinned version, with --ignore-scripts, into a staging
        // folder beside the final one (moved into place once it landed whole).
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "install")
        XCTAssertTrue(lines.contains("\(adapter.package)@\(adapter.version)"))
        XCTAssertTrue(lines.contains("--ignore-scripts"))
        let prefixAt = try XCTUnwrap(lines.firstIndex(of: "--prefix"))
        XCTAssertTrue(lines[prefixAt + 1].hasPrefix(expected.path + ".partial-"), lines[prefixAt + 1])
    }

    func testAFailedInstallSaysWhatNpmSaid() async throws {
        let (npm, _) = try fakeNpm(failWith: "E404 not found")
        Adapters.npmForTests = npm.path

        do {
            try await Adapters.setUp(Adapters.codex)
            XCTFail("the install should have failed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("E404"), error.localizedDescription)
        }
    }

    /// npm that wrote the package but exited badly: not set up, and nothing
    /// half-installed left behind.
    func testAHalfFinishedInstallIsNotSetUp() async throws {
        let (npm, _) = try fakeNpm(installsThenFails: true)
        Adapters.npmForTests = npm.path
        let adapter = Adapters.claude
        let final = Adapters.folder(adapter)

        do {
            try await Adapters.setUp(adapter)
            XCTFail("the install should have failed")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertFalse(Adapters.isSetUp(adapter))
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
        let beside = try FileManager.default.contentsOfDirectory(at: final.deletingLastPathComponent(),
                                                                 includingPropertiesForKeys: nil)
        XCTAssertFalse(beside.contains { $0.lastPathComponent.hasPrefix(final.lastPathComponent + ".partial-") })
    }

    /// Two callers at once wait for one install: the fake npm runs once.
    func testTwoConcurrentSetUpsInstallOnce() async throws {
        let (npm, log) = try fakeNpm(delay: 1)
        Adapters.npmForTests = npm.path
        let adapter = Adapters.claude

        async let first: Void = Adapters.setUp(adapter)
        async let second: Void = Adapters.setUp(adapter)
        _ = try await (first, second)

        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.filter { $0 == "install" }.count, 1)
        XCTAssertTrue(Adapters.isSetUp(adapter))
    }

    // MARK: - the two as agents

    /// A PATH with a few fake programs on it, none of which run.
    private func fakePath(_ names: [String]) throws -> URL {
        let bin = folder.appendingPathComponent("bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in names {
            let script = bin.appendingPathComponent(name)
            try "#!/bin/sh\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        return bin
    }

    func testClaudeAndCodexAreFoundThroughTheirAdapters() async throws {
        let bin = try fakePath(["claude", "codex", "node", "opencode"])
        // The person's own Codex home, with a sign-in to link.
        let person = folder.appendingPathComponent("person-codex")
        try FileManager.default.createDirectory(at: person, withIntermediateDirectories: true)
        try "{}".write(to: person.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        Adapters.codexHomeForTests = person.path

        Agents.searchPathForTests = bin.path
        LoginShell.forget()
        Agents.shared.refresh()
        await until(10) { Agents.shared.looked }

        // Claude and Codex come before opencode, as the table says.
        let ids = Agents.shared.all.map(\.id).filter { !$0.hasPrefix("custom.") }
        XCTAssertEqual(ids, ["pi", "claude", "codex", "opencode"])

        let node = bin.appendingPathComponent("node").path
        let claude = try XCTUnwrap(Agents.shared.choice("claude"))
        XCTAssertEqual(claude.path, node)
        XCTAssertEqual(claude.spec?.path, node)
        XCTAssertEqual(claude.spec?.arguments, [Adapters.script(Adapters.claude).path])
        XCTAssertEqual(claude.adapter, Adapters.claude)
        XCTAssertEqual(claude.cliPath, bin.appendingPathComponent("claude").path)
        XCTAssertEqual(claude.spec?.structuralTools, .claude)
        XCTAssertEqual(claude.spec?.unsetEnvironment, ["CLAUDE_CODE_EXECUTABLE"])
        let options = (claude.spec?.sessionMeta?["claudeCode"] as? [String: Any])?["options"] as? [String: Any]
        XCTAssertEqual(options?["tools"] as? [String], [])
        XCTAssertEqual(options?["strictMcpConfig"] as? Bool, true)

        let codex = try XCTUnwrap(Agents.shared.choice("codex"))
        XCTAssertEqual(codex.path, node)
        XCTAssertEqual(codex.spec?.arguments, [Adapters.script(Adapters.codex).path])
        XCTAssertEqual(codex.adapter, Adapters.codex)
        XCTAssertEqual(codex.ownTools, .refused)
        XCTAssertEqual(codex.cliPath, bin.appendingPathComponent("codex").path)
        XCTAssertEqual(codex.spec?.structuralTools, .codex)
        XCTAssertEqual(codex.spec?.unsetEnvironment, ["CODEX_PATH"])
        // Search's own config for it; the home is prepared fresh at each start.
        XCTAssertEqual(codex.spec?.environment["CODEX_CONFIG"], "{}")
        XCTAssertNil(codex.spec?.environment["CODEX_HOME"])

        // That start-time home: config.toml and the person's sign-in linked.
        let environment = try Adapters.codexEnvironment()
        let home = try XCTUnwrap(environment["CODEX_HOME"])
        let config = try String(contentsOf: URL(fileURLWithPath: home).appendingPathComponent("config.toml"),
                                encoding: .utf8)
        XCTAssertTrue(config.contains("sandbox_mode = \"read-only\""), config)
        XCTAssertTrue(config.contains("approval_policy = \"on-request\""), config)
        XCTAssertTrue(config.contains("[features]"), config)
        XCTAssertTrue(config.contains("shell_tool = false"), config)
        XCTAssertTrue(config.contains("goals = false"), config)
        // Code mode stays on: its models reach Search's tools through it.
        XCTAssertFalse(config.contains("code_mode_host"), config)
        let link = URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        XCTAssertEqual(URL(fileURLWithPath: target).resolvingSymlinksInPath().path,
                       person.appendingPathComponent("auth.json").resolvingSymlinksInPath().path)
    }

    /// A terminal sign-in runs the agent's own CLI, not the adapter's node.
    func testTerminalSignInRunsTheCLI() async throws {
        let bin = try fakePath(["claude", "codex", "node"])
        Agents.searchPathForTests = bin.path
        LoginShell.forget()
        Agents.shared.refresh()
        await until(10) { Agents.shared.looked }

        let claude = try XCTUnwrap(Agents.shared.choice("claude"))
        XCTAssertEqual(Agents.loginCommand(claude), [bin.appendingPathComponent("claude").path])
        let codex = try XCTUnwrap(Agents.shared.choice("codex"))
        XCTAssertEqual(Agents.loginCommand(codex),
                       [bin.appendingPathComponent("codex").path, "login"])
    }

    /// An inherited CODEX_PATH could run another binary and an inherited
    /// CODEX_CONFIG re-enable its tools: the child's environment loses the
    /// first and gets Search's own for the second.
    func testCodexChildEnvironmentUnsetsInheritedTools() async throws {
        LoginShell.environmentForTests = [
            "PATH": "/usr/bin:/bin",
            "CODEX_CONFIG": #"{"features":{"shell_tool":true}}"#,
            "CODEX_PATH": "/somewhere/else/codex",
        ]
        defer { LoginShell.environmentForTests = nil }
        let bin = try fakePath(["codex", "node"])
        Agents.searchPathForTests = bin.path
        LoginShell.forget()
        Agents.shared.refresh()
        await until(10) { Agents.shared.looked }

        let codex = try XCTUnwrap(Agents.shared.choice("codex"))
        let environment = try XCTUnwrap(codex.spec).childEnvironment()
        XCTAssertEqual(environment["CODEX_CONFIG"], "{}")
        XCTAssertNil(environment["CODEX_PATH"])
    }

    /// A home that can't be made stops the start, saying so.
    func testACodexHomeThatCannotBeMadeStopsTheStart() async throws {
        let bin = try fakePath(["codex", "node"])
        Agents.searchPathForTests = bin.path
        LoginShell.forget()
        Agents.shared.refresh()
        await until(10) { Agents.shared.looked }
        // Install the adapter, so it is the home, not the set-up card, that
        // stops the start.
        let (npm, _) = try fakeNpm()
        Adapters.npmForTests = npm.path
        try await Adapters.setUp(Adapters.codex)

        // A file where the home should be: it can't be created.
        let home = Adapters.codexHome()
        try? FileManager.default.removeItem(at: home)
        try FileManager.default.createDirectory(at: home.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not a folder".write(to: home, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: home) }

        let agent = Agents.shared.chatAgent("codex")
        do {
            let link = try await agent.start(UUID(), nil) { _ in }
            link.stop()
            XCTFail("the start should have failed")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("Search couldn't prepare Codex's settings:"),
                          error.localizedDescription)
        }
    }

    /// The auth link is reconciled each time the home is prepared: the
    /// person's file comes first, and Search's is always a link to it.
    func testCodexAuthLinkIsReconciled() throws {
        let manager = FileManager.default
        let home = Adapters.codexHome()
        let person = folder.appendingPathComponent("person-codex-\(UUID().uuidString)")
        Adapters.codexHomeForTests = person.path
        defer {
            Adapters.codexHomeForTests = nil
            try? manager.removeItem(at: person)
        }
        try manager.createDirectory(at: person, withIntermediateDirectories: true)
        let theirs = person.appendingPathComponent("auth.json")
        let ours = home.appendingPathComponent("auth.json")

        // Nothing: a link to the person's, before theirs exists too.
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        try Adapters.linkCodexAuth()
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: ours.path), theirs.path)

        // A link to the right file is kept.
        let before = try manager.destinationOfSymbolicLink(atPath: ours.path)
        try Adapters.linkCodexAuth()
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: ours.path), before)

        // A link elsewhere is replaced.
        let elsewhere = folder.appendingPathComponent("elsewhere-\(UUID().uuidString)")
        try "{}".write(to: elsewhere, atomically: true, encoding: .utf8)
        try manager.removeItem(at: ours)
        try manager.createSymbolicLink(at: ours, withDestinationURL: elsewhere)
        try Adapters.linkCodexAuth()
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: ours.path), theirs.path)

        // A regular file, the person's absent: it becomes theirs, then a link.
        try manager.removeItem(at: ours)
        try "mine".write(to: ours, atomically: true, encoding: .utf8)
        try? manager.removeItem(at: theirs)
        try Adapters.linkCodexAuth()
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: ours.path), theirs.path)
        XCTAssertEqual(try String(contentsOf: theirs, encoding: .utf8), "mine")

        // A regular file, the person's present: theirs is kept, ours goes.
        try manager.removeItem(at: ours)
        try "mine".write(to: ours, atomically: true, encoding: .utf8)
        try "theirs".write(to: theirs, atomically: true, encoding: .utf8)
        try Adapters.linkCodexAuth()
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: ours.path), theirs.path)
        XCTAssertEqual(try String(contentsOf: theirs, encoding: .utf8), "theirs")

        // A dangling link elsewhere is replaced too.
        try manager.removeItem(at: ours)
        try manager.createSymbolicLink(at: ours, withDestinationURL: folder.appendingPathComponent("gone"))
        try Adapters.linkCodexAuth()
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: ours.path), theirs.path)
    }

    // MARK: - a chat on one

    func testAChatOnClaudeAsksForSetUp() async throws {
        let bin = try fakePath(["claude", "node"])
        Agents.searchPathForTests = bin.path
        LoginShell.forget()
        Agents.shared.refresh()
        await until(10) { Agents.shared.looked }

        let chat = Chat(title: "Test", agentID: "claude", agentName: "Claude Code")
        chats.append(chat)
        chat.send("hello")
        await until(10) { chat.setUp != nil || chat.items.contains { $0.kind == .error } }

        XCTAssertNotNil(chat.setUp)
        XCTAssertEqual(chat.setUp?.agent, "Claude Code")
        XCTAssertEqual(chat.setUp?.adapter, Adapters.claude)
        XCTAssertFalse(chat.items.contains { $0.kind == .error })
    }

    /// A chat switched to Claude Code before any message: the menu's first
    /// start shows the adapter card, and once Set Up installs it the agent
    /// starts.
    func testAChosenAgentAsksForItsAdapterBeforeAnyMessage() async throws {
        let (_, log) = try await scriptedClaude()
        let (npm, _) = try fakeNpm()
        Adapters.npmForTests = npm.path

        let chat = Chat(title: "Test")
        chats.append(chat)
        XCTAssertTrue(chat.use("claude"))
        chat.loadOptions()
        await until(10) { chat.setUp != nil || chat.items.contains { $0.kind == .error } }

        // The card, and nothing was sent to the agent.
        XCTAssertNotNil(chat.setUp)
        XCTAssertEqual(chat.setUp?.adapter, Adapters.claude)
        XCTAssertFalse(chat.items.contains { $0.kind == .error })
        XCTAssertTrue(chat.items.isEmpty)
        XCTAssertNil(chat.session)
        XCTAssertFalse(logged(log).contains { $0["method"] as? String == "initialize" })

        chat.setUpAdapter()
        await until(20) { chat.session != nil || chat.items.contains { $0.kind == .error } }

        XCTAssertTrue(Adapters.isSetUp(Adapters.claude))
        XCTAssertNil(chat.setUp)
        XCTAssertEqual(chat.session, "s-1")
        XCTAssertFalse(chat.items.contains { $0.kind == .error })
        XCTAssertTrue(logged(log).contains { $0["method"] as? String == "initialize" })
    }

    /// A send already waiting keeps its message when the menu's quiet start
    /// finds the same card: after Set Up the message is what goes.
    func testAPendingSendWinsOverTheMenu() async throws {
        let (_, log) = try await scriptedClaude()
        let (npm, _) = try fakeNpm()
        Adapters.npmForTests = npm.path

        let chat = Chat(title: "Test", agentID: "claude", agentName: "Claude Code")
        chats.append(chat)
        chat.send("hello")
        chat.loadOptions()
        await until(10) { chat.setUp != nil || chat.items.contains { $0.kind == .error } }
        XCTAssertNotNil(chat.setUp)

        chat.setUpAdapter()
        await until(20) { logged(log).contains { $0["method"] as? String == "session/prompt" }
            || chat.items.contains { $0.kind == .error } }

        let prompt = logged(log).first { $0["method"] as? String == "session/prompt" }
        let blocks = (prompt?["params"] as? [String: Any])?["prompt"] as? [[String: Any]]
        XCTAssertEqual(blocks?.first?["text"] as? String, "hello")
    }

    /// An install that finishes after its chat was deleted retries into
    /// nothing: no agent is started.
    func testSetUpDoesNotRetryADeletedChat() async throws {
        let (_, log) = try await scriptedClaude()
        let (npm, _) = try fakeNpm(delay: 1)
        Adapters.npmForTests = npm.path

        let chat = Chat(title: "Test", agentID: "claude", agentName: "Claude Code")
        chats.append(chat)
        chat.loadOptions()
        await until(10) { chat.setUp != nil || chat.items.contains { $0.kind == .error } }
        XCTAssertNotNil(chat.setUp)

        chat.setUpAdapter()
        try await Task.sleep(for: .milliseconds(150))
        Chats.delete(chat)
        chats.removeAll { $0 === chat }

        await until(10) { Adapters.isSetUp(Adapters.claude) }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(logged(log).contains { $0["method"] as? String == "initialize" })
    }

    // MARK: - helpers for the scripted agent

    /// A PATH whose claude exists and whose node runs the scripted ACP agent,
    /// with nothing of Claude's adapter set up. The caller installs a fake npm.
    @discardableResult
    private func scriptedClaude(_ scenario: [String: Any] = [:]) async throws -> (bin: URL, log: URL) {
        guard pythonIsThere() else { throw XCTSkip("python3 isn't installed") }
        let bin = folder.appendingPathComponent("bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let scenarioFile = folder.appendingPathComponent("scenario-\(UUID().uuidString).json")
        let log = folder.appendingPathComponent("log-\(UUID().uuidString).jsonl")
        try JSONSerialization.data(withJSONObject: scenario).write(to: scenarioFile)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        try writeExecutable(bin.appendingPathComponent("claude"), "#!/bin/sh\nexit 0\n")
        try writeExecutable(bin.appendingPathComponent("node"),
                            "#!/bin/sh\nexec /usr/bin/env python3 '\(Self.script.path)' '\(scenarioFile.path)' '\(log.path)'\n")
        Agents.searchPathForTests = bin.path
        LoginShell.forget()
        Agents.shared.refresh()
        await until(10) { Agents.shared.looked }
        try? FileManager.default.removeItem(at: Adapters.folder(Adapters.claude))
        return (bin, log)
    }

    /// The scripted ACP agent, found beside the test file wherever it is built.
    private static var script: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/scripted-acp-agent.py")
    }

    private func pythonIsThere() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "--version"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func writeExecutable(_ url: URL, _ body: String) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// The log's lines, parsed. A half-written last line is let go.
    private func logged(_ log: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }
}
