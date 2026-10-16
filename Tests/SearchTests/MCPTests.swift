import Darwin
import Foundation
import XCTest
@testable import Search

/// The MCP server's protocol on its own: messages in and answered, with the
/// catalogue behind it and nothing on the wire (docs/design/agents.md).
@MainActor
final class MCPTests: XCTestCase {

    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    /// What a server said, called and was asked to stop, for one test.
    private final class Recorder {
        var sent: [[String: Any]] = []
        var calls: [[String: Any]] = []
        var replies: [([String: Any]) -> Void] = []
        var cancels = 0
    }

    /// A server whose sends land in `sent`, whose calls are kept with the
    /// reply each waits on, and whose cancels are counted.
    private func server(_ recorder: Recorder) -> MCPServer {
        MCPServer(call: { call, reply in
            recorder.calls.append(call)
            recorder.replies.append(reply)
        }, cancel: {
            recorder.cancels += 1
        }, send: { message in
            recorder.sent.append(message)
        })
    }

    private func ask(_ server: MCPServer, id: Any, _ method: String, _ params: [String: Any] = [:]) {
        server.receive(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    func testInitializeSpeaksTheAgentsVersion() {
        let recorder = Recorder()
        let server = server(recorder)

        ask(server, id: 1, "initialize", ["protocolVersion": "2025-06-18"])
        let first = recorder.sent.last
        XCTAssertEqual(first?["id"] as? Int, 1)
        let result = first?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-06-18")
        let capabilities = result?["capabilities"] as? [String: Any]
        XCTAssertNotNil(capabilities?["tools"] as? [String: Any])
        let info = result?["serverInfo"] as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, "search")

        ask(server, id: 2, "initialize", ["protocolVersion": "1999-01-01"])
        XCTAssertEqual((recorder.sent.last?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
    }

    func testToolsListIsTheCatalogue() {
        let recorder = Recorder()
        let server = server(recorder)
        ask(server, id: 1, "tools/list")

        let result = recorder.sent.last?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.compactMap { $0["name"] as? String }, AgentTools.names)
        for tool in tools ?? [] {
            XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object", tool["name"] as? String ?? "")
        }
        let close = tools?.first { $0["name"] as? String == "browser_close" }
        XCTAssertEqual((close?["annotations"] as? [String: Any])?["destructiveHint"] as? Bool, true)
        let read = tools?.first { $0["name"] as? String == "browser_read" }
        XCTAssertEqual((read?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
    }

    func testToolsCallGoesToTheCatalogueAndAnswers() {
        let recorder = Recorder()
        let server = server(recorder)
        ask(server, id: "a", "tools/call", ["name": "browser_tabs", "arguments": ["x": 1]])

        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls.first?["name"] as? String, "browser_tabs")
        XCTAssertEqual((recorder.calls.first?["args"] as? [String: Int])?["x"], 1)

        recorder.replies.first?(["content": [["type": "text", "text": "hi"]], "isError": false, "details": ["summary": "s"]])
        let sent = recorder.sent.last
        XCTAssertEqual(sent?["id"] as? String, "a")
        let result = sent?["result"] as? [String: Any]
        XCTAssertEqual((result?["content"] as? [[String: Any]])?.first?["text"] as? String, "hi")
        XCTAssertEqual(result?["isError"] as? Bool, false)
        XCTAssertNil(result?["details"])
    }

    func testUnknownToolAndMethod() {
        let recorder = Recorder()
        let server = server(recorder)

        ask(server, id: 1, "tools/call", ["name": "rm_rf"])
        XCTAssertEqual((recorder.sent.last?["error"] as? [String: Any])?["code"] as? Int, -32602)

        ask(server, id: 2, "resources/list")
        XCTAssertEqual((recorder.sent.last?["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    func testNotificationsAreNotAnswered() {
        let recorder = Recorder()
        let server = server(recorder)
        server.receive(["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertTrue(recorder.sent.isEmpty)
    }

    func testCancelledCallIsNotAnswered() {
        let recorder = Recorder()
        let server = server(recorder)
        ask(server, id: 7, "tools/call", ["name": "browser_tabs", "arguments": [:]])

        server.receive(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 7]])
        XCTAssertEqual(recorder.cancels, 1)

        recorder.replies.first?(["content": [], "isError": false])
        XCTAssertTrue(recorder.sent.isEmpty)
    }

    func testPingAnswers() {
        let recorder = Recorder()
        let server = server(recorder)
        ask(server, id: 1, "ping")
        let result = recorder.sent.last?["result"] as? [String: Any]
        XCTAssertEqual(result?.isEmpty, true)
    }

    // MARK: - the door

    /// The tool names a door's catalogue was asked for, and a lock so the
    /// reading thread and the test can look without tripping over each other.
    private final class DoorTools {
        private let lock = NSLock()
        private var names: [String] = []
        func asked(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return names }
    }

    /// A door whose tools answer at once with `text`.
    private func makeDoor(_ tools: DoorTools, text: String = "tabs: none") -> MCPDoor? {
        MCPDoor(call: { call, reply in
            tools.asked(call["name"] as? String ?? "")
            reply(["content": [["type": "text", "text": text]], "isError": false])
        }, cancel: {})
    }

    /// stdout's lines, parsed, taken on the reading thread.
    private final class Lines {
        private let lock = NSLock()
        private var carry = Data()
        private var ready: [[String: Any]] = []

        func take(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            carry.append(data)
            while let newline = carry.firstIndex(of: 0x0A) {
                let line = carry[carry.startIndex..<newline]
                carry.removeSubrange(carry.startIndex...newline)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    ready.append(object)
                }
            }
        }

        var all: [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return ready
        }
    }

    /// What a blocking read off the main actor came back with.
    private final class Answer {
        private let lock = NSLock()
        private var code: Int?
        func set(_ code: Int) { lock.lock(); self.code = code; lock.unlock() }
        var got: Int? { lock.lock(); defer { lock.unlock() }; return code }
    }

    func testTheDoorAnswersThroughTheHelper() async throws {
        let binary = Bundle(for: MCPTests.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("Search").path
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw XCTSkip("the Search binary isn't built")
        }
        MCPDoor.executableOverride = binary
        defer { MCPDoor.executableOverride = nil }

        let tools = DoorTools()
        guard let door = makeDoor(tools) else { return XCTFail("the door couldn't be opened") }
        defer { door.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: door.server["command"] as? String ?? "")
        process.arguments = door.server["args"] as? [String] ?? []
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        let lines = Lines()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            lines.take(data)
        }

        func ask(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try ask(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        try ask(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "browser_tabs", "arguments": [:]]])

        await until(5) { lines.all.count >= 2 }
        let byID = Dictionary(uniqueKeysWithValues: lines.all.compactMap { message -> (Int, [String: Any])? in
            guard let id = message["id"] as? Int else { return nil }
            return (id, message)
        })
        XCTAssertNotNil((byID[1]?["result"] as? [String: Any])?["protocolVersion"])
        let content = (byID[2]?["result"] as? [String: Any])?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["text"] as? String, "tabs: none")
        XCTAssertEqual(tools.all, ["browser_tabs"])

        try input.fileHandleForWriting.close()
        door.close()
        await until(5) { !process.isRunning }
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: door.path))
    }

    func testTheDoorShutsAWrongToken() async {
        let tools = DoorTools()
        guard let door = makeDoor(tools) else { return XCTFail("the door couldn't be opened") }
        defer { door.close() }

        guard let fd = UnixSocket.connect(to: door.path) else { return XCTFail("couldn't reach the door") }
        defer { Darwin.close(fd) }
        // A write after the door shuts us fails quietly, rather than with a
        // signal, so the second line below can't end the test run.
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        for text in ["nope\n", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}\n"] {
            var line = Data(text.utf8)
            line.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
        }

        // The read blocks, so it is done off the main actor and raced with a
        // deadline: EOF is what a shut connection is.
        let eof = expectation(description: "the door shuts a wrong token")
        let answer = Answer()
        DispatchQueue.global().async {
            var byte: UInt8 = 0
            answer.set(Darwin.read(fd, &byte, 1))
            eof.fulfill()
        }
        await fulfillment(of: [eof], timeout: 2)
        XCTAssertEqual(answer.got, 0)
        XCTAssertEqual(tools.all, [])
    }

