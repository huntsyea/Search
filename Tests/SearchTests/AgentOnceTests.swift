import Darwin
import Foundation
import XCTest
@testable import Search

/// One question to an ACP agent, away from any chat and with no tools: the
/// side prompts' run when the person chose another agent for them
/// (AgentOnce.swift, Suggestions.swift) — docs/design/agents.md.
@MainActor
final class AgentOnceTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private var folder: URL!
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
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("one-shot-\(UUID().uuidString)")
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
        Agents.searchPathForTests = nil
        LoginShell.forget()
        Store.settings.removeObject(forKey: Chats.sideAgentKey)
        Store.settings.removeObject(forKey: Chats.sideModelKey)
        Store.settings.removeObject(forKey: Agents.customKey)
        Store.settings.removeObject(forKey: Agents.hiddenKey)
        for key in Store.settings.dictionaryRepresentation().keys
        where key.hasPrefix("chat.agents.signin.") || key.hasPrefix("chat.agents.state.")
            || key.hasPrefix("chat.agents.model.") {
            Store.settings.removeObject(forKey: key)
        }
        for id in added { Agents.shared.remove(id) }
        added = []
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

    private struct Made {
        let agent: AgentChoice
        let log: URL
    }

    /// A custom agent whose command is the scripted ACP agent, set as the
    /// side agent for the prompts: the whole way through Agents, not around
    /// it.
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
        Store.settings.set(agent.id, forKey: Chats.sideAgentKey)
        return Made(agent: agent, log: log)
    }

    /// The log's lines, parsed. A half-written last line is let go.
    private func logged(_ log: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    func testAnAnswerIsCollected() async throws {
        let made = try made([
            "prompts": [[
                ["update": ["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "hmm"]]],
                ["update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "<title>Lighthouse"]]],
                ["update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": " story</title>"]]],
            ]],
        ])
        let title = await PiOnce.title(for: "write me a story about a lighthouse")
        XCTAssertEqual(title, "Lighthouse story")

        let received = logged(made.log)
        let new = received.first { $0["method"] as? String == "session/new" }
        XCTAssertTrue(((new?["params"] as? [String: Any])?["mcpServers"] as? [Any])?.isEmpty ?? false)
        let prompt = received.first { $0["method"] as? String == "session/prompt" }
        let blocks = (prompt?["params"] as? [String: Any])?["prompt"] as? [[String: Any]]
        let text = blocks?.first?["text"] as? String
        XCTAssertTrue(text?.hasPrefix(PiOnce.titleSystem) ?? false)
    }

    func testTheModelIsSetFirst() async throws {
        let options: [[String: Any]] = [["value": "a", "name": "A"], ["value": "b", "name": "B"]]
        let option: [String: Any] = ["id": "model", "name": "Model", "category": "model",
                                     "currentValue": "a", "options": options]
        let scenario: [String: Any] = [
            "new": ["sessionId": "s-1", "configOptions": [option]],
            "setConfig": ["configOptions": [option]],
            "prompts": [[["update": ["sessionUpdate": "agent_message_chunk",
                                      "content": ["type": "text", "text": "<title>Set</title>"]]]]],
        ]
        let listed = try made(scenario)
        Store.settings.set("b", forKey: Chats.sideModelKey)
        let title = await PiOnce.title(for: "anything")
        XCTAssertEqual(title, "Set")

        let received = logged(listed.log)
        let set = received.first { $0["method"] as? String == "session/set_config_option" }
        XCTAssertEqual((set?["params"] as? [String: Any])?["value"] as? String, "b")
        let setAt = received.firstIndex { $0["method"] as? String == "session/set_config_option" }
        let promptAt = received.firstIndex { $0["method"] as? String == "session/prompt" }
        XCTAssertNotNil(setAt)
        XCTAssertNotNil(promptAt)
        if let setAt, let promptAt { XCTAssertLessThan(setAt, promptAt) }

        // A model the agent doesn't list isn't set, and the answer still comes.
        let other = try made(scenario)
        Store.settings.set("z", forKey: Chats.sideModelKey)
        let still = await PiOnce.title(for: "anything")
        XCTAssertEqual(still, "Set")
        XCTAssertFalse(logged(other.log).contains { $0["method"] as? String == "session/set_config_option" })
    }

    func testFailuresAreQuiet() async throws {
        _ = try made(["new": ["error": ["code": -32000, "message": "Authentication required"]]])
        let title = await PiOnce.title(for: "anything")
        XCTAssertNil(title)
    }

    func testTheAgentIsStopped() async throws {
        let made = try made([
            "prompts": [[["update": ["sessionUpdate": "agent_message_chunk",
                                      "content": ["type": "text", "text": "<title>Done</title>"]]]]],
        ])
        let title = await PiOnce.title(for: "anything")
        XCTAssertEqual(title, "Done")
        // Its process is gone: stopping ends it, however it goes.
        let pid = logged(made.log).first { $0["pid"] != nil }?["pid"] as? Int
        XCTAssertNotNil(pid)
        await until(10) {
            guard let pid else { return true }
            return kill(pid_t(pid), 0) == -1
        }
    }

    func testModelsAreListed() async throws {
        let options: [[String: Any]] = [["value": "a", "name": "A"], ["value": "b", "name": "B"]]
        let option: [String: Any] = ["id": "model", "name": "Model", "category": "model",
                                     "currentValue": "a", "options": options]
        let made = try made(["new": ["sessionId": "s-1", "configOptions": [option]]])
        let models = await AgentOnce.models(agent: made.agent.id)
        XCTAssertEqual(models.map(\.value), ["a", "b"])
        XCTAssertFalse(logged(made.log).contains { $0["method"] as? String == "session/prompt" })
    }

    func testOneShotsHaveNoTools() async throws {
        let made = try made([
            "prompts": [[
                ["update": ["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "mcp__search__browser_tabs"]],
                ["mcp": ["name": "browser_tabs", "arguments": [:]]],
                ["update": ["sessionUpdate": "agent_message_chunk",
                            "content": ["type": "text", "text": "<title>No tools</title>"]]],
            ]],
        ])
        let title = await PiOnce.title(for: "anything")
        XCTAssertEqual(title, "No tools")

        let received = logged(made.log)
        let new = received.first { $0["method"] as? String == "session/new" }
        XCTAssertTrue(((new?["params"] as? [String: Any])?["mcpServers"] as? [Any])?.isEmpty ?? false)
        // The mcp step couldn't run: no server was given for it.
        XCTAssertNotNil(received.first { ($0["mcpResult"] as? [String: Any])?["error"] != nil })
    }
}
