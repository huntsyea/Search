import AppKit
import Foundation
import XCTest
@testable import Search

/// Signing in to an ACP agent: session/new's auth_required, the methods the
/// agent lists, the card the chat shows, the method remembered for its next
/// chat, and a saved chat's agent found again after the first look
/// (ACP.swift, Agents.swift, Chats.swift) — docs/design/agents.md.
@MainActor
final class SignInTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private var folder: URL!
    private var chats: [Chat] = []
    private var browsers: [Browser] = []
    private var added: [String] = []

    /// The script, found beside the test file, wherever it is built.
    private static var script: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/scripted-acp-agent.py")
    }

    override func setUp() async throws {
        try await super.setUp()
        guard pythonIsThere() else { throw XCTSkip("python3 isn't installed") }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("signin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Nothing of the person's own agents on the PATH, so only the ones a
        // test adds are found.
        let empty = folder.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        Agents.searchPathForTests = empty.path
        LoginShell.forget()
        Agents.shared.refresh()
        await until(10) { Agents.shared.looked }
    }

    override func tearDown() async throws {
        for chat in chats { Chats.delete(chat) }
        chats = []
        for id in added { Agents.shared.remove(id) }
        added = []
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

    /// The log's lines, parsed. A half-written last line is let go.
    private func logged(_ log: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    private struct Made {
        let chat: Chat
        let browser: Browser
        let log: URL
        let agent: AgentChoice
    }

    /// A custom agent whose command is the scripted ACP agent, and a chat on
    /// it: the whole way through Agents, not around it.
    private func made(_ scenario: [String: Any]) throws -> Made {
        let scenarioFile = folder.appendingPathComponent("scenario-\(UUID().uuidString).json")
        let log = folder.appendingPathComponent("log-\(UUID().uuidString).jsonl")
        try JSONSerialization.data(withJSONObject: scenario).write(to: scenarioFile)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let command = "/usr/bin/env python3 '\(Self.script.path)' '\(scenarioFile.path)' '\(log.path)'"
        guard case let .success(agent) = Agents.shared.add(name: "scripted", command: command) else {
            throw XCTSkip("the scripted agent couldn't be added")
        }
        added.append(agent.id)
        let made = chat(on: agent)
        return Made(chat: made.chat, browser: made.browser, log: log, agent: agent)
    }

    /// A chat on an agent already added.
    private func chat(on agent: AgentChoice) -> (chat: Chat, browser: Browser) {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        let chat = Chat(title: "Test", agentID: agent.id, agentName: agent.name)
        chats.append(chat)
        chat.browser = browser
        return (chat, browser)
    }

    // MARK: - the race at startup

    func testAnAgentBeforeTheFirstLookIsFound() async throws {
        // "opencode" on the PATH is the scripted agent, ignoring its "acp"
        // argument: a chat made before the look has finished still reaches it.
        let known = folder.appendingPathComponent("known")
        try FileManager.default.createDirectory(at: known, withIntermediateDirectories: true)
        let scenario = folder.appendingPathComponent("known-scenario.json")
        let log = folder.appendingPathComponent("known-log.jsonl")
        try JSONSerialization.data(withJSONObject: [String: Any]()).write(to: scenario)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let program = known.appendingPathComponent("opencode")
        try """
        #!/bin/sh
        exec /usr/bin/env python3 '\(Self.script.path)' '\(scenario.path)' '\(log.path)'
        """.write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        Agents.searchPathForTests = known.path

        let fresh = Agents()
        XCTAssertFalse(fresh.looked)
        let agent = fresh.chatAgent("opencode")
        let link = try await agent.start(UUID(), nil) { _ in }
        link.stop()
    }

    // MARK: - sign-in

    private static let methods: [String: Any] = ["id": "m1", "name": "Sign in"]
    private var scenario: [String: Any] { ["auth": ["methods": [Self.methods], "accept": "m1"]] }

    func testSignInIsAsked() async throws {
        let made = try made(scenario)
        made.chat.send("hello")
        await until(10) { made.chat.signIn != nil || made.chat.items.contains { $0.kind == .error } }

        XCTAssertEqual(made.chat.signIn?.agent, made.agent.name)
        XCTAssertEqual(made.chat.signIn?.methods.map(\.id), ["m1"])
        XCTAssertFalse(made.chat.busy)
        XCTAssertFalse(made.chat.items.contains { $0.kind == .error })
        XCTAssertEqual(Agents.shared.state(made.agent.id), .signIn)
    }

    func testSigningInSendsTheMessage() async throws {
        let made = try made(scenario)
        made.chat.send("hello")
        await until(10) { made.chat.signIn != nil }

        made.chat.signIn(with: "m1")
        await until(10) { made.chat.session != nil || made.chat.items.contains { $0.kind == .error } }
        // The session is set by session/new, which comes before the prompt is
        // sent: wait for the prompt itself before reading the log.
        await until(10) { logged(made.log).contains { $0["method"] as? String == "session/prompt" } }
        XCTAssertNil(made.chat.signIn)
        XCTAssertEqual(made.chat.session, "s-1")
        XCTAssertEqual(Agents.shared.state(made.agent.id), .ready)

        let received = logged(made.log)
        let authenticate = received.first { $0["method"] as? String == "authenticate" }
        XCTAssertEqual((authenticate?["params"] as? [String: Any])?["methodId"] as? String, "m1")
        let authAt = received.firstIndex { $0["method"] as? String == "authenticate" }
        // The first session/new asked for the sign-in; the one after
        // authenticate is the one that opened.
        let newAt = received.lastIndex { $0["method"] as? String == "session/new" }
        XCTAssertNotNil(authAt)
        XCTAssertNotNil(newAt)
        if let authAt, let newAt { XCTAssertLessThan(authAt, newAt) }

        let prompt = received.first { $0["method"] as? String == "session/prompt" }
        let blocks = (prompt?["params"] as? [String: Any])?["prompt"] as? [[String: Any]]
        XCTAssertEqual(blocks?.first?["text"] as? String, "hello")
    }

    func testTheMethodIsRememberedForTheNextChat() async throws {
        let first = try made(scenario)
        first.chat.send("hello")
        await until(10) { first.chat.signIn != nil }
        first.chat.signIn(with: "m1")
        await until(10) { first.chat.session != nil }

        let before = logged(first.log).count
        let second = chat(on: first.agent)
        second.chat.send("hello")
        await until(10) { second.chat.session != nil || second.chat.signIn != nil }
        XCTAssertNil(second.chat.signIn)
        XCTAssertEqual(second.chat.session, "s-1")
        XCTAssertFalse(second.chat.items.contains { $0.kind == .error })

        // Its start signed in again without a card.
        let fresh = Array(logged(first.log).dropFirst(before))
        XCTAssertTrue(fresh.contains { $0["method"] as? String == "authenticate" })
    }

    func testTerminalMethods() async throws {
        let made = try made(["auth": ["methods": [
            ["id": "t1", "name": "Sign in in a terminal", "type": "terminal", "args": ["login"]],
        ], "accept": "t1"]])
        made.chat.send("hello")
        await until(10) { made.chat.signIn != nil }

        let method = made.chat.signIn?.methods.first { $0.id == "t1" }
        XCTAssertEqual(method?.name, "Sign in in a terminal")
        // The agent's own program and arguments, plus the method's args.
        XCTAssertEqual(method?.terminal?.first, "/usr/bin/env")
        XCTAssertEqual(method?.terminal?.last, "login")
    }

    func testAModelIsRememberedForTheNextChat() async throws {
        let models: [[String: Any]] = [["value": "a", "name": "A"], ["value": "b", "name": "B"]]
        let option: [String: Any] = ["id": "model", "name": "Model", "category": "model",
                                     "currentValue": "a", "options": models]
        let chosen = option.merging(["currentValue": "b"]) { _, new in new }
        let scenario: [String: Any] = [
            "new": ["sessionId": "s-1", "configOptions": [option]],
            "setConfig": ["configOptions": [chosen]],
        ]
        let first = try made(scenario)
        first.chat.loadOptions()
        await until(10) { first.chat.option(.model)?.choices.count == 2 }
        first.chat.choose(first.chat.option(.model)?.id ?? "model", "b")
        await until(10) { first.chat.option(.model)?.current == "b" }
        XCTAssertEqual(Agents.model(for: first.agent.id), "b")

        // A new chat on the same agent starts on the model the last one used,
        // set inside the start, before the first message is sent.
        let before = logged(first.log).count
        let second = chat(on: first.agent)
        second.chat.send("hello")
        await until(10) { logged(first.log).dropFirst(before).contains { $0["method"] as? String == "session/prompt" } }

        let fresh = Array(logged(first.log).dropFirst(before))
        let setAt = fresh.firstIndex { message in
            guard message["method"] as? String == "session/set_config_option" else { return false }
            return ((message["params"] as? [String: Any])?["value"] as? String) == "b"
        }
        let promptAt = fresh.firstIndex { $0["method"] as? String == "session/prompt" }
        XCTAssertNotNil(setAt)
        XCTAssertNotNil(promptAt)
        if let setAt, let promptAt { XCTAssertLessThan(setAt, promptAt) }
    }

    // MARK: - switching agents

    func testAStartForTheMenuIsNotBegun() async throws {
        let option: [String: Any] = ["id": "model", "name": "Model", "category": "model", "currentValue": "a",
                                     "options": [["value": "a", "name": "A"]]]
        let made = try made(["new": ["sessionId": "s-1", "configOptions": [option]]])
        made.chat.loadOptions()
        // The agent opened a session only to fill the menu.
        await until(10) { made.chat.option(.model) != nil && made.chat.session != nil }

        // Nothing was sent: not begun, not listed, and its agent can change.
        XCTAssertFalse(made.chat.begun)
        XCTAssertFalse(Chats.all.contains { $0 === made.chat })
        XCTAssertTrue(made.chat.use("pi"))
        XCTAssertNil(made.chat.session)
    }

    func testAMessageListsTheChat() async throws {
        let made = try made(["new": ["sessionId": "s-1"]])
        made.chat.loadOptions()
        await until(10) { made.chat.session != nil }
        XCTAssertFalse(Chats.all.contains { $0 === made.chat })

        made.chat.send("hello")
        await until(10) { Chats.all.contains { $0 === made.chat } }
    }

    func testSwitchingWhileTheOldStartIsInFlightStartsTheNewOne() async throws {
        let made = try made([:])
        let gate = Gate()
        defer { gate.open() }
        let old = ChatAgent(name: "pi", start: { _, _, _ in
            await gate.wait()
            throw ChildProcess.Failure(why: "the old agent let go")
        }, title: { _, _ in nil })
        let chat = Chat(title: "Test", agentID: "pi", agent: old)
        chats.append(chat)

        // A start for the menu is still in flight when the agent changes.
        chat.loadOptions()
        await until(5) { gate.waiting == 1 }
        XCTAssertFalse(chat.begun)
        XCTAssertTrue(chat.use(made.agent.id))
        chat.loadOptions()

        // The new agent starts, whatever the old start is still doing.
        await until(10) { logged(made.log).contains { $0["method"] as? String == "initialize" } }
    }

    /// A remembered method the agent rejects is shown as a card again, and
    /// forgotten so it can't trap the next start too.
    func testARejectedSignInMethodIsForgotten() async throws {
        let made = try made(["auth": ["methods": [["id": "m1", "name": "One"], ["id": "m2", "name": "Two"]],
                                       "accept": "m2"]])
        Agents.shared.remember(signIn: "m1", for: made.agent.id)
        made.chat.send("hello")
        await until(10) { made.chat.signIn != nil }

        XCTAssertEqual(made.chat.signIn?.methods.map(\.id), ["m1", "m2"])
        XCTAssertNil(Agents.signIn(for: made.agent.id))
        XCTAssertFalse(made.chat.items.contains { $0.kind == .error })
    }

    /// While the card is up, sending isn't allowed: the message kept for Try
    /// Again is the one that goes, and only once the agent takes it.
    func testAMessageWaitingOnSignInIsKept() async throws {
        let made = try made(scenario)
        made.chat.send("hello")
        await until(10) { made.chat.signIn != nil }
        XCTAssertTrue(made.chat.hasUnsent)

        XCTAssertFalse(made.chat.send("something else"))
        XCTAssertTrue(made.chat.hasUnsent)

        made.chat.signIn(with: "m1")
        await until(10) { logged(made.log).contains { $0["method"] as? String == "session/prompt" } }
        XCTAssertFalse(made.chat.hasUnsent)
        let prompt = logged(made.log).first { $0["method"] as? String == "session/prompt" }
        let blocks = (prompt?["params"] as? [String: Any])?["prompt"] as? [[String: Any]]
        XCTAssertEqual(blocks?.first?["text"] as? String, "hello")
    }

    /// Opening saved history is what the sign-in interrupted: Try Again does
    /// the open again, and the history loads.
    func testSignInFromOpeningSavedHistoryRetries() async throws {
        let made = try made([
            "auth": ["methods": [Self.methods], "accept": "m1"],
            "load": ["updates": [
                ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Earlier"]],
            ]],
        ])
        let chat = Chat(title: "Test", session: "s-1", agentID: made.agent.id, agentName: made.agent.name)
        chats.append(chat)
        chat.browser = made.browser

        chat.open(in: made.browser)
        await until(10) { chat.signIn != nil }
        XCTAssertFalse(chat.items.contains { $0.kind == .error })

        chat.signIn(with: "m1")
        await until(10) { chat.items.contains { $0.text == "Earlier" } }
        XCTAssertFalse(chat.items.contains { $0.kind == .error })
    }

    /// A send the chat has moved on from mustn't clear a newer one's state.
    func testASupersededSendDoesNotClearTheNewOne() async throws {
        let script = ScriptedPi()
        let gate = Gate()
        defer { gate.open() }
        let starts = StartCount()
        let agent = ChatAgent(name: "pi", start: { chat, session, hear in
            starts.count += 1
            if starts.count == 1 {
                await gate.wait()
                throw ChildProcess.Failure(why: "the first start let go")
            }
            return try await ChatAgent.pi(script.pi).start(chat, session, hear)
        }, title: { _, _ in nil })
        let chat = Chat(title: "Test", agentID: "pi", agent: agent)
        chats.append(chat)

        chat.send("A")
        await until(5) { gate.waiting == 1 }
        chat.close()
        chat.send("B")
        await until(5) { script.sentTypes.contains("prompt") }
        XCTAssertTrue(chat.busy)

        // A's start fails now; B stays busy and gets no error from it.
        gate.open()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(chat.busy)
        XCTAssertFalse(chat.items.contains { $0.kind == .error })

        script.emit(["type": "agent_settled"])
        await until(5) { !chat.busy }
    }
}

/// A start that waits until the test lets it go.
@MainActor
private final class Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { waiters.count }
    func wait() async { await withCheckedContinuation { waiters.append($0) } }
    func open() { let waiting = waiters; waiters = []; waiting.forEach { $0.resume() } }
}

/// How many times a start closure has been called.
private final class StartCount {
    var count = 0
}
