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
    private func made(_ scenario: [String: Any], session: String? = nil) throws -> Made {
        let scenarioFile = folder.appendingPathComponent("scenario-\(UUID().uuidString).json")
        let log = folder.appendingPathComponent("log-\(UUID().uuidString).jsonl")
        try JSONSerialization.data(withJSONObject: scenario).write(to: scenarioFile)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        let chat = Chat(title: "Test", session: session,
                        agent: .acp(ACPSpec(id: "scripted", name: "scripted", path: "/usr/bin/env",
                                            arguments: ["python3", Self.script.path, scenarioFile.path, log.path])))
        chats.append(chat)
        chat.browser = browser
        return Made(chat: chat, browser: browser, log: log)
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

    // MARK: - failures

    func testSignInNeeded() async throws {
        let made = try made(["new": ["error": ["code": -32000, "message": "Authentication required"]]])
        made.chat.send("hi")
        await until { !made.chat.busy }

        XCTAssertEqual(made.chat.items.last?.kind, .error)
        XCTAssertEqual(made.chat.items.last?.text, "scripted needs you to sign in first.")
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
}
