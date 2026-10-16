import AppKit
import Foundation
import XCTest
@testable import Search

/// A live check against a real ACP agent, off by default: it spends the
/// person's tokens, so it runs only when SEARCH_LIVE_ACP says so (e.g.
/// "opencode acp"). It records the wire to a file, to replay later.
@MainActor
final class ACPLiveTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    /// Held so the chat's weak browser stays alive.
    private var browsers: [Browser] = []

    override func tearDown() async throws {
        ACPConnection.recorder = nil
        MCPDoor.executableOverride = nil
        browsers = []
        try await super.tearDown()
    }

    /// Where the built Search binary is, next to the test bundle; nil when it
    /// isn't there (the test skips).
    private func searchBinary() -> String? {
        let binary = Bundle(for: ACPLiveTests.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("Search").path
        return FileManager.default.isExecutableFile(atPath: binary) ? binary : nil
    }

    func testARealAgentUsesTheBrowsersTools() async throws {
        let setting = ProcessInfo.processInfo.environment["SEARCH_LIVE_ACP"]?
            .split(separator: " ").map(String.init) ?? []
        guard let program = setting.first, let path = LoginShell.find(program) else {
            throw XCTSkip("SEARCH_LIVE_ACP isn't set to an agent on this PATH")
        }
        guard let binary = searchBinary() else { throw XCTSkip("the Search binary isn't built") }
        MCPDoor.executableOverride = binary

        var environment: [String: String] = [:]
        if let json = ProcessInfo.processInfo.environment["SEARCH_LIVE_ACP_ENV"],
           let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            environment = object
        }

        let transcript = FileManager.default.temporaryDirectory.appendingPathComponent("acp-live-\(program).jsonl")
        let recorder = try WireRecorder(transcript)
        ACPConnection.recorder = { direction, message in recorder.append(direction, message) }
        defer {
            ACPConnection.recorder = nil
            recorder.close()
        }

        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        let chat = Chat(title: "Test", mode: .act,
                        agent: .acp(ACPSpec(id: program, name: program, path: path,
                                            arguments: Array(setting.dropFirst()), environment: environment)))
        defer { Chats.delete(chat) }
        chat.browser = browser

        if let model = ProcessInfo.processInfo.environment["SEARCH_LIVE_ACP_MODEL"], !model.isEmpty {
            chat.loadOptions()
            await until(30) { chat.option(.model) != nil }
            chat.choose(chat.option(.model)?.id ?? "model", model)
            // Give the set a moment to reach the agent before the prompt.
            try? await Task.sleep(for: .seconds(2))
        }

        chat.send("Call the browser_tabs tool exactly once, then reply with just the word: done")
        await until(30) { chat.busy }
        await until(120) { !chat.busy }

        for item in chat.items {
            print("live: \(item.kind) failed=\(item.failed) text=\(item.text) detail=\(item.detail)")
        }
        print("live transcript: \(transcript.path)")

        XCTAssertTrue(chat.items.contains { $0.kind == .tool && $0.text != "A tool of its own" && !$0.failed },
                      "no browser tool step: \(chat.items.map(\.text))")
        XCTAssertTrue(chat.items.contains { $0.kind == .assistant && !$0.text.isEmpty },
                      "no assistant text: \(chat.items.map(\.text))")
    }
}

/// The wire as JSON lines: what the agent said ("in") and what Search sent
/// ("out"). A lock keeps appends whole however the recorder is called.
private final class WireRecorder {
    private let handle: FileHandle
    private let lock = NSLock()

    init(_ url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.seekToEnd()
    }

    func append(_ direction: String, _ message: Any) {
        guard var data = try? JSONSerialization.data(withJSONObject: ["dir": direction, "msg": message]) else { return }
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        try? handle.write(contentsOf: data)
    }

    func close() { try? handle.close() }
}