    func testTheDoorIsOnlyThisUsers() throws {
        let tools = DoorTools()
        guard let door = makeDoor(tools) else { return XCTFail("the door couldn't be opened") }
        defer { door.close() }

        let socket = try FileManager.default.attributesOfItem(atPath: door.path)
        XCTAssertEqual((socket[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: (door.path as NSString).deletingLastPathComponent)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testASlowAgentDoesNotHoldTheMainThread() async {
        let tools = DoorTools()
        guard let door = makeDoor(tools, text: String(repeating: "x", count: 2 * 1024 * 1024)) else {
            return XCTFail("the door couldn't be opened")
        }
        defer { door.close() }

        guard let fd = UnixSocket.connect(to: door.path) else { return XCTFail("couldn't reach the door") }
        defer { Darwin.close(fd) }
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)

        // Never read: each 2 MB answer has nowhere to go. The old blocking
        // write would have stopped the main thread dead on the first one.
        func send(_ object: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
            data.append(0x0A)
            data.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
        }
        var token = Data((door.token + "\n").utf8)
        token.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
        send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        for id in 2...21 {
            send(["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": "browser_tabs", "arguments": [:]]])
        }

        // The main actor must still get through every call.
        await until(5) { tools.all.count == 20 }

        // And the output is still delivered, read off the main actor.
        let delivered = await Task.detached { () -> Bool in
            var seen = Data()
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                var watching = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&watching, 1, 200) > 0 else { continue }
                var buffer = [UInt8](repeating: 0, count: 65536)
                let n = Darwin.read(fd, &buffer, buffer.count)
                if n > 0 {
                    seen.append(contentsOf: buffer[0..<n])
                    if seen.contains(0x0A) { return true }
                } else if n == 0 {
                    return false
                }
            }
            return seen.contains(0x0A)
        }.value
        XCTAssertTrue(delivered)
    }
}
