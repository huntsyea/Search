import Foundation
import XCTest
@testable import Search

/// The agents Search knows, finds and lets the person add, and which agent a
/// chat runs on (Agents.swift, Chats.swift): docs/design/agents.md,
/// "Discovery". A temporary PATH with two scripts stands in for the person's
/// login shell's, so what is found doesn't depend on this Mac.
@MainActor
final class AgentsTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private var folder: URL!
    private var chats: [Chat] = []

    override func setUp() async throws {
        try await super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Two known agents' programs, found and never run.
        for name in ["opencode", "kimi"] {
            let script = folder.appendingPathComponent(name)
            try "#!/bin/sh\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        Agents.searchPathForTests = folder.path
        LoginShell.forget()
        Agents.shared.refresh()
        await until(10) { Agents.shared.looked }
    }

    override func tearDown() async throws {
        for chat in chats { Chats.delete(chat) }
        chats = []
        Agents.searchPathForTests = nil
        Store.settings.removeObject(forKey: Agents.hiddenKey)
        Store.settings.removeObject(forKey: Agents.customKey)
        Store.settings.removeObject(forKey: Chats.agentKey)
        LoginShell.forget()
        try? FileManager.default.removeItem(at: folder)
        try await super.tearDown()
    }

    // MARK: - finding

    func testKnownAgentsFoundOnThePath() {
        let ids = Agents.shared.all.map(\.id)
        XCTAssertEqual(ids.first, "pi")
        // pi may or may not be installed here; the known ones found are
        // exactly the two on the test PATH, in the table's order.
        XCTAssertEqual(ids.filter { $0 != "pi" && !$0.hasPrefix("custom.") }, ["opencode", "kimi"])

        let opencode = Agents.shared.choice("opencode")
        XCTAssertEqual(opencode?.name, "opencode")
        XCTAssertEqual(opencode?.path, folder.appendingPathComponent("opencode").path)
        XCTAssertEqual(opencode?.spec?.path, folder.appendingPathComponent("opencode").path)
        XCTAssertEqual(opencode?.spec?.arguments, ["acp"])
        XCTAssertEqual(opencode?.spec?.environment["OPENCODE_CLIENT"], "acp")
        XCTAssertEqual(opencode?.ownTools, .off)
        XCTAssertEqual(opencode?.login, ["opencode", "auth", "login"])

        // A known agent that isn't on the PATH isn't offered.
        XCTAssertNil(Agents.shared.choice("gemini"))
    }

    func testHiddenAgentsAreNotOffered() {
        Agents.shared.hide("kimi", true)
        XCTAssertFalse(Agents.shared.visible.contains { $0.id == "kimi" })
        XCTAssertTrue(Agents.shared.visible.contains { $0.id == "opencode" })
        XCTAssertTrue(Agents.shared.isHidden("kimi"))

        // pi is never hidden.
        Agents.shared.hide("pi", true)
        XCTAssertFalse(Agents.shared.isHidden("pi"))
        XCTAssertTrue(Agents.shared.visible.contains { $0.id == "pi" })

        Agents.shared.hide("kimi", false)
        XCTAssertTrue(Agents.shared.visible.contains { $0.id == "kimi" })
        XCTAssertFalse(Agents.shared.isHidden("kimi"))
    }

    // MARK: - the ones the person adds

    func testCustomAgents() async {
        // Words of a command line: plain, quoted, mixed, empty.
        XCTAssertEqual(Agents.words("opencode acp"), ["opencode", "acp"])
        XCTAssertEqual(Agents.words("\"/tmp/x y/agent\" --acp 'two words'"), ["/tmp/x y/agent", "--acp", "two words"])
        XCTAssertEqual(Agents.words(" a \"b c\"  d "), ["a", "b c", "d"])
        XCTAssertEqual(Agents.words("   "), [])

        guard let added = Agents.shared.add(name: "My agent", command: "\"/tmp/x y/agent\" --acp 'two words'") else {
            return XCTFail("the agent wasn't added")
        }
        XCTAssertTrue(added.custom)
        XCTAssertEqual(added.name, "My agent")
        XCTAssertEqual(added.path, "/tmp/x y/agent")
        XCTAssertEqual(added.spec?.path, "/tmp/x y/agent")
        XCTAssertEqual(added.spec?.arguments, ["--acp", "two words"])
        XCTAssertEqual(added.ownTools, .refused)
        XCTAssertNil(added.login)
        // Listed after the known ones.
        XCTAssertEqual(Agents.shared.all.last?.id, added.id)
        XCTAssertEqual(Agents.shared.visible.last?.id, added.id)

        // Written down: a new look reads it back.
        let fresh = Agents()
        await until(10) { fresh.looked }
        XCTAssertEqual(fresh.choice(added.id)?.name, "My agent")
        XCTAssertEqual(fresh.choice(added.id)?.spec?.path, "/tmp/x y/agent")
        XCTAssertEqual(fresh.choice(added.id)?.spec?.arguments, ["--acp", "two words"])

        Agents.shared.remove(added.id)
        XCTAssertNil(Agents.shared.choice(added.id))
        XCTAssertTrue(Agents.customEntries().isEmpty)

        // A command line with no words adds nothing.
        XCTAssertNil(Agents.shared.add(name: "Empty", command: "   "))
    }

    // MARK: - the chat's agent

    func testAChatKeepsItsAgent() async {
        let session = "/tmp/agents-test-\(UUID().uuidString).jsonl"
        let chat = Chat(title: "Test", session: session, agentID: "kimi", agentName: "Kimi")
        chats.append(chat)
        Chats.remember(chat)
        Disk.drain()

        let file = Chats.folder.appendingPathComponent("chats.json")
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return XCTFail("chats.json didn't read as a JSON array")
        }
        let entry = entries.first { $0["id"] as? String == chat.id.uuidString }
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?["agent"] as? String, "kimi")

        // One whose agent isn't here any more says so on its first message.
        let gone = Chat(title: "Test", agentID: "gone", agentName: "Gone")
        chats.append(gone)
        gone.send("hello")
        await until { !gone.busy }
        XCTAssertEqual(gone.items.last?.kind, .error)
        XCTAssertEqual(gone.items.last?.text, "Gone isn't on this Mac any more.")
    }

    func testUseOnlyBeforeTheFirstMessage() async {
        let script = ScriptedPi()
        let chat = Chat(title: "Test", agentID: "pi", agent: .pi(script.pi))
        chats.append(chat)
        XCTAssertEqual(chat.agentID, "pi")

        XCTAssertTrue(chat.use("kimi"))
        XCTAssertEqual(chat.agentID, "kimi")

        // A chat that has sent something has begun: its agent is fixed.
        let other = ScriptedPi()
        let begun = Chat(title: "Test", agent: .pi(other.pi))
        chats.append(begun)
        begun.send("hello")
        await until { other.sentTypes.contains("prompt") }
        XCTAssertFalse(begun.use("kimi"))
        XCTAssertEqual(begun.agentID, "pi")
    }
}
