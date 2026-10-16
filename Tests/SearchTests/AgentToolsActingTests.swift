import AppKit
import Darwin
import WebKit
import XCTest
@testable import Search

private typealias BrowserTab = Search.Tab

/// The catalogue's rules for acting, through the call the chat makes: every
/// act is asked about before anything is done, a refusal leaves everything
/// as it was, and reading or showing never asks.
@MainActor
final class AgentToolsActingTests: XCTestCase {
    private var browser: Browser!
    private var fixture: LocalDownloadServer!
    private var window: NSWindow!
    private var chat: Chat!
    private var page: BrowserTab!

    override class func setUp() {
        // A test world of its own, never the person's profile.
        TestWorld.enter()
        super.setUp()
    }

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        fixture = try LocalDownloadServer()
        browser = Browser(record: WindowRecord())

        window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 700, height: 680),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        browser.window = window

        chat = Chat()
        chat.browser = browser
        chat.mode = .ask

        page = browser.open(URL(string: "about:blank")!, foreground: true)
        window.contentView = page.web
        page.go(to: fixture.url("/page"))
        try await waitUntil { page.built?.url?.path == "/page" && !page.loading }

        // Controls in the page's own world for the acting tools to reach.
        _ = try await page.web.evaluateJavaScript("""
            document.body.innerHTML = '<button onclick="document.body.dataset.clicked = 1">Sign in</button>'
              + '<input aria-label="Name">';
            document.addEventListener("keydown", (e) => { document.body.dataset.pressed = e.key; });
            window.__before = 1;
            true
        """)
    }

    override func tearDown() async throws {
        try? nothingShown()
        if let browser {
            for tab in browser.tabs { browser.close(tab) }
        }
        fixture?.stop()
        window?.orderOut(nil)
        window?.close()
        try await super.tearDown()
    }

    // MARK: - the tests

    func testEveryActingToolAsksFirstAndARefusalChangesNothing() async throws {
        let short = AgentTools.short(page)
        let (button, field) = try await refs()
        let tabCount = browser.tabs.count

        struct Entry {
            let args: [String: Any]
            let asks: String
            let notHappened: @MainActor () async throws -> Bool
        }

        let table: [String: Entry] = [
            "browser_open": Entry(
                args: ["url": fixture.url("/page").absoluteString],
                asks: "open 127.0.0.1",
                notHappened: { self.browser.tabs.count == tabCount }),
            "browser_navigate": Entry(
                args: ["tab": short, "url": fixture.url("/page").absoluteString],
                asks: "go to 127.0.0.1",
                notHappened: {
                    let value = try await self.inPage("window.__before")
                    return (value as? NSNumber)?.intValue == 1
                }),
            "browser_close": Entry(
                args: ["tab": short],
                asks: "close “\(page!.label)”",
                notHappened: { self.browser.tabs.contains { $0 === self.page } }),
            "browser_click": Entry(
                args: ["tab": short, "ref": button],
                asks: "click “Sign in” on 127.0.0.1",
                notHappened: {
                    self.isMissing(try await self.inPage("document.body.dataset.clicked ?? null"))
                }),
            "browser_type": Entry(
                args: ["tab": short, "ref": field, "text": "Ada"],
                asks: "type into “Name” on 127.0.0.1",
                notHappened: {
                    (try await self.inPage("document.querySelector('input').value") as? String) == ""
                }),
            "browser_press": Entry(
                args: ["tab": short, "key": "Enter"],
                asks: "press Enter on 127.0.0.1",
                notHappened: {
                    self.isMissing(try await self.inPage("document.body.dataset.pressed ?? null"))
                }),
        ]

        // A new acting tool can't be added without this test knowing.
        XCTAssertEqual(Set(table.keys), Set(AgentTools.tools.filter { $0.kind == .acts }.map(\.name)))

        for (name, entry) in table {
            let pending = start(name, entry.args)
            try await waitUntil { chat.asking.count == 1 }
            XCTAssertEqual(chat.asking.first?.action, entry.asks, name)
            let beforeActed = try await entry.notHappened()
            XCTAssertTrue(beforeActed, "\(name) acted before it was allowed")
            XCTAssertNil(pending.answer, name)
            XCTAssertFalse(page.agent, name)

            chat.answer(.deny)
            let refusal = try await answer(pending)
            XCTAssertTrue(isError(refusal), name)
            XCTAssertTrue(text(refusal).contains("didn't allow"), name)
            let afterRefused = try await entry.notHappened()
            XCTAssertTrue(afterRefused, "\(name) acted after it was refused")
            XCTAssertFalse(page.agent, name)
            XCTAssertTrue(chat.asking.isEmpty, name)
        }
    }

    func testAnAllowedActIsDoneAndItsTabMarked() async throws {
        let short = AgentTools.short(page)
        let (button, field) = try await refs()

        let clicked = start("browser_click", ["tab": short, "ref": button])
        try await waitUntil { chat.asking.count == 1 }
        chat.answer(.once)
        let clickAnswer = try await answer(clicked)
        XCTAssertFalse(isError(clickAnswer))
        XCTAssertEqual((clickAnswer["details"] as? [String: Any])?["summary"] as? String, "Clicked “Sign in”")
        let clickedValue = try await inPage("document.body.dataset.clicked") as? String
        XCTAssertEqual(clickedValue, "1")
        XCTAssertTrue(page.agent)

        let typed = start("browser_type", ["tab": short, "ref": field, "text": "Ada"])
        try await waitUntil { chat.asking.count == 1 }
        chat.answer(.once)
        let typeAnswer = try await answer(typed)
        XCTAssertFalse(isError(typeAnswer))
        let typedValue = try await inPage("document.querySelector('input').value") as? String
        XCTAssertEqual(typedValue, "Ada")
    }

    func testATabTheAgentOpensIsMarkedAndGathered() async throws {
        browser.prefs.usesTabGroups = true
        chat.mode = .act

        let pending = start("browser_open", ["url": fixture.url("/page").absoluteString])
        XCTAssertTrue(chat.asking.isEmpty)
        let openedAnswer = try await answer(pending)
        XCTAssertFalse(isError(openedAnswer))
        XCTAssertTrue(chat.asking.isEmpty)

        let opened = try XCTUnwrap(browser.tabs.first { $0 !== page })
        XCTAssertTrue(opened.agent)
        XCTAssertNotNil(browser.group(of: opened))
        XCTAssertTrue(browser.tabGroups.contains { $0.id == browser.group(of: opened) })
        XCTAssertFalse(page.agent)
    }

    func testATabAClickOpensIsMarkedAndGathered() async throws {
        browser.prefs.usesTabGroups = true
        chat.mode = .ask
        let short = AgentTools.short(page)

        _ = try await inPage(#"document.body.insertAdjacentHTML("beforeend", '<a href="' + location.href + '" target="_blank">Elsewhere</a>'); true"#)

        let listing = start("browser_find", ["tab": short])
        let body = text(try await answer(listing))
        let link = try XCTUnwrap(body.split(separator: "\n").first { $0.contains("link \"Elsewhere\"") }
            .map { String($0.prefix(while: { $0 != " " })) })

        let tabCount = browser.tabs.count

        let denied = start("browser_click", ["tab": short, "ref": link])
        try await waitUntil { chat.asking.count == 1 }
        XCTAssertEqual(chat.asking.first?.action, "click “Elsewhere” on 127.0.0.1")
        XCTAssertEqual(browser.tabs.count, tabCount)
        chat.answer(.deny)
        _ = try await answer(denied)
        XCTAssertEqual(browser.tabs.count, tabCount)
        XCTAssertFalse(browser.tabs.contains { $0.agent })

        let allowed = start("browser_click", ["tab": short, "ref": link])
        try await waitUntil { chat.asking.count == 1 }
        chat.answer(.once)
        let openedAnswer = try await answer(allowed)
        XCTAssertFalse(isError(openedAnswer))
        XCTAssertTrue(chat.asking.isEmpty)

        let opened = try XCTUnwrap(browser.tabs.first { $0 !== page })
        XCTAssertEqual(browser.tabs.count, tabCount + 1)
        XCTAssertTrue(opened.agent)
        XCTAssertTrue(page.agent)
        XCTAssertNotNil(browser.group(of: opened))
        XCTAssertTrue(browser.tabGroups.contains { $0.id == browser.group(of: opened) })
    }

    func testReadingAndShowingNeverAsk() async throws {
        chat.mode = .ask
        let short = AgentTools.short(page)

        for tool in AgentTools.tools where tool.kind == .reads || tool.kind == .shows {
            let pending = start(tool.name, ["tab": short])
            _ = try await answer(pending)
            XCTAssertTrue(chat.asking.isEmpty, tool.name)
            XCTAssertFalse(page.agent, tool.name)
        }
    }

    func testBadInputIsRefusedWithoutAsking() async throws {
        chat.mode = .ask
        let short = AgentTools.short(page)

        let bad: [(name: String, args: [String: Any], text: String?)] = [
            ("browser_click", ["tab": short, "ref": "e999"], nil),
            ("browser_type", ["tab": short], nil),
            ("browser_press", ["tab": short], nil),
            ("browser_navigate", ["tab": short, "action": "sideways"], "The action is back, forward or reload."),
            ("browser_close", ["tab": "ffffffff"], "There's no tab [ffffffff]"),
        ]

        for entry in bad {
            let pending = start(entry.name, entry.args)
            let refusal = try await answer(pending)
            XCTAssertTrue(isError(refusal), entry.name)
            if let expected = entry.text {
                if entry.name == "browser_close" {
                    XCTAssertTrue(text(refusal).hasPrefix(expected), entry.name)
                } else {
                    XCTAssertEqual(text(refusal), expected, entry.name)
                }
            }
            XCTAssertTrue(chat.asking.isEmpty, entry.name)
            XCTAssertFalse(page.agent, entry.name)
        }
    }

    func testACallGivenUpWhilePausedDoesNotAct() async throws {
        // A chat that is busy, so Pause can hold: the catalogue's rules are
        // the test's here, not the agent's.
        let script = ScriptedPi()
        chat = Chat(title: "Test", mode: .ask, agent: .pi(script.pi))
        chat.open(in: browser)
        chat.send("go")
        await until { script.sentTypes.contains("prompt") }
        XCTAssertTrue(chat.busy)
        defer { Chats.delete(chat) }

        chat.pause()
        XCTAssertTrue(chat.paused)

        let before = browser.tabs.count
        let pending = Pending()
        AgentTools.run(["name": "browser_open", "args": ["url": fixture.url("/page").absoluteString]],
                       for: chat, givenUp: { pending.givenUp }) { pending.answer = $0 }
        await until { chat.waitingSteps == 1 }

        // The agent gives the call up — its connection closed, say — while
        // it is held, then the person resumes the chat.
        pending.givenUp = true
        chat.resume()

        let refused = try await answer(pending)
        XCTAssertTrue(isError(refused))
        XCTAssertEqual(text(refused), "Stopped.")
        XCTAssertEqual(browser.tabs.count, before)
    }

    // MARK: - helpers

    /// A call made through the catalogue, as the chat makes it; its answer
    /// arrives later. `givenUp` is the test's to set while it runs.
    final class Pending {
        var answer: [String: Any]?
        var givenUp = false
    }

    private func start(_ name: String, _ args: [String: Any] = [:]) -> Pending {
        let pending = Pending()
        AgentTools.run(["name": name, "args": args], for: chat) { pending.answer = $0 }
        return pending
    }

    /// The call's answer, once it has come.
    private func answer(_ pending: Pending) async throws -> [String: Any] {
        try await waitUntil { pending.answer != nil }
        return try XCTUnwrap(pending.answer)
    }

    /// The "text" of the first content block.
    private func text(_ answer: [String: Any]) -> String {
        (answer["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    }

    private func isError(_ answer: [String: Any]) -> Bool {
        answer["isError"] as? Bool == true
    }

    private func isMissing(_ value: Any?) -> Bool {
        guard let value else { return true }
        return value is NSNull
    }

    private func waitUntil(timeout: TimeInterval = 15, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try nothingShown()
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if condition() { return }   // woken late with it already true: not a timeout
        XCTFail("Timed out waiting for the agent tools")
        throw WaitError.timedOut
    }

    private func inPage(_ script: String) async throws -> Any? {
        try await page.web.evaluateJavaScript(script)
    }

    /// The references browser_find gives the button and the field, through
    /// the catalogue.
    private func refs() async throws -> (button: String, field: String) {
        let pending = start("browser_find", ["tab": AgentTools.short(page)])
        let listing = try await answer(pending)
        let body = text(listing)
        func reference(_ line: Substring) -> String { String(line.prefix(while: { $0 != " " })) }
        let button = try XCTUnwrap(body.split(separator: "\n").first { $0.contains("button \"Sign in\"") }.map(reference))
        let field = try XCTUnwrap(body.split(separator: "\n").first { $0.contains("textbox \"Name\"") }.map(reference))
        return (button, field)
    }

    /// These tests never put a window in, nor bring the app forward: one
    /// that did would be on someone's screen. It fails the test.
    private func nothingShown(file: StaticString = #filePath, line: UInt = #line) throws {
        let shown = NSApp.windows.filter(\.isVisible)
        guard !shown.isEmpty || NSApp.isActive else { return }
        for window in NSApp.windows { window.orderOut(nil); window.close() }
        NSApp.hide(nil)
        XCTFail("a window was shown or the app came forward: \(shown)", file: file, line: line)
        throw WaitError.timedOut
    }

    private enum WaitError: Error { case timedOut }
}
