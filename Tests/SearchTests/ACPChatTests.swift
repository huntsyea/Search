import AppKit
import Foundation
import XCTest
@testable import Search

/// A chat on the scripted ACP agent (Tests/fixtures/scripted-acp-agent.py):
/// the adapter's translation of ACP into what a chat hears, its tool calls
/// over MCP, its options and its Stop (docs/design/agents.md).
@MainActor
final class ACPChatTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("acp-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard pythonIsThere() else { throw XCTSkip("python3 isn't installed") }
        guard let binary = searchBinary() else { throw XCTSkip("the Search binary isn't built") }
        MCPDoor.executableOverride = binary
    }

    override func tearDown() async throws {
        for chat in chats { Chats.delete(chat) }
        chats = []
        MCPDoor.executableOverride = nil
        try? FileManager.default.removeItem(at: folder)
        try await super.tearDown()
    }

    private var folder: URL!
    private var chats: [Chat] = []
    /// Held so the chats' weak browsers stay alive.
    private var browsers: [Browser] = []

    /// The script, found beside the test file, wherever it is built.
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

    /// Where the built Search binary is, next to the test bundle; nil when it
    /// isn't there (the class skips).
    private func searchBinary() -> String? {
        let binary = Bundle(for: ACPChatTests.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("Search").path
        return FileManager.default.isExecutableFile(atPath: binary) ? binary : nil
    }

    private struct Made {
        let chat: Chat
        let browser: Browser
        let log: URL
    }

    /// A chat on the scripted agent, with a browser for its tools.
    private func made(_ scenario: [String: Any], session: String? = nil, mode: Chat.Mode = .ask,
                      browser given: Browser? = nil, startOptions: [String: String] = [:]) throws -> Made {
        let scenarioFile = folder.appendingPathComponent("scenario-\(UUID().uuidString).json")
        let log = folder.appendingPathComponent("log-\(UUID().uuidString).jsonl")
        try JSONSerialization.data(withJSONObject: scenario).write(to: scenarioFile)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        _ = NSApplication.shared
        let browser = given ?? Browser(record: WindowRecord())
        if given == nil { browsers.append(browser) }
        let chat = Chat(title: "Test", session: session, mode: mode,
                        agent: .acp(ACPSpec(id: "scripted", name: "scripted", path: "/usr/bin/env",
                                            arguments: ["python3", Self.script.path, scenarioFile.path, log.path],
                                            startOptions: startOptions)))
        chats.append(chat)
        chat.browser = browser
        return Made(chat: chat, browser: browser, log: log)
    }

    /// The step lines kept for a chat's session.
    private func steps(_ session: String) -> [String: String] {
        guard let data = try? Data(contentsOf: Chats.stepsFile(session)),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    /// The log's lines, parsed. A half-written last line is let go.
    private func logged(_ log: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    /// What the catalogue answers for a tool, as the chat shows it: the
    /// summary the adapter takes, read from a run of the tool itself.
    private func summary(_ tool: String, for chat: Chat) async -> String? {
        var found: String?
        AgentTools.run(["name": tool, "args": [:]], for: chat) { reply in
            found = (reply["details"] as? [String: Any])?["summary"] as? String
        }
        await until { found != nil }
        return found
    }

    // MARK: - answers

    func testAnAnswerStreamsAndSettles() async throws {
        let made = try made([
            "prompts": [[
                ["update": ["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "Thinking"]]],
                ["update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Hel"]]],
                ["update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "lo"]]],
            ]],
        ])
        made.chat.send("hi")
        await until { !made.chat.busy }

        XCTAssertEqual(made.chat.items.map(\.kind), [.user, .thinking, .assistant])
        XCTAssertEqual(made.chat.items[0].text, "hi")
        XCTAssertEqual(made.chat.items[1].text, "Thinking")
        XCTAssertEqual(made.chat.items[2].text, "Hello")
        XCTAssertTrue(made.chat.items.allSatisfy(\.done))
        XCTAssertEqual(made.chat.session, "s-1")
    }

    // MARK: - the browser's tools

    func testABrowserToolRunsThroughMCPAndShowsItsSummary() async throws {
        let made = try made([
            "prompts": [[
                ["update": ["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "mcp__search__browser_tabs",
                            "status": "pending", "rawInput": [:]]],
                ["mcp": ["name": "browser_tabs", "arguments": [:]]],
                ["update": ["sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed",
                            "content": [["type": "content", "content": ["type": "text", "text": "the tabs"]]]]],
                ["update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Done"]]],
            ]],
        ])
        made.chat.send("hi")
        await until { !made.chat.busy }

        let expected = await summary("browser_tabs", for: made.chat)
        let tool = made.chat.items.first { $0.kind == .tool }
        XCTAssertNotNil(tool)
        XCTAssertEqual(tool?.text, expected)
        XCTAssertTrue(tool?.done ?? false)
        XCTAssertFalse(tool?.failed ?? true)

        await until { self.logged(made.log).contains { $0["mcpResult"] != nil } }
        let result = logged(made.log).first { $0["mcpResult"] != nil }?["mcpResult"] as? [String: Any]
        XCTAssertNotNil(result?["content"])
    }

    func testItsOwnToolsAreRefused() async throws {
        let made = try made([
            "prompts": [[
                ["update": ["sessionUpdate": "tool_call", "toolCallId": "t2", "title": "Run shell",
                            "kind": "execute", "status": "pending"]],
                ["ask": ["toolCall": ["toolCallId": "t2", "title": "Run shell"],
                         "options": [["optionId": "a", "name": "Allow", "kind": "allow_once"],
                                     ["optionId": "r", "name": "Reject", "kind": "reject_once"]]]],
                ["request": ["method": "fs/read_text_file", "params": ["path": "/etc/hosts"]]],
                ["update": ["sessionUpdate": "tool_call_update", "toolCallId": "t2", "status": "failed"]],
            ]],
        ])
        made.chat.send("hi")
        await until { !made.chat.busy }

        let received = logged(made.log)
        let permission = received.first { ($0["result"] as? [String: Any])?["outcome"] != nil }
        let outcome = (permission?["result"] as? [String: Any])?["outcome"] as? [String: Any]
        XCTAssertEqual(outcome?["optionId"] as? String, "r")
        XCTAssertNotNil(received.first { ($0["error"] as? [String: Any])?["code"] as? Int == -32601 })

        let tool = made.chat.items.first { $0.id == "tool-t2" }
        XCTAssertTrue(tool?.failed ?? false)
        XCTAssertEqual(tool?.detail, "Search gives scripted only the browser's tools.")
    }

    func testABrowserToolAskIsAllowedForTheCatalogueToAsk() async throws {
        let made = try made([
            "prompts": [[
                ["ask": ["toolCall": ["title": "mcp__search__browser_click"],
                         "options": [["optionId": "a", "name": "Allow", "kind": "allow_once"],
                                     ["optionId": "r", "name": "Reject", "kind": "reject_once"]]]],
            ]],
        ])
        made.chat.send("hi")
        await until { !made.chat.busy }

        let permission = logged(made.log).first { ($0["result"] as? [String: Any])?["outcome"] != nil }
        let outcome = (permission?["result"] as? [String: Any])?["outcome"] as? [String: Any]
        XCTAssertEqual(outcome?["optionId"] as? String, "a")
    }

    // MARK: - stop and reopening

    func testStopCancels() async throws {
        let made = try made([
            "prompts": [[
                ["update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Working"]]],
                ["waitCancel": true],
                ["stop": "cancelled"],
            ]],
        ])
        made.chat.send("hi")
        await until { made.chat.items.contains { $0.text == "Working" } }
        made.chat.stop()
        await until { self.logged(made.log).contains { $0["method"] as? String == "session/cancel" } }
        await until { !made.chat.busy }

        XCTAssertEqual(made.chat.items.last?.kind, .note)
        XCTAssertEqual(made.chat.items.last?.text, "Stopped.")
    }

    func testAReopenedChatShowsItsHistory() async throws {
        let steps = Chats.folder.appendingPathComponent("Steps", isDirectory: true).appendingPathComponent("s-9.json")
        try FileManager.default.createDirectory(at: steps.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["t9": "Read the page"]).write(to: steps)
        defer { try? FileManager.default.removeItem(at: steps) }

        let made = try made([
            "load": ["updates": [
                ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "earlier question"]],
                ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "earlier answer"]],
                ["sessionUpdate": "tool_call", "toolCallId": "t9", "title": "mcp__search__browser_read",
                 "status": "completed", "rawInput": [:]],
            ]],
        ], session: "s-9")
        made.chat.open(in: made.browser)
        await until { !made.chat.items.isEmpty && !made.chat.busy && made.chat.status == nil }

        XCTAssertEqual(made.chat.items.map(\.kind), [.user, .assistant, .tool])
        XCTAssertEqual(made.chat.items[0].text, "earlier question")
        XCTAssertEqual(made.chat.items[1].text, "earlier answer")
        XCTAssertEqual(made.chat.items[2].text, "Read the page")

        let load = logged(made.log).first { $0["method"] as? String == "session/load" }
        let params = load?["params"] as? [String: Any]
        XCTAssertEqual(params?["sessionId"] as? String, "s-9")
        let servers = params?["mcpServers"] as? [[String: Any]]
        XCTAssertEqual(servers?.first?["command"] as? String, MCPDoor.executableOverride)
        XCTAssertEqual((servers?.first?["args"] as? [String])?.first, "--mcp")
    }

    // MARK: - options

    func testOptionsComeFromConfigOptions() async throws {
        let made = try made([
            "new": ["sessionId": "s-1", "configOptions": [
                ["id": "model", "name": "Model", "category": "model", "currentValue": "a",
                 "options": [["value": "a", "name": "A"], ["value": "b", "name": "B"]]],
                ["id": "mode", "name": "Mode", "category": "mode", "currentValue": "code",
                 "options": [["value": "code", "name": "Code"]]],
                ["id": "effort", "name": "Effort", "category": "thought_level", "currentValue": "low",
                 "options": [["value": "low", "name": "Low"], ["value": "high", "name": "High"]]],
            ]],
        ])
        made.chat.loadOptions()
        await until { made.chat.option(.model)?.current == "a" }

        XCTAssertEqual(made.chat.option(.model)?.choices.count, 2)
        XCTAssertEqual(made.chat.option(.thought)?.id, "effort")
        XCTAssertTrue(made.chat.options.allSatisfy { $0.id != "mode" })

        made.chat.choose("model", "b")
        await until { self.logged(made.log).contains { $0["method"] as? String == "session/set_config_option" } }
        let sent = logged(made.log).first { $0["method"] as? String == "session/set_config_option" }
        XCTAssertEqual((sent?["params"] as? [String: Any])?["configId"] as? String, "model")
        XCTAssertEqual((sent?["params"] as? [String: Any])?["value"] as? String, "b")
    }

    func testLegacyModels() async throws {
        let made = try made([
            "new": ["sessionId": "s-1", "models": [
                "availableModels": [["modelId": "m1", "name": "M1"], ["modelId": "m2", "name": "M2"]],
                "currentModelId": "m1",
            ]],
        ])
        made.chat.loadOptions()
        await until { made.chat.option(.model)?.current == "m1" }

        made.chat.choose("model", "m2")
        await until { self.logged(made.log).contains { $0["method"] as? String == "session/set_model" } }
        let sent = logged(made.log).first { $0["method"] as? String == "session/set_model" }
        XCTAssertEqual((sent?["params"] as? [String: Any])?["modelId"] as? String, "m2")
    }

    /// An agent that wants a config option set at every start (Codex's mode)
    /// gets it, before any prompt, when its session lists that option.
    func testStartOptionsAreSetBeforeTheFirstPrompt() async throws {
        let made = try made([
            "new": ["sessionId": "s-1", "configOptions": [
                ["id": "mode", "name": "Mode", "category": "mode", "currentValue": "code",
                 "options": [["value": "code", "name": "Code"], ["value": "read-only", "name": "Read-only"]]],
            ]],
        ], startOptions: ["mode": "read-only"])
        made.chat.send("hi")
        await until(10) { !made.chat.busy }

        let received = logged(made.log)
        let sent = received.first { $0["method"] as? String == "session/set_config_option" }
        XCTAssertEqual((sent?["params"] as? [String: Any])?["configId"] as? String, "mode")
        XCTAssertEqual((sent?["params"] as? [String: Any])?["value"] as? String, "read-only")
        let setAt = received.firstIndex { $0["method"] as? String == "session/set_config_option" }
        let promptAt = received.firstIndex { $0["method"] as? String == "session/prompt" }
        XCTAssertNotNil(setAt)
        XCTAssertNotNil(promptAt)
        if let setAt, let promptAt { XCTAssertLessThan(setAt, promptAt) }
    }

    /// One the session doesn't list is skipped, not sent and refused.
    func testAStartOptionTheSessionDoesNotListIsSkipped() async throws {
        let made = try made([
            "new": ["sessionId": "s-1", "configOptions": [
                ["id": "model", "name": "Model", "category": "model", "currentValue": "a",
                 "options": [["value": "a", "name": "A"]]],
            ]],
        ], startOptions: ["mode": "read-only"])
        made.chat.send("hi")
        await until(10) { !made.chat.busy }

        XCTAssertFalse(logged(made.log).contains { $0["method"] as? String == "session/set_config_option" })
    }

    // MARK: - failures

    func testSignInNeeded() async throws {
        let made = try made(["new": ["error": ["code": -32000, "message": "Authentication required"]]])
        made.chat.send("hi")
        await until { !made.chat.busy }

        // The agent asked for a sign-in: the card, not an error line.
        XCTAssertEqual(made.chat.signIn?.agent, "scripted")
        XCTAssertFalse(made.chat.items.contains { $0.kind == .error })
    }

    func testTheAgentEndingMidAnswer() async throws {
        let made = try made([
            "prompts": [[
                ["update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "par"]]],
                ["exit": 3],
            ]],
        ])
        made.chat.send("hi")
        await until { !made.chat.busy }

        XCTAssertEqual(made.chat.items.last?.kind, .error)
        XCTAssertEqual(made.chat.items.last?.text, "scripted stopped: scripted agent exiting")
    }

    // MARK: - what may be let through

    func testOnlyAnExactBrowserToolIsAllowed() async throws {
        let made = try made([
            "prompts": [
                [["ask": ["toolCall": ["title": "search_browser_tabs", "kind": "execute"],
                          "options": [["optionId": "a", "name": "Allow", "kind": "allow_once"],
                                      ["optionId": "r", "name": "Reject", "kind": "reject_once"]]]]],
                [["ask": ["toolCall": ["title": "cat browser_read.txt"],
                          "options": [["optionId": "a", "name": "Allow", "kind": "allow_once"],
                                      ["optionId": "r", "name": "Reject", "kind": "reject_once"]]]]],
                [["ask": ["toolCall": ["title": "search_browser_tabs", "kind": "other"],
                          "options": [["optionId": "k", "name": "Keep", "kind": "allow_always"],
                                      ["optionId": "r", "name": "Reject", "kind": "reject_once"]]]]],
                // Begun as a command; its request leaves the kind out.
                [["update": ["sessionUpdate": "tool_call", "toolCallId": "x1", "title": "search_browser_tabs",
                             "kind": "execute", "status": "pending"]],
                 ["ask": ["toolCall": ["toolCallId": "x1", "title": "search_browser_tabs"],
                          "options": [["optionId": "a", "name": "Allow", "kind": "allow_once"],
                                      ["optionId": "r", "name": "Reject", "kind": "reject_once"]]]]],
            ],
        ])
        for _ in 0..<4 {
            made.chat.send("hi")
            await until(5) { !made.chat.busy }
        }
        let outcomes = logged(made.log).compactMap { message -> String? in
            let outcome = (message["result"] as? [String: Any])?["outcome"] as? [String: Any]
            return outcome?["optionId"] as? String
        }
        XCTAssertEqual(outcomes, ["r", "r", "r", "r"])
    }

    /// Codex calls Search's tools under its own names and asks to run one as
    /// a command; the structured server and tool say it is Search's own, so
    /// it is let through whatever the kind, and shown as the browser tool it is.
    func testAStructuredSearchToolIsAllowedWhateverItsKind() async throws {
        let made = try made([
            "prompts": [[
                ["update": ["sessionUpdate": "tool_call", "toolCallId": "t1",
                            "title": "mcp.search.browser_tabs", "kind": "execute", "status": "pending",
                            "rawInput": ["server": "search", "tool": "browser_tabs", "arguments": [:]]]],
                ["ask": ["toolCall": ["toolCallId": "t1", "kind": "execute"],
                         "options": [["optionId": "a", "name": "Allow", "kind": "allow_once"],
                                     ["optionId": "r", "name": "Reject", "kind": "reject_once"]]]],
            ]],
        ])
        made.chat.send("hi")
        await until(10) { !made.chat.busy }

        let permission = logged(made.log).first { ($0["result"] as? [String: Any])?["outcome"] != nil }
        let outcome = (permission?["result"] as? [String: Any])?["outcome"] as? [String: Any]
        XCTAssertEqual(outcome?["optionId"] as? String, "a")
        XCTAssertEqual(made.chat.items.first { $0.kind == .tool }?.text, AgentTools.label("browser_tabs", [:]))
    }

    /// A command merely titled like a browser tool, with no server and tool
    /// of Search's behind it, is refused: the title is the agent's words.
    func testACommandTitledLikeAToolWithoutItsServerIsRefused() async throws {
        let made = try made([
            "prompts": [[
                ["update": ["sessionUpdate": "tool_call", "toolCallId": "t1",
                            "title": "mcp.search.browser_tabs", "kind": "execute", "status": "pending"]],
                ["ask": ["toolCall": ["toolCallId": "t1", "title": "mcp.search.browser_tabs", "kind": "execute"],
                         "options": [["optionId": "a", "name": "Allow", "kind": "allow_once"],
                                     ["optionId": "r", "name": "Reject", "kind": "reject_once"]]]],
            ]],
        ])
        made.chat.send("hi")
        await until(10) { !made.chat.busy }

        let permission = logged(made.log).first { ($0["result"] as? [String: Any])?["outcome"] != nil }
        let outcome = (permission?["result"] as? [String: Any])?["outcome"] as? [String: Any]
        XCTAssertEqual(outcome?["optionId"] as? String, "r")
    }

    /// A structured call for another server is not one of Search's tools.
    func testAStructuredCallForAnotherServerIsNotABrowserTool() async throws {
        let made = try made([
            "prompts": [[
                ["update": ["sessionUpdate": "tool_call", "toolCallId": "t1",
                            "kind": "execute", "status": "pending",
                            "rawInput": ["server": "other", "tool": "browser_tabs", "arguments": [:]]]],
            ]],
        ])
        made.chat.send("hi")
        await until(10) { !made.chat.busy }

        XCTAssertEqual(made.chat.items.first { $0.kind == .tool }?.text, "A tool of its own")
    }

    /// Codex nests a browser tool's own arguments under rawInput.arguments;
    /// the step ends on the catalogue's summary of that same call, not the
    /// label it started with.
    func testCodexAStructurallyNamedToolKeepsItsArguments() async throws {
        let made = try made([
            "prompts": [[
                ["update": ["sessionUpdate": "tool_call", "toolCallId": "t1",
                            "title": "mcp.search.browser_tabs", "kind": "execute", "status": "pending",
                            "rawInput": ["server": "search", "tool": "browser_tabs", "arguments": [:]]]],
                ["mcp": ["name": "browser_tabs", "arguments": [:]]],
                ["update": ["sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed"]],
            ]],
        ])
        made.chat.send("hi")
        await until(10) { !made.chat.busy }

        let expected = await summary("browser_tabs", for: made.chat)
        let tool = made.chat.items.first { $0.kind == .tool }
        XCTAssertTrue(tool?.done ?? false)
        XCTAssertEqual(tool?.text, expected)
    }

    // MARK: - items

    func testAMessageStartsItsOwnItem() async throws {
        let made = try made([
            "load": ["updates": [
                ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "Q1"]],
                ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "A1"]],
                ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "Q2"]],
                ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "A2"]],
            ]],
            "prompts": [[["update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "B"]]]]],
        ], session: "s-9")
        made.chat.open(in: made.browser)
        await until { made.chat.items.count == 4 && !made.chat.busy && made.chat.status == nil }
        XCTAssertEqual(made.chat.items.map(\.kind), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(made.chat.items.map(\.text), ["Q1", "A1", "Q2", "A2"])

        // An answer after the load's last text is an item of its own.
        made.chat.send("hi")
        await until { !made.chat.busy }
        XCTAssertEqual(made.chat.items.map(\.kind), [.user, .assistant, .user, .assistant, .user, .assistant])
        XCTAssertEqual(made.chat.items.suffix(2).map(\.text), ["hi", "B"])
    }

    // MARK: - a start that hangs

    func testAStartThatNeverAnswersGivesUp() async throws {
        let old = ACPTimeouts.session
        ACPTimeouts.session = 1
        defer { ACPTimeouts.session = old }
        let made = try made(["new": ["hang": true]])
        made.chat.send("hi")
        await until(10) { !made.chat.busy }
        XCTAssertEqual(made.chat.items.last?.kind, .error)
        XCTAssertTrue(made.chat.items.last?.text.contains("didn't answer session/new") ?? false,
                      made.chat.items.last?.text ?? "")
    }

    // MARK: - steps kept for a reopen

    func testThreeStepsAllKeepTheirSummaries() async throws {
        let steps: [[String: Any]] = (1...3).flatMap { number -> [[String: Any]] in
            [
                ["update": ["sessionUpdate": "tool_call", "toolCallId": "t\(number)",
                            "title": "mcp__search__browser_tabs", "status": "pending", "rawInput": [:]]],
                ["mcp": ["name": "browser_tabs", "arguments": [:]]],
                ["update": ["sessionUpdate": "tool_call_update", "toolCallId": "t\(number)", "status": "completed"]],
            ]
        }
        let first = try made(["prompts": [steps]])
        first.chat.send("hi")
        await until { !first.chat.busy }
        guard let expected = await summary("browser_tabs", for: first.chat) else { return XCTFail("no summary") }
        await until(5) { self.steps("s-1").count == 3 }

        let reopened = try made([
            "load": ["updates": (1...3).map { number -> [String: Any] in
                ["sessionUpdate": "tool_call", "toolCallId": "t\(number)",
                 "title": "mcp__search__browser_tabs", "status": "completed", "rawInput": [:]]
            }],
        ], session: "s-1")
        reopened.chat.open(in: reopened.browser)
        await until { reopened.chat.items.filter { $0.kind == .tool }.count == 3 && !reopened.chat.busy && reopened.chat.status == nil }
        XCTAssertEqual(reopened.chat.items.filter { $0.kind == .tool }.map(\.text), [expected, expected, expected])
    }

    // MARK: - summaries by their arguments

    func testSummariesAreMatchedByTheirArguments() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        let alpha = browser.open(URL(string: "data:text/html,%3Ctitle%3EALPHA%3C/title%3Eone")!, foreground: true, from: nil)
        let beta = browser.open(URL(string: "data:text/html,%3Ctitle%3EBETA%3C/title%3Etwo")!, foreground: true, from: alpha)
        await until(10) { alpha.built != nil && beta.built != nil && alpha.pageAddress != nil && beta.pageAddress != nil }
        let tabA = AgentTools.short(alpha), tabB = AgentTools.short(beta)

        let made = try made([
            "prompts": [[
                ["update": ["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "mcp__search__browser_read",
                            "status": "pending", "rawInput": ["tab": tabA]]],
                ["update": ["sessionUpdate": "tool_call", "toolCallId": "t2", "title": "mcp__search__browser_read",
                            "status": "pending", "rawInput": ["tab": tabB]]],
                ["mcp": ["name": "browser_read", "arguments": ["tab": tabA]]],
                ["mcp": ["name": "browser_read", "arguments": ["tab": tabB]]],
                ["update": ["sessionUpdate": "tool_call_update", "toolCallId": "t2", "status": "completed"]],
                ["update": ["sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed"]],
            ]],
        ], browser: browser)
        made.chat.send("hi")
        await until(30) { !made.chat.busy }
        let t1 = made.chat.items.first { $0.id == "tool-t1" }
        let t2 = made.chat.items.first { $0.id == "tool-t2" }
        XCTAssertTrue(t1?.text.contains("ALPHA") ?? false, t1?.text ?? "")
        XCTAssertTrue(t2?.text.contains("BETA") ?? false, t2?.text ?? "")
    }

    // MARK: - a tool's merging

    func testAToolsContentIsKeptForItsFailedEnd() async throws {
        let made = try made([
            "prompts": [[
                ["update": ["sessionUpdate": "tool_call", "toolCallId": "t8", "title": "Run shell",
                            "kind": "execute", "status": "pending"]],
                ["update": ["sessionUpdate": "tool_call_update", "toolCallId": "t8",
                            "content": [["type": "content", "content": ["type": "text", "text": "it broke"]]]]],
                ["update": ["sessionUpdate": "tool_call_update", "toolCallId": "t8", "status": "failed"]],
            ]],
        ])
        made.chat.send("hi")
        await until { !made.chat.busy }
        let tool = made.chat.items.first { $0.id == "tool-t8" }
        XCTAssertTrue(tool?.failed ?? false)
        XCTAssertEqual(tool?.detail, "it broke")
    }

    func testAToolUpdateForAnUnseenToolStillShowsDone() async throws {
        let made = try made([
            "prompts": [[
                ["update": ["sessionUpdate": "tool_call_update", "toolCallId": "t7", "title": "Some tool",
                            "status": "completed"]],
            ]],
        ])
        made.chat.send("hi")
        await until { !made.chat.busy }
        let tool = made.chat.items.first { $0.id == "tool-t7" }
        XCTAssertNotNil(tool)
        XCTAssertTrue(tool?.done ?? false)
    }

    // MARK: - a chat's own folder

    func testEachChatRunsInItsOwnFolder() async throws {
        let first = try made([:])
        let second = try made([:])
        first.chat.send("hi")
        second.chat.send("hi")
        await until(10) { !first.chat.busy && !second.chat.busy }

        let firstNew = logged(first.log).first { $0["method"] as? String == "session/new" }
        let secondNew = logged(second.log).first { $0["method"] as? String == "session/new" }
        let firstCwd = (firstNew?["params"] as? [String: Any])?["cwd"] as? String
        let secondCwd = (secondNew?["params"] as? [String: Any])?["cwd"] as? String
        XCTAssertNotNil(firstCwd)
        XCTAssertNotEqual(firstCwd, secondCwd)
        XCTAssertTrue(firstCwd?.contains(first.chat.id.uuidString) ?? false, firstCwd ?? "")
        XCTAssertTrue(secondCwd?.contains(second.chat.id.uuidString) ?? false, secondCwd ?? "")
    }
}
