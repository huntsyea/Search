import XCTest
@testable import Search

// pi started, talked to and stopped (Pi.swift, Suggestions.swift), against
// a fake pi: a shell script each test writes, put in pi's place with
// Pi.executable.

final class PiTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("pi-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        Pi.executable = nil
        try? FileManager.default.removeItem(at: folder)
    }

    /// `body` as a shell script, made the pi that is started.
    private func fakePi(_ body: String) throws {
        let url = folder.appendingPathComponent("pi")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        Pi.executable = url
    }

    /// A path in the test's folder, for a fake pi to write what it was sent.
    private func path(_ name: String) -> String {
        folder.appendingPathComponent(name).path
    }

    /// What a fake pi wrote to `name`, once it has (5 s at most).
    private func written(_ name: String) throws -> String {
        let file = folder.appendingPathComponent(name)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty {
                return text
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("\(name) was never written")
        throw NSError(domain: "PiTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(name) was never written"])
    }

    /// A PiProcess started on the fake pi, in the test's folder; `ready`
    /// sets its callbacks first, so nothing pi says at once is missed.
    private func started(_ ready: (PiProcess) -> Void = { _ in }) throws -> PiProcess {
        let pi = PiProcess()
        ready(pi)
        try pi.start(arguments: [], directory: folder.appendingPathComponent("run"), environment: [:])
        return pi
    }

    // MARK: - what pi is allowed

    func testConfinedToTheseTools() {
        XCTAssertEqual(Pi.confined(tools: ["browser_open", "browser_tabs"]),
                       ["--tools", "browser_open,browser_tabs",
                        "--no-mcp", "--no-skills", "--no-prompt-templates", "--no-context-files", "--no-themes"])
    }

    func testConfinedToNoTools() {
        let flags = Pi.confined(tools: [])
        XCTAssertEqual(flags.first, "--no-tools")
        for flag in ["--no-mcp", "--no-skills", "--no-prompt-templates", "--no-context-files", "--no-themes"] {
            XCTAssertTrue(flags.contains(flag), flag)
        }
        XCTAssertFalse(flags.contains("--tools"))
    }

    // MARK: - the chat's pi

    func testRequestGetsItsResponse() async throws {
        try fakePi("""
        read line
        echo '{"type":"response","id":"search-1","success":true,"data":{"ok":1}}'
        while read line; do :; done
        """)
        let pi = try started()
        defer { pi.stop() }
        let data = try await pi.request(["type": "get_state"])
        XCTAssertEqual(data["ok"] as? Int, 1)
    }

    func testRefusalSaysWhy() async throws {
        try fakePi("""
        read line
        echo '{"type":"response","id":"search-1","success":false,"error":"no such model"}'
        while read line; do :; done
        """)
        let pi = try started()
        defer { pi.stop() }
        do {
            _ = try await pi.request(["type": "get_state"])
            XCTFail("expected a refusal")
        } catch let failure as PiProcess.Failure {
            XCTAssertEqual(failure.why, "no such model")
        }
    }

    func testEventsArriveOnMain() async throws {
        try fakePi("""
        echo '{"type":"agent_start"}'
        while read line; do :; done
        """)
        let arrived = expectation(description: "an event")
        var type: String?
        let pi = try started { pi in
            pi.onEvent = { event in
                XCTAssertTrue(Thread.isMainThread)
                type = event["type"] as? String
                arrived.fulfill()
            }
        }
        defer { pi.stop() }
        await fulfillment(of: [arrived], timeout: 5)
        XCTAssertEqual(type, "agent_start")
    }

    /// pi asks for a dialog nobody offers; it's answered as cancelled.
    func testDialogAnsweredAsCancelled() async throws {
        try fakePi("""
        echo '{"type":"extension_ui_request","id":"d1","method":"confirm"}'
        read line; printf '%s\\n' "$line" > "\(path("sent"))"
        while read line; do :; done
        """)
        let pi = try started()
        defer { pi.stop() }
        let sent = try written("sent")
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])
        XCTAssertEqual(record["type"] as? String, "extension_ui_response")
        XCTAssertEqual(record["id"] as? String, "d1")
        XCTAssertEqual(record["cancelled"] as? Bool, true)
    }

    func testToolCallGoesBothWays() async throws {
        try fakePi("""
        echo '{"kind":"tool","id":"t1","name":"browser_tabs"}' >&3
        read reply <&4
        printf '%s\\n' "$reply" > "\(path("reply"))"
        while read line; do :; done
        """)
        let called = expectation(description: "a tool call")
        let pi = try started { pi in
            pi.onTool = { call, reply in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(call["name"] as? String, "browser_tabs")
                reply(["content": [["type": "text", "text": "two tabs"]]])
                called.fulfill()
            }
        }
        defer { pi.stop() }
        await fulfillment(of: [called], timeout: 5)
        let reply = try written("reply")
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        XCTAssertEqual(record["kind"] as? String, "tool-result")
        XCTAssertEqual(record["id"] as? String, "t1")
        let content = try XCTUnwrap(record["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "two tabs")
    }

    func testCancelReachesTheChat() async throws {
        try fakePi("""
        echo '{"kind":"cancel"}' >&3
        while read line; do :; done
        """)
        let cancelled = expectation(description: "a cancel")
        let pi = try started { pi in
            pi.onCancel = { cancelled.fulfill() }
        }
        defer { pi.stop() }
        await fulfillment(of: [cancelled], timeout: 5)
    }

    func testExitSaysWhyAndFailsWhatWaits() async throws {
        try fakePi("""
        read line; echo "No API key for anthropic" >&2; exit 1
        """)
        let exited = expectation(description: "pi exited")
        var why: String?
        let pi = try started { pi in
            pi.onExit = { tail in
                why = tail
                exited.fulfill()
            }
        }
        defer { pi.stop() }
        do {
            _ = try await pi.request(["type": "prompt"])
            XCTFail("expected a failure")
        } catch let failure as PiProcess.Failure {
            XCTAssertEqual(failure.why, "pi stopped")
        }
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertEqual(why, "No API key for anthropic")
        XCTAssertFalse(pi.running)
    }

    func testStopEndsPi() async throws {
        try fakePi("""
        while read line; do :; done
        """)
        let exited = expectation(description: "pi exited")
        let pi = try started { pi in
            pi.onExit = { _ in exited.fulfill() }
        }
        pi.stop()
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertFalse(pi.running)
    }

    func testStopEndsAPiThatIgnoresIt() async throws {
        try fakePi("""
        trap '' TERM
        while read line; do :; done
        sleep 30
        """)
        let exited = expectation(description: "pi exited")
        let pi = try started { pi in
            pi.onExit = { _ in exited.fulfill() }
        }
        pi.stop(grace: 0.2)
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertFalse(pi.running)
    }

    /// A chat's pi that closes stdout but stays alive is still ended.
    func testChatPiThatClosesStdoutStillGoes() async throws {
        try fakePi("""
        exec >&-
        trap '' TERM
        sleep 30
        """)
        let exited = expectation(description: "pi exited")
        let pi = try started { pi in
            pi.onExit = { _ in exited.fulfill() }
        }
        await fulfillment(of: [exited], timeout: 8)
        XCTAssertFalse(pi.running)
    }

    /// Nothing Search has open goes with pi: only its own five descriptors.
    func testNothingElseGoesWithPi() async throws {
        let held = (0..<10).compactMap { _ in FileHandle(forReadingAtPath: "/etc/hosts") }
        XCTAssertEqual(held.count, 10)
        try fakePi("""
        ls /dev/fd > "\(path("fds"))"
        while read line; do :; done
        """)
        let pi = try started()
        defer { pi.stop() }
        let numbers = try written("fds").split(whereSeparator: \.isNewline).map { try XCTUnwrap(Int($0)) }
        // pi's five are 0–4; `ls` itself holds two more on macOS (5 and 6).
        XCTAssertTrue(numbers.allSatisfy { (0...6).contains($0) }, "descriptors: \(numbers)")
        withExtendedLifetime(held) {}
    }

    func testMissingPiSaysToInstallIt() throws {
        Pi.executable = folder.appendingPathComponent("nothing")
        XCTAssertThrowsError(try PiProcess().start(arguments: [], directory: folder.appendingPathComponent("run"),
                                                   environment: [:])) { error in
            guard let failure = error as? PiProcess.Failure else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(failure.why.contains("isn't installed"), failure.why)
        }
    }

    // MARK: - the one-shot runs

    func testAnswerIsTheLastAssistantMessage() async throws {
        try fakePi("""
        for a in "$@"; do printf '%s\\n' "$a"; done > "\(path("args"))"
        echo '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"<title>Draft</title>"}]}}'
        echo '{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"q"}]}}'
        echo '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"<title>Jazz Shop</title>"}]}}'
        """)
        let answer = try await PiOnce.answer(system: "Be brief.", prompt: "Name this", model: "kimi-coding/k3")
        XCTAssertEqual(answer, "<title>Jazz Shop</title>")
        let args = try written("args").split(separator: "\n").map(String.init)
        for flag in ["--print", "--no-session", "--no-tools",
                     "--no-mcp", "--no-skills", "--no-prompt-templates", "--no-context-files", "--no-themes"] {
            XCTAssertTrue(args.contains(flag), flag)
        }
        let model = try XCTUnwrap(args.firstIndex(of: "--model"))
        XCTAssertEqual(args[model + 1], "kimi-coding/k3")
        XCTAssertEqual(args.last, "Name this")
        XCTAssertFalse(args.contains("--tools"))
    }

    func testModelErrorSaysWhy() async throws {
        try fakePi("""
        echo '{"type":"message_end","message":{"role":"assistant","stopReason":"error","errorMessage":"rate limited"}}'
        """)
        do {
            _ = try await PiOnce.answer(system: "Be brief.", prompt: "Name this", model: nil)
            XCTFail("expected a failure")
        } catch let failure as PiOnce.Failure {
            XCTAssertEqual(failure.why, "rate limited")
        }
    }

    func testOneShotHoldsNothingElse() throws {
        let held = (0..<10).compactMap { _ in FileHandle(forReadingAtPath: "/etc/hosts") }
        XCTAssertEqual(held.count, 10)
        try fakePi("ls /dev/fd\n")
        let output = try Pi.print([])
        let numbers = try output.split(whereSeparator: \.isNewline).map { try XCTUnwrap(Int($0)) }
        // The one-shot's three are 0–2; `ls` itself holds two more on macOS (3 and 4).
        XCTAssertTrue(numbers.allSatisfy { (0...4).contains($0) }, "descriptors: \(numbers)")
        withExtendedLifetime(held) {}
    }

    func testMissingPiForAnAnswer() async throws {
        Pi.executable = folder.appendingPathComponent("nothing")
        do {
            _ = try await PiOnce.answer(system: "Be brief.", prompt: "Name this", model: nil)
            XCTFail("expected a failure")
        } catch let failure as PiOnce.Failure {
            XCTAssertTrue(failure.why.contains("isn't installed"), failure.why)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    /// Needs both SIGKILL (pi ignores SIGTERM) and the process group: the
    /// `sleep` holds stdout open even after the shell itself is gone.
    func testOneShotGivesUpOnAPiThatIgnoresIt() throws {
        try fakePi("""
        trap '' TERM
        sleep 30
        """)
        let began = Date()
        XCTAssertThrowsError(try Pi.print([], deadline: 1)) { error in
            guard let failure = error as? Pi.Failure else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(failure.why.contains("longer than"), failure.why)
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 6)
    }

    /// stdout closing is not pi exiting: a pi that closes it and hangs still
    /// goes at the deadline.
    func testOneShotGivesUpWhenStdoutClosesFirst() throws {
        try fakePi("""
        exec >&-
        trap '' TERM
        sleep 30
        """)
        let began = Date()
        XCTAssertThrowsError(try Pi.print([], deadline: 1)) { error in
            guard let failure = error as? Pi.Failure else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(failure.why.contains("longer than"), failure.why)
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 6)
    }

    func testOneShotSaysWhyItFailed() async throws {
        try fakePi("""
        echo "No API key for anthropic" >&2
        exit 1
        """)
        do {
            _ = try await PiOnce.answer(system: "s", prompt: "p", model: nil)
            XCTFail("expected a failure")
        } catch let failure as PiOnce.Failure {
            XCTAssertEqual(failure.why, "No API key for anthropic")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - the models

    func testModelsFromTheTable() throws {
        try fakePi("""
        printf 'provider      model     context
        kimi-coding   k3        1.0M
        ollama-cloud  glm-5.3   200K
        '
        """)
        XCTAssertEqual(try Pi.models(),
                       [Pi.Model(provider: "kimi-coding", id: "k3"),
                        Pi.Model(provider: "ollama-cloud", id: "glm-5.3")])
    }

    func testModelsLeaveStderrOut() throws {
        try fakePi("""
        echo "Warning: an extension failed to load" >&2
        printf 'provider      model     context
        kimi-coding   k3        1.0M
        ollama-cloud  glm-5.3   200K
        '
        """)
        XCTAssertEqual(try Pi.models(),
                       [Pi.Model(provider: "kimi-coding", id: "k3"),
                        Pi.Model(provider: "ollama-cloud", id: "glm-5.3")])
    }

    func testModelsGiveUp() throws {
        try fakePi("""
        sleep 30
        """)
        let began = Date()
        XCTAssertThrowsError(try Pi.models(deadline: 1)) { error in
            guard let failure = error as? Pi.Failure else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(failure.why.contains("longer than"), failure.why)
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
    }
}
