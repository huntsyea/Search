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
    private var empty: URL!
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
        empty = folder.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        Agents.searchPathForTests = empty.path
        LoginShell.forget()
        Agents.shared.refresh()
        await until(10) { Agents.shared.looked }
    }

    override func tearDown() async throws {
        AgentOnce.deadline = 60
        AgentOnce.forgetModels()
        Pi.executable = nil
        // Back to the empty PATH, so a test's fake agents don't linger.
        Agents.searchPathForTests = empty?.path
        Agents.shared.refresh()
        await until(10) { Agents.shared.looked }
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

    /// The pid the script logged, waited for.
    private func pid(of log: URL) async -> Int? {
        await until(5) { self.logged(log).contains { $0["pid"] != nil } }
        return logged(log).first { $0["pid"] != nil }?["pid"] as? Int
    }

    /// It is gone: the pid no longer answers.
    private func gone(_ pid: Int?) async {
        guard let pid else { return XCTFail("the script never logged its pid") }
        await until(5) { kill(pid_t(pid), 0) == -1 }
    }

    // MARK: - the answer

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
        await gone(await pid(of: made.log))
    }

    // MARK: - no tools

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

    func testOneShotApprovesNothing() async throws {
        let made = try made([
            "prompts": [[
                ["update": ["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "browser_read", "status": "pending"]],
                ["ask": ["toolCall": ["toolCallId": "t1", "title": "browser_read"],
                         "options": [["optionId": "a", "name": "Allow", "kind": "allow_once"],
                                     ["optionId": "r", "name": "Reject", "kind": "reject_once"]]]],
                // Codex's shape: the server and tool named, marked as an MCP
                // call — a browser tool were it a chat's.
                ["ask": ["toolCall": ["toolCallId": "t2", "title": "mcp__search__browser_click",
                                      "_meta": ["is_mcp_tool_call": true],
                                      "rawInput": ["server": "search", "tool": "browser_click"]],
                         "options": [["optionId": "a", "name": "Allow", "kind": "allow_once"],
                                     ["optionId": "r", "name": "Reject", "kind": "reject_once"]]]],
                ["update": ["sessionUpdate": "agent_message_chunk",
                            "content": ["type": "text", "text": "<title>No</title>"]]],
            ]],
        ])
        let title = await PiOnce.title(for: "anything")
        XCTAssertEqual(title, "No")

        let outcomes = logged(made.log).compactMap { message -> String? in
            guard let result = message["result"] as? [String: Any],
                  let outcome = result["outcome"] as? [String: Any],
                  outcome["outcome"] as? String == "selected" else { return nil }
            return outcome["optionId"] as? String
        }
        XCTAssertEqual(outcomes, ["r", "r"])
    }

    // MARK: - the deadline

    func testAHungStartEndsAtTheDeadline() async throws {
        AgentOnce.deadline = 1
        let made = try made(["new": ["hang": true]])
        let began = Date()
        do {
            _ = try await AgentOnce.answer(agent: made.agent.id, system: "s", prompt: "p", model: nil)
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("took longer"), error.localizedDescription)
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
        await gone(await pid(of: made.log))
    }

    func testAHungOptionSetEndsAtTheDeadline() async throws {
        AgentOnce.deadline = 1
        let option: [String: Any] = ["id": "model", "name": "Model", "category": "model",
                                     "currentValue": "a", "options": [["value": "a", "name": "A"]]]
        let made = try made(["new": ["sessionId": "s-1", "configOptions": [option]],
                             "setConfig": ["hang": true]])
        let began = Date()
        do {
            _ = try await AgentOnce.answer(agent: made.agent.id, system: "s", prompt: "p", model: "a")
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("took longer"), error.localizedDescription)
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
        await gone(await pid(of: made.log))
    }

    // MARK: - the models

    func testModelsAreListed() async throws {
        let options: [[String: Any]] = [["value": "a", "name": "A"], ["value": "b", "name": "B"]]
        let option: [String: Any] = ["id": "model", "name": "Model", "category": "model",
                                     "currentValue": "a", "options": options]
        let made = try made(["new": ["sessionId": "s-1", "configOptions": [option]]])
        guard case .loaded(let models) = await AgentOnce.models(agent: made.agent.id) else {
            return XCTFail("expected loaded models")
        }
        XCTAssertEqual(models.map(\.value), ["a", "b"])
        XCTAssertFalse(logged(made.log).contains { $0["method"] as? String == "session/prompt" })
    }

    func testConcurrentModelAsksShareOneStart() async throws {
        let made = try made(["new": ["sessionId": "s-1"]])
        async let first = AgentOnce.models(agent: made.agent.id)
        async let second = AgentOnce.models(agent: made.agent.id)
        _ = await (first, second)
        XCTAssertEqual(logged(made.log).filter { $0["method"] as? String == "session/new" }.count, 1)
    }

    func testCancellingAModelsAskStopsTheAgent() async throws {
        let made = try made(["new": ["hang": true]])
        let task = Task { await AgentOnce.models(agent: made.agent.id) }
        let pid = await self.pid(of: made.log)
        await until(5) { self.logged(made.log).contains { $0["method"] as? String == "session/new" } }
        task.cancel()
        await gone(pid)
    }

    func testModelsNeedsSetUpWhenTheAdapterIsNotThere() async throws {
        // Nothing installed from an earlier test, then Claude Code and node
        // on the PATH.
        try? FileManager.default.removeItem(at: Adapters.folder(Adapters.claude))
        let found = folder.appendingPathComponent("found")
        try FileManager.default.createDirectory(at: found, withIntermediateDirectories: true)
        for name in ["claude", "node"] {
            let program = found.appendingPathComponent(name)
            try "#!/bin/sh\n".write(to: program, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        }
        Agents.searchPathForTests = found.path
        LoginShell.forget()
        Agents.shared.refresh()
        await until(10) { Agents.shared.looked }
        guard let adapter = Agents.shared.choice("claude")?.adapter else {
            return XCTFail("Claude Code wasn't found")
        }
        XCTAssertFalse(Adapters.isSetUp(adapter))

        guard case .needsSetUp(let wanted) = await AgentOnce.models(agent: "claude") else {
            return XCTFail("expected needsSetUp")
        }
        XCTAssertEqual(wanted.agent, "Claude Code")
        XCTAssertEqual(wanted.adapter, Adapters.claude)
    }

    func testModelsNeedsSignIn() async throws {
        let made = try made(["new": ["error": ["code": -32000, "message": "Authentication required"]]])
        guard case .needsSignIn(let wanted) = await AgentOnce.models(agent: made.agent.id) else {
            return XCTFail("expected needsSignIn")
        }
        XCTAssertEqual(wanted.agent, "scripted")
    }

    func testModelsCanBeEmptyAndAreNotKept() async throws {
        let made = try made(["new": ["sessionId": "s-1"]])
        guard case .loaded(let first) = await AgentOnce.models(agent: made.agent.id) else {
            return XCTFail("expected loaded")
        }
        XCTAssertTrue(first.isEmpty)
        // An empty list isn't kept: asking again starts the agent again.
        guard case .loaded = await AgentOnce.models(agent: made.agent.id) else {
            return XCTFail("expected loaded again")
        }
        XCTAssertEqual(logged(made.log).filter { $0["method"] as? String == "session/new" }.count, 2)
    }

    // MARK: - the bench's named agent

    func testARequestForPiStaysWithPi() async throws {
        let made = try made([
            "prompts": [[["update": ["sessionUpdate": "agent_message_chunk",
                                      "content": ["type": "text", "text": "<title>Mine</title>"]]]]],
        ])
        // pi isn't installed here: the run fails, quietly, and never reaches
        // the side agent.
        Pi.executable = folder.appendingPathComponent("no-pi")
        let title = await PiOnce.title(for: "anything", agent: "pi")
        XCTAssertNil(title)
        XCTAssertTrue(logged(made.log).isEmpty)
    }
}
