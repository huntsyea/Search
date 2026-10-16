import AppKit
import Darwin
import XCTest
@testable import Search

// The chat's lines, asked and stopped through its own interface (Chat.swift,
// ChatPanel.swift reads them): a scripted pi (ScriptedPi.swift) says exactly
// what a real one said (PiTranscripts.swift), and what the chat shows is
// checked without a provider.

@MainActor
final class ChatTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    override func tearDown() async throws {
        for chat in chats { Chats.delete(chat) }
        chats = []
        Chat.forget("data")
        try await super.tearDown()
    }

    /// Every chat a test makes, deleted when it is over.
    private var chats: [Chat] = []

    /// A chat on a scripted pi, and the script behind it.
    private func made(_ title: String = "Test") -> (chat: Chat, script: ScriptedPi) {
        let script = ScriptedPi()
        let chat = Chat(title: title, agent: .pi(script.pi))
        chats.append(chat)
        return (chat, script)
    }

    /// A chat that has been sent to and whose pi has its prompt.
    private func sent(_ title: String = "Test") async -> (chat: Chat, script: ScriptedPi) {
        let (chat, script) = made(title)
        chat.send("hello")
        await until { script.sentTypes.contains("prompt") }
        return (chat, script)
    }

    // MARK: - the lines

    func testToolTurnLines() async {
        let (chat, script) = await sent()
        script.replay(PiTranscripts.events(PiTranscripts.toolTurn))

        XCTAssertEqual(chat.items.map(\.kind),
                       [.user, .assistant, .tool, .thinking, .tool, .thinking, .assistant])

        // The person's message, without the <browser> note ahead of it.
        XCTAssertTrue(chat.items[0].text.hasPrefix("Call browser_tabs"))

        // "I'll check the tabs first."
        XCTAssertEqual(chat.items[1].kind, .assistant)
        XCTAssertEqual(chat.items[1].text, "I'll check the tabs first.")

        // browser_tabs: the step's label, then its summary.
        let tabs = chat.items[2]
        XCTAssertEqual(tabs.kind, .tool)
        XCTAssertEqual(tabs.text, "Looked at 1 tab")
        XCTAssertTrue(tabs.done)
        XCTAssertFalse(tabs.failed)

        // browser_open, refused: the label stays, and the reason is the detail.
        let open = chat.items[4]
        XCTAssertEqual(open.kind, .tool)
        XCTAssertTrue(open.failed)
        XCTAssertTrue(open.detail.hasPrefix("The person didn't allow that"))
        XCTAssertEqual(open.text, Chat.label("browser_open", ["url": "https://example.org"]))

        XCTAssertTrue(chat.items.allSatisfy(\.done))
        XCTAssertFalse(chat.busy)
    }

    func testAbortedTurnSaysStopped() async {
        let (chat, script) = await sent()
        script.replay(PiTranscripts.events(PiTranscripts.abortedTurn))

        XCTAssertEqual(chat.items.suffix(2).first?.kind, .assistant)
        XCTAssertEqual(chat.items.suffix(2).first?.text, "The lamp had")
        XCTAssertEqual(chat.items.last?.kind, .note)
        XCTAssertEqual(chat.items.last?.text, "Stopped.")
        XCTAssertFalse(chat.busy)
    }

    func testErrorStop() async {
        let (chat, script) = await sent()

        script.emit(["type": "message_start", "message": ["role": "assistant", "content": []]])
        script.emit(["type": "message_end",
                     "message": ["role": "assistant", "stopReason": "error", "errorMessage": "429 Too Many Requests"]])
        XCTAssertEqual(chat.items.last?.kind, .error)
        XCTAssertEqual(chat.items.last?.text, "429 Too Many Requests")

        script.emit(["type": "message_start", "message": ["role": "assistant", "content": []]])
        script.emit(["type": "message_end",
                     "message": ["role": "assistant", "stopReason": "error", "errorMessage": "Request was aborted"]])
        XCTAssertEqual(chat.items.last?.kind, .note)
        XCTAssertEqual(chat.items.last?.text, "Stopped.")
    }

    func testStreamingLinesAreNotDoneUntilTheyEnd() async throws {
        let (chat, script) = await sent()
        let events = PiTranscripts.events(PiTranscripts.toolTurn)
        let end = try XCTUnwrap(events.firstIndex {
            $0["type"] as? String == "message_update"
                && ($0["assistantMessageEvent"] as? [String: Any])?["type"] as? String == "text_end"
        })

        script.replay(Array(events[..<end]))
        let streaming = chat.items.first { $0.kind == .assistant }
        XCTAssertEqual(streaming?.text, "I'll check the tabs first.")
        XCTAssertEqual(streaming?.done, false)

        script.replay(Array(events[end...]))
        let finished = chat.items.first { $0.kind == .assistant }
        XCTAssertEqual(finished?.text, "I'll check the tabs first.")
        XCTAssertEqual(finished?.done, true)
    }

    // MARK: - status and name

    func testRetryShowsInStatus() async {
        let (chat, script) = await sent()
        script.emit(["type": "auto_retry_start"])
        XCTAssertEqual(chat.status, "Retrying…")
        script.emit(["type": "auto_retry_end"])
        XCTAssertNil(chat.status)
    }

    func testRenameFromPi() async {
        let (chat, script) = await sent("New chat")
        script.emit(["type": "session_info_changed", "name": "Lighthouse"])
        XCTAssertEqual(chat.title, "Lighthouse")
    }

    // MARK: - asks, pause, stop, and the tabs acted on

    /// Browsers made by `busyChat`, held for the test so the chat's weak
    /// `browser` stays alive even when a test doesn't bind the returned one.
    private var browsers: [Browser] = []

    /// A chat in `browser`, with a message sent so pi is running and the chat
    /// busy, ready to take tool calls.
    private func busyChat(_ script: ScriptedPi, mode: Chat.Mode = .ask) async -> (Chat, Browser) {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        let chat = Chat(title: "Test", mode: mode, agent: .pi(script.pi))
        chats.append(chat)
        chat.open(in: browser)
        chat.send("go")
        await until { script.sentTypes.contains("prompt") }
        return (chat, browser)
    }

    /// The text of a tool reply's first content block.
    private func replyText(_ reply: [String: Any]) -> String {
        ((reply["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    /// The tab a call opened, given the ids that were there before it.
    private func openedTab(_ browser: Browser, notIn before: Set<Tab.ID>) -> Tab? {
        browser.tabs.first { !before.contains($0.id) }
    }

    func testDenyRefusesTheStep() async {
        let script = ScriptedPi()
        let (chat, browser) = await busyChat(script)
        let before = browser.tabs.count

        let task = script.call("browser_open", ["url": "data:text/html,one"])
        await until { chat.asking.count == 1 }
        XCTAssertEqual(chat.asking.first?.site, "data")
        XCTAssertEqual(browser.tabs.count, before)

        chat.answer(.deny)
        guard let r = await reply(task) else { return }
        XCTAssertEqual(r["isError"] as? Bool, true)
        XCTAssertTrue(replyText(r).hasPrefix("The person didn't allow that"))
        XCTAssertTrue(chat.asking.isEmpty)
        XCTAssertEqual(browser.tabs.count, before)
        XCTAssertFalse(chat.acting)
    }

    func testOnceActsAndMarksTheTab() async {
        let script = ScriptedPi()
        let (chat, browser) = await busyChat(script)
        let before = Set(browser.tabs.map(\.id))

        let task = script.call("browser_open", ["url": "data:text/html,one"])
        await until { chat.asking.count == 1 }
        chat.answer(.once)
        guard let r = await reply(task) else { return }
        XCTAssertNotEqual(r["isError"] as? Bool, true)
        let tab = openedTab(browser, notIn: before)
        XCTAssertNotNil(tab)
        XCTAssertEqual(tab?.pageAddress?.absoluteString, "data:text/html,one")
        XCTAssertEqual(tab?.agent, true)
        XCTAssertTrue(chat.acting)

        script.emit(["type": "agent_settled"])
        XCTAssertEqual(tab?.agent, false)
        XCTAssertFalse(chat.acting)
        XCTAssertFalse(chat.busy)

        // Answered `.once`, a second open of the same site asks again.
        let again = script.call("browser_open", ["url": "data:text/html,two"])
        await until { chat.asking.count == 1 }
        chat.answer(.deny)
        _ = await reply(again)
    }

    func testChatWideAnswersTheSameSiteTogether() async {
        let script = ScriptedPi()
        let (chat, _) = await busyChat(script)

        let first = script.call("browser_open", ["url": "data:text/html,one"])
        let second = script.call("browser_open", ["url": "data:text/html,two"])
        await until { chat.asking.count == 2 }

        chat.answer(.chat)
        guard let one = await reply(first), let two = await reply(second) else { return }
        XCTAssertNotEqual(one["isError"] as? Bool, true)
        XCTAssertNotEqual(two["isError"] as? Bool, true)

        // One answer for the chat covers the site: a third call doesn't ask.
        let third = script.call("browser_open", ["url": "data:text/html,three"])
        guard let _ = await reply(third) else { return }
        XCTAssertTrue(chat.asking.isEmpty)
    }

    func testAlwaysIsKeptAcrossChats() async {
        let script = ScriptedPi()
        let (chat, _) = await busyChat(script)

        let task = script.call("browser_open", ["url": "data:text/html,one"])
        await until { chat.asking.count == 1 }
        chat.answer(.always)
        _ = await reply(task)
        XCTAssertTrue(Chat.alwaysSites.contains("data"))

        // A new chat, with its own pi, doesn't ask for the site again.
        let other = ScriptedPi()
        let (fresh, _) = await busyChat(other)
        let again = other.call("browser_open", ["url": "data:text/html,two"])
        guard let _ = await reply(again) else { return }
        XCTAssertTrue(fresh.asking.isEmpty)

        Chat.forget("data")
    }

    func testActModeDoesNotAsk() async {
        let script = ScriptedPi()
        let (chat, browser) = await busyChat(script, mode: .act)
        let before = browser.tabs.count

        let task = script.call("browser_open", ["url": "data:text/html,one"])
        guard let r = await reply(task) else { return }
        XCTAssertNotEqual(r["isError"] as? Bool, true)
        XCTAssertTrue(chat.asking.isEmpty)
        XCTAssertEqual(browser.tabs.count, before + 1)
    }

    func testPauseHoldsTheNextStep() async {
        let script = ScriptedPi()
        let (chat, _) = await busyChat(script)

        chat.pause()
        XCTAssertTrue(chat.paused)

        let task = script.call("browser_tabs")
        var finished = false
        var reply: [String: Any] = [:]
        Task { reply = await task.value; finished = true }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(finished)

        chat.resume()
        await until { finished }
        XCTAssertNotEqual(reply["isError"] as? Bool, true)
    }

    func testStopRefusesWhatWaitsAndAbortsPi() async {
        let script = ScriptedPi()
        let (chat, _) = await busyChat(script)

        let open = script.call("browser_open", ["url": "data:text/html,one"])
        await until { chat.asking.count == 1 }

        chat.pause()
        let tabs = script.call("browser_tabs")
        // The paused step has reached its wait.
        await until { chat.waitingSteps == 1 }

        chat.stop()

        guard let openReply = await reply(open) else { return }
        XCTAssertEqual(openReply["isError"] as? Bool, true)
        XCTAssertTrue(replyText(openReply).hasPrefix("The person didn't allow that"))
        guard let tabsReply = await reply(tabs) else { return }
        XCTAssertEqual(tabsReply["isError"] as? Bool, true)
        XCTAssertEqual(replyText(tabsReply), "Stopped.")
        XCTAssertTrue(chat.asking.isEmpty)
        XCTAssertFalse(chat.paused)
        await until { script.sentTypes.contains("abort") }
    }

    func testCancelDropsTheAsk() async {
        let script = ScriptedPi()
        let (chat, _) = await busyChat(script)

        let task = script.call("browser_open", ["url": "data:text/html,one"])
        await until { chat.asking.count == 1 }

        script.cancel()
        guard let r = await reply(task) else { return }
        XCTAssertEqual(r["isError"] as? Bool, true)
        XCTAssertTrue(replyText(r).hasPrefix("The person didn't allow that"))
        XCTAssertTrue(chat.asking.isEmpty)
    }

    func testCloseAsksAboutTheTab() async {
        let script = ScriptedPi()
        let (chat, browser) = await busyChat(script)
        let before = Set(browser.tabs.map(\.id))

        let open = script.call("browser_open", ["url": "data:text/html,one"])
        await until { chat.asking.count == 1 }
        chat.answer(.once)
        _ = await reply(open)
        guard let tab = openedTab(browser, notIn: before) else {
            return XCTFail("no tab was opened")
        }

        let close = script.call("browser_close", ["tab": AgentTools.short(tab)])
        await until { chat.asking.count == 1 }
        XCTAssertEqual(chat.asking.first?.action.hasPrefix("close"), true)
        chat.answer(.once)
        _ = await reply(close)
        XCTAssertFalse(browser.tabs.contains { $0.id == tab.id })
    }

    func testSettleDropsWaitingAsks() async {
        let script = ScriptedPi()
        let (chat, _) = await busyChat(script)

        let task = script.call("browser_open", ["url": "data:text/html,one"])
        await until { chat.asking.count == 1 }

        script.emit(["type": "agent_settled"])
        guard let r = await reply(task) else { return }
        XCTAssertEqual(r["isError"] as? Bool, true)
        XCTAssertTrue(replyText(r).hasPrefix("The person didn't allow that"))
        XCTAssertFalse(chat.busy)
    }

    // MARK: - sessions, names, models, and pi ending

    func testFirstMessageLearnsTheSessionAndListsTheChat() async {
        let (chat, script) = made()
        let session = "/tmp/chat-test-\(UUID().uuidString).jsonl"
        script.answers["get_state"] = ["sessionFile": session]

        chat.send("hello")
        await until { chat.session == session }

        // prompt, then get_state, then set_session_name. learnModels' own
        // commands may come before or between them.
        let types = script.sentTypes
        guard let prompt = types.firstIndex(of: "prompt"),
              let state = types[prompt...].firstIndex(of: "get_state"),
              let named = types[state...].firstIndex(of: "set_session_name") else {
            return XCTFail("prompt, get_state and set_session_name weren't all sent in order: \(types)")
        }
        XCTAssertEqual(script.sent[named]["name"] as? String, "Test")

        XCTAssertTrue(Chats.all.first === chat)

        Disk.drain()
        let file = Chats.folder.appendingPathComponent("chats.json")
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return XCTFail("chats.json didn't read as a JSON array")
        }
        let entry = entries.first { $0["id"] as? String == chat.id.uuidString }
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?["session"] as? String, session)
    }

    func testNewChatIsNamedByPi() async {
        let (chat, script) = made("New chat")
        script.titled = "Lighthouse story"
        script.answers["get_state"] = ["sessionFile": "/tmp/chat-test-\(UUID().uuidString).jsonl"]

        chat.send("write me a story about a lighthouse")
        await until { chat.title == "Lighthouse story" }
        await until {
            script.sent.contains {
                $0["type"] as? String == "set_session_name" && $0["name"] as? String == "Lighthouse story"
            }
        }
    }

    func testNoTitleKeepsTheMessageStart() async {
        let (chat, script) = made("New chat")
        script.titled = nil

        let message = String(repeating: "a", count: 70)
        chat.send(message)
        await until { script.sentTypes.contains("prompt") }
        XCTAssertEqual(chat.title, String(message.prefix(60)))
    }

    func testReopenedChatShowsItsMessages() async {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: path.path, contents: Data())

        let script = ScriptedPi()
        script.answers["get_messages"] = PiTranscripts.messagesData
        let chat = Chat(title: "Test", session: path.path, agent: .pi(script.pi))
        chats.append(chat)
        defer { try? FileManager.default.removeItem(at: path) }

        chat.open(in: browser)
        await until { chat.status == nil && !chat.items.isEmpty }

        XCTAssertEqual(script.starts, [path.path])
        XCTAssertEqual(chat.items.map(\.kind),
                       [.user, .assistant, .tool, .thinking, .tool, .thinking, .assistant, .user, .thinking, .assistant, .note])
        XCTAssertEqual(chat.items.last?.text, "Stopped.")
        XCTAssertEqual(chat.items[2].text, "Looked at 1 tab")
        XCTAssertTrue(chat.items[4].failed)
        XCTAssertTrue(chat.items[4].detail.hasPrefix("The person didn't allow that"))
        XCTAssertTrue(chat.items[0].text.hasPrefix("Call browser_tabs"))

        // Opened again, the messages already shown aren't asked for a second time.
        let asked = script.sentTypes.filter { $0 == "get_messages" }.count
        chat.open(in: browser)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(script.sentTypes.filter { $0 == "get_messages" }.count, asked)
    }

    func testReopenedChatShowsWhatTheLiveOneShowed() async {
        let (live, liveScript) = await sent()
        liveScript.replay(PiTranscripts.events(PiTranscripts.toolTurn))
        liveScript.replay(PiTranscripts.events(PiTranscripts.abortedTurn))

        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: path.path, contents: Data())

        let script = ScriptedPi()
        script.answers["get_messages"] = PiTranscripts.messagesData
        let reopened = Chat(title: "Test", session: path.path, agent: .pi(script.pi))
        chats.append(reopened)
        defer { try? FileManager.default.removeItem(at: path) }

        reopened.open(in: browser)
        await until { reopened.status == nil && !reopened.items.isEmpty }

        func lines(_ chat: Chat) -> [String] {
            chat.items.map { "\($0.kind)|\($0.text)|\($0.failed)|\($0.detail)" }
        }
        XCTAssertEqual(lines(live), lines(reopened))
    }

    func testGoneSessionFileStartsANewOne() async {
        let script = ScriptedPi()
        let chat = Chat(title: "Test", session: "/tmp/gone-\(UUID().uuidString).jsonl", agent: .pi(script.pi))
        chats.append(chat)

        chat.send("hello")
        await until { script.starts.count == 1 }
        XCTAssertEqual(script.starts, [nil])
    }

    func testPiEndingMidTurn() async {
        let (chat, script) = await sent()

        script.exit("out of memory")
        XCTAssertFalse(chat.busy)
        XCTAssertEqual(chat.items.last?.kind, .error)
        XCTAssertEqual(chat.items.last?.text, "pi stopped: out of memory")
        XCTAssertNil(chat.status)

        // A pi that ended is replaced by a new one on the next send.
        chat.send("again")
        await until { script.starts.count == 2 }
    }

    func testPiEndingWhileStarting() async {
        let (chat, script) = made()
        script.exitWhileStarting = .some("no provider")

        chat.send("hello")
        await until { !chat.busy }
        let errors = chat.items.filter { $0.kind == .error }
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.last?.text, "pi stopped: no provider")
        XCTAssertEqual(chat.items.last?.kind, .error)

        // The next send starts a second pi, and that one's link is used.
        script.exitWhileStarting = nil
        chat.send("again")
        await until { script.starts.count == 2 }
        await until { script.sentTypes.contains("prompt") }
        // The first start died before its prompt; the second one's link is used.
        XCTAssertEqual(script.sentTypes.filter { $0 == "prompt" }.count, 1)
    }

    func testStartFailureIsALine() async {
        let (chat, script) = made()
        script.startFailure = "pi isn't installed"

        chat.send("hello")
        await until { !chat.busy }
        XCTAssertEqual(chat.items.last?.kind, .error)
        XCTAssertEqual(chat.items.last?.text, "pi isn't installed")
    }

    func testModelsAndThinking() async {
        let (chat, script) = made()
        script.answers["get_available_models"] = ["models": [
            ["provider": "p", "id": "a", "name": "A", "reasoning": true],
            ["provider": "p", "id": "b", "name": "B"],
        ]]
        script.answers["get_state"] = ["model": ["provider": "p", "id": "a"], "thinkingLevel": "low"]
        script.answers["get_available_thinking_levels"] = ["levels": ["off", "low", "high"]]

        chat.loadOptions()
        await until { chat.option("model")?.choices.count == 2 && chat.option("model")?.current == "p/a" && chat.option("thinking")?.choices.count == 3 }
        XCTAssertEqual(chat.option("model")?.current, "p/a")
        XCTAssertEqual(chat.option("thinking")?.current, "low")
        XCTAssertEqual(chat.option("thinking")?.choices.map(\.value), ["off", "low", "high"])
        XCTAssertEqual(chat.option("model")?.choices.map(\.group), ["p", "p"])
        // Loading models quietly says no "Starting pi…".
        XCTAssertNil(chat.status)

        chat.choose("model", "p/b")
        await until { script.sentTypes.contains("set_model") }
        let chosen = script.sent.first { $0["type"] as? String == "set_model" }
        XCTAssertEqual(chosen?["provider"] as? String, "p")
        XCTAssertEqual(chosen?["modelId"] as? String, "b")

        chat.choose("thinking", "high")
        await until { script.sentTypes.contains("set_thinking_level") }
        let level = script.sent.first { $0["type"] as? String == "set_thinking_level" }
        XCTAssertEqual(level?["level"] as? String, "high")
    }

    func testThinkingIsOfferedOnlyForAModelThatReasons() async {
        let (chat, script) = made()
        script.answers["get_available_models"] = ["models": [
            ["provider": "p", "id": "a", "name": "A", "reasoning": true],
            ["provider": "p", "id": "b", "name": "B"],
        ]]
        script.answers["get_state"] = ["model": ["provider": "p", "id": "b"], "thinkingLevel": "low"]
        script.answers["get_available_thinking_levels"] = ["levels": ["off", "low", "high"]]

        chat.loadOptions()
        await until { chat.option("model")?.current == "p/b" }
        XCTAssertNil(chat.option("thinking"))
    }

    func testAPiStartedAgainOnANewSessionKeepsTheEarlierAnswer() async {
        let (chat, script) = made()
        chat.send("hello")
        await until { script.sentTypes.contains("prompt") }

        script.replay([
            ["type": "message_start", "message": ["role": "assistant", "content": []]],
            ["type": "message_update", "assistantMessageEvent": ["type": "text_delta", "contentIndex": 0, "delta": "first"]],
            ["type": "message_update", "assistantMessageEvent": ["type": "text_end", "contentIndex": 0, "content": "first"]],
            ["type": "message_end", "message": ["role": "assistant", "content": [], "stopReason": "stop"]],
            ["type": "agent_settled"],
        ])
        script.exit(nil)

        // A second pi on a new session: its message count starts at 0 again,
        // so its own items must not land where the first pi's did.
        chat.send("again")
        await until { script.starts.count == 2 && script.sentTypes.filter { $0 == "prompt" }.count == 2 }
        script.replay([
            ["type": "message_start", "message": ["role": "assistant", "content": []]],
            ["type": "message_update", "assistantMessageEvent": ["type": "text_delta", "contentIndex": 0, "delta": "second"]],
            ["type": "message_update", "assistantMessageEvent": ["type": "text_end", "contentIndex": 0, "content": "second"]],
            ["type": "message_end", "message": ["role": "assistant", "content": [], "stopReason": "stop"]],
            ["type": "agent_settled"],
        ])

        XCTAssertEqual(chat.items.filter { $0.kind == .assistant }.map(\.text), ["first", "second"])
    }

    func testChoosingAModelBeforeTheListCameStillSetsIt() async {
        let (chat, script) = made()
        script.answers["get_available_models"] = ["models": []]

        chat.choose("model", "p/x")
        await until { script.sentTypes.contains("set_model") }
        let chosen = script.sent.first { $0["type"] as? String == "set_model" }
        XCTAssertEqual(chosen?["provider"] as? String, "p")
        XCTAssertEqual(chosen?["modelId"] as? String, "x")
    }

    func testAFailedStateKeepsTheModel() async {
        let (chat, script) = made()
        script.answers["get_available_models"] = ["models": [
            ["provider": "p", "id": "a", "name": "A", "reasoning": true],
            ["provider": "p", "id": "b", "name": "B"],
        ]]
        script.answers["get_state"] = ["model": ["provider": "p", "id": "a"], "thinkingLevel": "low"]
        script.answers["get_available_thinking_levels"] = ["levels": ["off", "low", "high"]]

        chat.loadOptions()
        await until { chat.option("model")?.current == "p/a" }

        script.refusals["get_state"] = "busy"
        chat.choose("thinking", "high")
        await until { script.sentTypes.contains("set_thinking_level") }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(chat.option("model")?.current, "p/a")
    }

    func testAFailedReopenShowsNoHalfHistory() async {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: path.path, contents: Data())

        let script = ScriptedPi()
        script.refusals["get_messages"] = "broken"
        let chat = Chat(title: "Test", session: path.path, agent: .pi(script.pi))
        chats.append(chat)
        defer { try? FileManager.default.removeItem(at: path) }

        chat.open(in: browser)
        await until { chat.status == nil }
        XCTAssertTrue(chat.items.allSatisfy { $0.kind != .user })
        XCTAssertEqual(chat.items.last?.kind, .error)
        XCTAssertEqual(chat.items.last?.text, "broken")

        // The refusal cleared, the start's history comes whole: the half that
        // failed is gone, and the session's two user messages are shown.
        script.refusals["get_messages"] = nil
        script.answers["get_messages"] = PiTranscripts.messagesData
        chat.send("again")
        await until { script.starts.count == 2 }
        XCTAssertEqual(chat.items.filter { $0.kind == .user }.count, 2)
    }

    func testRefusedCommandIsALine() async {
        let (chat, script) = made()
        script.refusals["prompt"] = "model not found"

        chat.send("hello")
        await until { !chat.busy }
        XCTAssertEqual(chat.items.last?.kind, .error)
        XCTAssertEqual(chat.items.last?.text, "model not found")
    }

    // MARK: - the scripted pi alone

    func testScriptedPiFinishesUndeliverableCalls() async {
        // No start, so no link: the call is answered at once, not left hanging.
        let script = ScriptedPi()
        let task = script.call("browser_tabs")
        guard let r = await reply(task) else { return }
        XCTAssertEqual(r["isError"] as? Bool, true)
        XCTAssertEqual(replyText(r), "pi isn't running")
    }

    func testOldPiCannotAct() async {
        let script = ScriptedPi()
        let (chat, browser) = await busyChat(script)
        let before = browser.tabs.count

        // Settle the turn so the chat is free to start another pi.
        script.emit(["type": "agent_settled"])
        chat.close()
        chat.send("again")
        await until { script.starts.count == 2 }

        // The first link's pi had not died yet: its call arrives, and is refused.
        let task = script.call("browser_open", ["url": "data:text/html,one"], on: 0)
        guard let r = await reply(task) else { return }
        XCTAssertEqual(r["isError"] as? Bool, true)
        XCTAssertEqual(replyText(r), "Stopped.")
        XCTAssertTrue(chat.asking.isEmpty)
        XCTAssertEqual(browser.tabs.count, before)
        XCTAssertFalse(chat.acting)
    }

    func testClosingABusyChatSettlesIt() async {
        let script = ScriptedPi()
        let (chat, browser) = await busyChat(script)
        let before = Set(browser.tabs.map(\.id))

        let open = script.call("browser_open", ["url": "data:text/html,one"])
        await until { chat.asking.count == 1 }
        chat.answer(.once)
        _ = await reply(open)
        guard let tab = openedTab(browser, notIn: before) else {
            return XCTFail("no tab was opened")
        }
        XCTAssertEqual(tab.agent, true)

        let second = script.call("browser_open", ["url": "data:text/html,two"])
        await until { chat.asking.count == 1 }

        chat.pause()
        let tabs = script.call("browser_tabs")
        await until { chat.waitingSteps == 1 }

        chat.close()

        XCTAssertFalse(chat.busy)
        XCTAssertFalse(chat.acting)
        XCTAssertFalse(chat.paused)
        XCTAssertTrue(chat.asking.isEmpty)
        XCTAssertEqual(tab.agent, false)
        guard let refused = await reply(second) else { return }
        XCTAssertEqual(refused["isError"] as? Bool, true)
        XCTAssertTrue(replyText(refused).hasPrefix("The person didn't allow that"))
        guard let held = await reply(tabs) else { return }
        XCTAssertEqual(held["isError"] as? Bool, true)
        XCTAssertEqual(replyText(held), "Stopped.")
        XCTAssertEqual(script.stops, 1)
        XCTAssertFalse(chat.items.contains { $0.kind == .error })
    }

    func testCloseStopsPi() async {
        // Closing a busy chat stops its pi, and letting go before stopping
        // means the exit isn't heard as pi ending on its own: no "pi stopped." line.
        let (busy, busyScript) = await sent()
        busy.close()
        XCTAssertEqual(busyScript.stops, 1)
        XCTAssertFalse(busy.busy)
        XCTAssertFalse(busy.items.contains { $0.kind == .error })

        busy.send("again")
        await until { busyScript.starts.count == 2 }

        // A chat that is done and let go of starts a fresh pi on the next send.
        let (chat, script) = made()
        chat.send("hello")
        await until { script.sentTypes.contains("prompt") }
        script.emit(["type": "agent_settled"])
        XCTAssertFalse(chat.busy)
        chat.close()
        XCTAssertEqual(script.stops, 1)
        chat.send("again")
        await until { script.starts.count == 2 }
    }
}
