import Foundation
import XCTest
@testable import Search

/// The ACP client against a scripted agent (Tests/fixtures/scripted-acp-agent.py):
/// the wire, with no provider and no tokens (docs/design/agents.md, "ACP, the client side").
@MainActor
final class ACPTests: XCTestCase {
    private var folder: URL!

    /// The script, found beside the test file, wherever it is built.
    private static var script: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/scripted-acp-agent.py")
    }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("acp-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard pythonIsThere() else { throw XCTSkip("python3 isn't installed") }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// `/usr/bin/env python3 --version`, run to its end: ACP needs it, and a
    /// machine without it skips these tests.
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

    /// The scenario written where the script reads it, and the log beside it.
    private func scenario(_ object: [String: Any]) throws -> (scenario: URL, log: URL) {
        let scenario = folder.appendingPathComponent("scenario.json")
        let log = folder.appendingPathComponent("log.jsonl")
        try JSONSerialization.data(withJSONObject: object).write(to: scenario)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        return (scenario, log)
    }

    /// A connection on the script, stopped by the caller.
    private func started(_ scenario: URL, _ log: URL) throws -> ACPConnection {
        let connection = ACPConnection()
        try connection.start("/usr/bin/env",
                             ["python3", Self.script.path, scenario.path, log.path],
                             in: folder, environment: ProcessInfo.processInfo.environment)
        return connection
    }

    /// The log's lines, parsed. A half-written last line is let go.
    private func logged(_ log: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    // MARK: - the wire

    func testInitializeAnswers() async throws {
        let paths = try scenario([:])
        let connection = try started(paths.scenario, paths.log)
        defer { connection.stop() }

        let result = try await connection.request("initialize", ["protocolVersion": 1])
        let info = (result as? [String: Any])?["agentInfo"] as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, "scripted")

        let sent = logged(paths.log).first { $0["method"] as? String == "initialize" }
        XCTAssertEqual(sent?["id"] as? Int, 1)
        XCTAssertEqual((sent?["params"] as? [String: Any])?["protocolVersion"] as? Int, 1)
    }

    /// A load's updates are all heard before the load's response ends the
    /// request that asked for it.
    func testUpdatesSaidBeforeAResponseAreHeardFirst() async throws {
        let updates: [[String: Any]] = [
            ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "a"]],
            ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "b"]],
            ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "c"]],
        ]
        let paths = try scenario(["load": ["updates": updates]])
        let connection = try started(paths.scenario, paths.log)
        defer { connection.stop() }

        var heard: [String] = []
        connection.onNotification = { method, _ in heard.append(method) }

        _ = try await connection.request("session/load", ["sessionId": "s-1"])
        XCTAssertEqual(heard, ["session/update", "session/update", "session/update"])
    }

    /// A prompt's permission request is answered; an unhandled request gets
    /// "method not found".
    func testAgentRequestsAreAnswered() async throws {
        let paths = try scenario([
            "prompts": [
                [["ask": ["toolCall": ["toolCallId": "t1"],
                          "options": [["optionId": "no", "name": "No", "kind": "reject_once"]]]]],
                [["request": ["method": "fs/read_text_file",
                              "params": ["sessionId": "s-1", "path": "/tmp/nope"]]]],
            ],
        ])
        let connection = try started(paths.scenario, paths.log)
        defer { connection.stop() }

        connection.onRequest = { method, _, respond in
            guard method == "session/request_permission" else { return }
            respond(.success(["outcome": ["outcome": "selected", "optionId": "no"]]))
        }
        let first = try await connection.request("session/prompt", ["sessionId": "s-1", "prompt": []])
        XCTAssertEqual((first as? [String: Any])?["stopReason"] as? String, "end_turn")

        // Nothing handles this one: the agent is told so.
        connection.onRequest = nil
        let second = try await connection.request("session/prompt", ["sessionId": "s-1", "prompt": []])
        XCTAssertEqual((second as? [String: Any])?["stopReason"] as? String, "end_turn")

        let received = logged(paths.log)
        let allowed = received.first { message in
            guard let result = message["result"] as? [String: Any],
                  let outcome = result["outcome"] as? [String: Any] else { return false }
            return outcome["outcome"] as? String == "selected"
        }
        XCTAssertNotNil(allowed)
        let refused = received.first { message in
            (message["error"] as? [String: Any])?["code"] as? Int == -32601
        }
        XCTAssertNotNil(refused)
    }

    func testErrorsComeBackAsACPError() async throws {
        let paths = try scenario(["new": ["error": ["code": -32000, "message": "Authentication required"]]])
        let connection = try started(paths.scenario, paths.log)
        defer { connection.stop() }

        do {
            _ = try await connection.request("session/new", ["cwd": folder.path, "mcpServers": []])
            XCTFail("expected an ACP error")
        } catch let error as ACPError {
            XCTAssertEqual(error.code, ACPError.authRequired)
            XCTAssertEqual(error.message, "Authentication required")
        }
    }

    /// The agent goes while a prompt waits: the request fails, and onExit
    /// carries the last thing it said.
    func testAnAgentThatEndsFailsWhatWaits() async throws {
        let paths = try scenario(["prompts": [[["exit": 3]]]])
        let connection = try started(paths.scenario, paths.log)
        defer { connection.stop() }

        let exited = expectation(description: "the agent ended")
        var why: String?
        connection.onExit = { tail in
            why = tail
            exited.fulfill()
        }

        do {
            _ = try await connection.request("session/prompt", ["sessionId": "s-1", "prompt": []])
            XCTFail("expected a failure")
        } catch let failure as ChildProcess.Failure {
            XCTAssertTrue(failure.why.contains("stopped"), failure.why)
        }

        await fulfillment(of: [exited], timeout: 5)
        XCTAssertEqual(why, "scripted agent exiting")
    }
}
