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
    /// the script inside the folder it was told to install into. It is a
    /// /bin/sh script, so no npm or node is needed to test setUp.
    private func fakeNpm(failWith error: String? = nil) throws -> (script: URL, args: URL) {
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
            body = """
            #!/bin/sh
            printf '%s\\n' "$@" > '\(args.path)'
            prefix=""
            last=""
            prev=""
            for arg in "$@"; do
              if [ "$prev" = "--prefix" ]; then prefix="$arg"; fi
              prev="$arg"
              last="$arg"
            done
            package="${last%@*}"
            mkdir -p "$prefix/node_modules/$package/dist"
            : > "$prefix/node_modules/$package/dist/index.js"
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

        // Exactly the pinned version, with --ignore-scripts and its own folder.
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "install")
        XCTAssertTrue(lines.contains("\(adapter.package)@\(adapter.version)"))
        XCTAssertTrue(lines.contains("--ignore-scripts"))
        let prefixAt = try XCTUnwrap(lines.firstIndex(of: "--prefix"))
        XCTAssertEqual(lines[prefixAt + 1], expected.path)
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
        let options = (claude.spec?.sessionMeta?["claudeCode"] as? [String: Any])?["options"] as? [String: Any]
        XCTAssertEqual(options?["tools"] as? [String], [])
        XCTAssertEqual(options?["strictMcpConfig"] as? Bool, true)

        let codex = try XCTUnwrap(Agents.shared.choice("codex"))
        XCTAssertEqual(codex.path, node)
        XCTAssertEqual(codex.spec?.arguments, [Adapters.script(Adapters.codex).path])
        XCTAssertEqual(codex.adapter, Adapters.codex)
        XCTAssertEqual(codex.ownTools, .refused)
        let environment = codex.spec?.environment ?? [:]
        // Codex reads these from its own config.toml, not the environment.
        XCTAssertNil(environment["CODEX_CONFIG"])
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
        // Search's own home, with the person's sign-in linked, not copied.
        let link = URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        XCTAssertEqual(URL(fileURLWithPath: target).resolvingSymlinksInPath().path,
                       person.appendingPathComponent("auth.json").resolvingSymlinksInPath().path)
    }

    func testAChatOnClaudeAsksForSetUp() async throws {
        let bin = try fakePath(["claude", "node"])
        Agents.searchPathForTests = bin.path
        LoginShell.forget()
        Agents.shared.refresh()
        await until(10) { Agents.shared.looked }
        // Another test may have installed it: the card only comes when it isn't.
        try? FileManager.default.removeItem(at: Adapters.folder(Adapters.claude))

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
    /// start shows the adapter card, not a quiet failure, and once Set Up
    /// installs the adapter the agent starts.
    func testAChosenAgentAsksForItsAdapterBeforeAnyMessage() async throws {
        guard pythonIsThere() else { throw XCTSkip("python3 isn't installed") }
        // A PATH whose node runs the scripted ACP agent, so a start after set
        // up reaches a real agent; Claude itself only has to be there.
        let bin = folder.appendingPathComponent("bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let scenario = folder.appendingPathComponent("scenario-\(UUID().uuidString).json")
        let log = folder.appendingPathComponent("log-\(UUID().uuidString).jsonl")
        try JSONSerialization.data(withJSONObject: [String: Any]()).write(to: scenario)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        try writeExecutable(bin.appendingPathComponent("claude"), "#!/bin/sh\nexit 0\n")
        try writeExecutable(bin.appendingPathComponent("node"),
                            "#!/bin/sh\nexec /usr/bin/env python3 '\(Self.script.path)' '\(scenario.path)' '\(log.path)'\n")
        Agents.searchPathForTests = bin.path
        LoginShell.forget()
        Agents.shared.refresh()
        await until(10) { Agents.shared.looked }

        // The adapter isn't set up: a fake npm will install it.
        try? FileManager.default.removeItem(at: Adapters.folder(Adapters.claude))
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

    // MARK: - helpers for the scripted agent

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
