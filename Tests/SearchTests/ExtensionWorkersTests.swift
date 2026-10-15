import AppKit
import WebKit
import XCTest
@testable import Search

/// Whether an extension's worker runs, and bringing back the ones WebKit
/// left dead. The kept-registration failure is WebKit's own and happens in
/// its default store, so every harness here is one launch of the browser on
/// that store; a test's launches share a fresh host so no other test's
/// registrations are in the way.
@available(macOS 15.4, *)
@MainActor
final class ExtensionWorkersTests: XCTestCase {
    private var folder: URL!
    private var harnesses: [WorkerHarness] = []

    override class func setUp() {
        setenv("SEARCH_PROBE", "extension-workers-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        folder = FileManager.default.temporaryDirectory.appendingPathComponent("worker-ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"manifest_version": 3, "name": "Worker test", "version": "1.0", "description": "A made-up extension with a worker, for Search's tests.", "background": {"service_worker": "worker.js"}}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "self.started = Date.now();\nchrome.runtime.onMessage.addListener((message, sender, respond) => { respond(\"pong \" + self.started); });\n"
            .write(to: folder.appendingPathComponent("worker.js"), atomically: true, encoding: .utf8)
        try "<!doctype html><p>page</p>"
            .write(to: folder.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        try ExtensionShims.prepare(folder, fresh: true)
    }

    override func tearDown() async throws {
        // This launch's extensions go first, so the next test's clearing and
        // relaunches don't reach into them.
        harnesses.forEach { $0.close() }
        harnesses = []
        try? await Task.sleep(for: .milliseconds(500))
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: - helpers

    /// A harness for one launch, kept so the test's launches are closed
    /// together in `tearDown`.
    private func launch(patience: Duration = .seconds(3), reviveEvery: TimeInterval = 60, networkProcess: (() -> pid_t)? = nil) -> WorkerHarness {
        let harness = WorkerHarness(folder: folder, patience: patience, reviveEvery: reviveEvery, networkProcess: networkProcess)
        harnesses.append(harness)
        return harness
    }

    /// Stands for quitting and opening Search: WebKit's network process
    /// starts afresh and the registrations it kept are still there.
    private func relaunch() async {
        _ = WKWebsiteDataStore.default().perform(NSSelectorFromString("_terminateNetworkProcess"))
        try? await Task.sleep(for: .milliseconds(500))
    }

    private func eventually(within seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// A host of its own for each test: lowercase letters, so the extension's
    /// origin can't be confused with another test's.
    private func freshHost() -> String {
        let letters = String(UUID().uuidString.prefix(8).lowercased().filter(\.isLetter))
        return ("w" + letters).padding(toLength: 8, withPad: "x", startingAt: 0)
    }

    // MARK: - tests

    func testAWorkerKeptFromTheLastLaunchIsRevived() async throws {
        let host = freshHost()

        let first = launch()
        await first.workers.forgetKept()
        let firstContext = try await first.load(host)
        let firstAnswer = try await first.ask(host)
        XCTAssertTrue(firstAnswer.hasPrefix("pong"), firstAnswer)
        try? first.controller.unload(firstContext)
        first.workers.unloaded(host)

        await relaunch()

        let second = launch()
        _ = try await second.load(host)
        let dead = try await second.ask(host)
        // Within one process WebKit now and then starts the kept worker after all;
        // then there is nothing dead to bring back, and this run proves nothing.
        if dead.hasPrefix("pong") { throw XCTSkip("WebKit started the kept worker this time") }
        XCTAssertEqual(dead, "undefined", "a kept registration's worker answered neither nothing nor pong")
        let didRevive = await eventually(within: 10) { second.revives.count == 1 }
        XCTAssertTrue(didRevive, "revived: \(second.revives)")
        XCTAssertEqual(second.revives.first?.reason, "its worker didn't start", "revived: \(second.revives)")
        let revived = try await second.ask(host)
        XCTAssertTrue(revived.hasPrefix("pong"), revived)
    }

    func testForgettingAtLaunchLeavesNothingToRevive() async throws {
        let host = freshHost()

        let first = launch()
        await first.workers.forgetKept()
        let firstContext = try await first.load(host)
        let firstAnswer = try await first.ask(host)
        XCTAssertTrue(firstAnswer.hasPrefix("pong"), firstAnswer)
        try? first.controller.unload(firstContext)
        first.workers.unloaded(host)

        await relaunch()

        let second = launch()
        await second.workers.forgetKept()
        _ = try await second.load(host)
        let answer = try await second.ask(host)
        XCTAssertTrue(answer.hasPrefix("pong"), answer)
        try? await Task.sleep(for: .seconds(4))
        XCTAssertTrue(second.revives.isEmpty, "revived: \(second.revives)")
    }

    func testWebKitsNetworkProcessStartingAgainRevivesWorkers() async throws {
        let host = freshHost()

        let harness = launch()
        await harness.workers.forgetKept()
        _ = try await harness.load(host)
        let answer = try await harness.ask(host)
        XCTAssertTrue(answer.hasPrefix("pong"), answer)

        await relaunch()

        let didRevive = await eventually(within: 10) { harness.revives.count == 1 }
        XCTAssertTrue(didRevive, "revived: \(harness.revives)")
        // When the network process starts again with a worker running, WebKit
        // may also report backgroundContentFailedToLoad on the context. Either
        // sign leads to the one revive, and both are right.
        XCTAssertTrue(["WebKit's network process started again", "its worker failed to start"].contains(harness.revives.first?.reason ?? ""), "revived: \(harness.revives)")
        let revived = try await harness.ask(host)
        XCTAssertTrue(revived.hasPrefix("pong"), revived)
    }

    func testAWorkerThatStartsIsLeftAlone() async throws {
        let host = freshHost()

        let harness = launch()
        await harness.workers.forgetKept()
        _ = try await harness.load(host)
        let answer = try await harness.ask(host)
        XCTAssertTrue(answer.hasPrefix("pong"), answer)

        try? await Task.sleep(for: .seconds(4))
        XCTAssertTrue(harness.revives.isEmpty, "revived: \(harness.revives)")
    }

    func testLoadedBeforeIsTheSecondLoadOfARun() async throws {
        let host = freshHost()

        let harness = launch()
        await harness.workers.forgetKept()
        let first = try await harness.load(host)
        XCTAssertFalse(harness.workers.loadedBefore(host))

        try? harness.controller.unload(first)
        harness.workers.unloaded(host)
        let second = try await harness.load(host)
        XCTAssertTrue(harness.workers.loadedBefore(host))

        try? harness.controller.unload(second)
        harness.workers.unloaded(host, removed: true)
        _ = try await harness.load(host)
        XCTAssertFalse(harness.workers.loadedBefore(host))
    }

    func testTheNetworkProcessWatchAloneRevives() async throws {
        let host = freshHost()
        var pid: pid_t = 100

        let harness = launch(patience: .seconds(60), networkProcess: { pid })
        await harness.workers.forgetKept()
        _ = try await harness.load(host)
        let answer = try await harness.ask(host)
        XCTAssertTrue(answer.hasPrefix("pong"), answer)

        pid = 200
        let didRevive = await eventually(within: 5) { harness.revives.count == 1 }
        XCTAssertTrue(didRevive, "revived: \(harness.revives)")
        XCTAssertEqual(harness.revives.first?.reason, "WebKit's network process started again", "revived: \(harness.revives)")
        let revived = try await harness.ask(host)
        XCTAssertTrue(revived.hasPrefix("pong"), revived)
    }

    func testANetworkRestartWithinTheMinuteIsDeferredNotLost() async throws {
        let host = freshHost()
        var pid: pid_t = 100

        let harness = launch(patience: .seconds(60), reviveEvery: 3, networkProcess: { pid })
        await harness.workers.forgetKept()
        _ = try await harness.load(host)
        let answer = try await harness.ask(host)
        XCTAssertTrue(answer.hasPrefix("pong"), answer)

        pid = 200
        let first = await eventually(within: 5) { harness.revives.count == 1 }
        XCTAssertTrue(first, "revived: \(harness.revives)")

        pid = 300
        let tooSoon = await eventually(within: 1) { harness.revives.count == 2 }
        XCTAssertFalse(tooSoon, "revived: \(harness.revives)")

        // Generous: on a busy Mac the wait for the minute, here three seconds, can run long.
        let later = await eventually(within: 20) { harness.revives.count == 2 }
        XCTAssertTrue(later, "revived: \(harness.revives)")
        XCTAssertEqual(harness.revives.last?.reason, "WebKit's network process started again", "revived: \(harness.revives)")
        let revived = try await harness.ask(host)
        XCTAssertTrue(revived.hasPrefix("pong"), revived)
    }

    func testAnExtensionThatCantStartIsGivenUpOn() async throws {
        let host = freshHost()

        let harness = launch(reviveEvery: 4)
        harness.silent.insert(host)
        await harness.workers.forgetKept()
        _ = try await harness.load(host)

        let didRevive = await eventually(within: 6) { harness.revives.count == 1 }
        XCTAssertTrue(didRevive, "revived: \(harness.revives)")
        XCTAssertEqual(harness.revives.first?.reason, "its worker didn't start", "revived: \(harness.revives)")

        try? await Task.sleep(for: .seconds(4 + 3 + 2))
        XCTAssertEqual(harness.revives.count, 1, "revived: \(harness.revives)")
    }

    func testEveryExtensionWithAWorkerIsRevived() async throws {
        let hostA = freshHost()
        let hostB = freshHost()

        let harness = launch()
        await harness.workers.forgetKept()
        _ = try await harness.load(hostA)
        _ = try await harness.load(hostB)
        let answerA = try await harness.ask(hostA)
        XCTAssertTrue(answerA.hasPrefix("pong"), answerA)
        let answerB = try await harness.ask(hostB)
        XCTAssertTrue(answerB.hasPrefix("pong"), answerB)

        await relaunch()

        let didRevive = await eventually(within: 10) { harness.revives.count == 1 }
        XCTAssertTrue(didRevive, "revived: \(harness.revives)")
        XCTAssertEqual(Set(harness.revives.first?.ids ?? []), Set([hostA, hostB]), "revived: \(harness.revives)")
        let revivedA = try await harness.ask(hostA)
        XCTAssertTrue(revivedA.hasPrefix("pong"), revivedA)
        let revivedB = try await harness.ask(hostB)
        XCTAssertTrue(revivedB.hasPrefix("pong"), revivedB)
    }

    // WebKit keeps in memory what an extension loaded, by address, and the
    // addresses don't change with its files, so without `ExtensionFiles.replace`
    // dropping that memory, a reloaded extension ran its old scripts.
    func testReplacingAnExtensionsFilesRunsTheNewScripts() async throws {
        try "window.pageVersion = \"v1\";\n"
            .write(to: folder.appendingPathComponent("page.js"), atomically: true, encoding: .utf8)
        try "<!doctype html><p>page</p><script src=\"page.js\"></script>"
            .write(to: folder.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        try ExtensionShims.prepare(folder, fresh: true)

        let harness = launch()
        await harness.workers.forgetKept()
        let host = freshHost()
        let first = try await harness.load(host)

        let firstPong = try await harness.ask(host)
        XCTAssertTrue(firstPong.hasPrefix("pong"), firstPong)
        let firstVersion = try await harness.evaluate(host, "return String(window.pageVersion)")
        XCTAssertEqual(firstVersion, "v1", firstVersion)

        let staged = folder.deletingLastPathComponent().appendingPathComponent("staged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: folder, to: staged)
        try "self.started = Date.now();\nchrome.runtime.onMessage.addListener((message, sender, respond) => { respond(\"v2 \" + self.started); });\n"
            .write(to: staged.appendingPathComponent("worker.js"), atomically: true, encoding: .utf8)
        try "window.pageVersion = \"v2\";\n"
            .write(to: staged.appendingPathComponent("page.js"), atomically: true, encoding: .utf8)
        try ExtensionShims.prepare(staged, fresh: true)

        try await ExtensionFiles.replace(staged, at: folder, in: .default())
        defer { try? FileManager.default.removeItem(at: staged) }

        try? harness.controller.unload(first)
        harness.workers.unloaded(host)
        _ = try await harness.load(host)

        let secondPong = try await harness.ask(host)
        XCTAssertTrue(secondPong.hasPrefix("v2"), secondPong)
        let secondVersion = try await harness.evaluate(host, "return String(window.pageVersion)")
        XCTAssertEqual(secondVersion, "v2", secondVersion)
    }
}

/// One launch of the browser: a controller on WebKit's default store, an
/// `ExtensionWorkers` reloading through it, and a delegate that answers the
/// shim the way the app's own does.
@available(macOS 15.4, *)
@MainActor
private final class WorkerHarness: NSObject, WKWebExtensionControllerDelegate, WKNavigationDelegate {
    let folder: URL
    let controller: WKWebExtensionController
    let patience: Duration
    let reviveEvery: TimeInterval
    let networkProcess: (() -> pid_t)?
    /// The `(ids, reason)` of each revive, in order.
    var revives: [(ids: [String], reason: String)] = []
    var contexts: [String: WKWebExtensionContext] = [:]
    /// Hosts whose worker never says it started — a worker that can't start.
    var silent: Set<String> = []

    private var pages: [WKWebView] = []
    private var waiting: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]
    private var finished: Set<ObjectIdentifier> = []
    private var lastNavigationError: Error?
    /// WebKit suspends a page that is in no window; an extension's pages live
    /// in one in the app, so its page is put in one here too. Not shown.
    private var window: NSWindow?

    init(folder: URL, patience: Duration = .seconds(3), reviveEvery: TimeInterval = 60, networkProcess: (() -> pid_t)? = nil) {
        self.folder = folder
        self.patience = patience
        self.reviveEvery = reviveEvery
        self.networkProcess = networkProcess
        let configuration = WKWebExtensionController.Configuration.default()
        configuration.defaultWebsiteDataStore = .default()
        let views = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        views.preferences.inactiveSchedulingPolicy = .none
        views.websiteDataStore = .default()
        configuration.webViewConfiguration = views
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
    }

    lazy var workers: ExtensionWorkers = ExtensionWorkers(
        store: .default(),
        patience: patience,
        watch: .milliseconds(500),
        reviveEvery: reviveEvery,
        networkProcess: networkProcess
    ) { [weak self] ids, reason in
        guard let self else { return }
        self.revives.append((ids, reason))
        for id in ids {
            guard let context = self.contexts[id] else { continue }
            try? self.controller.unload(context)
            self.workers.unloaded(id)
            _ = try? await self.load(id)
        }
    }

    @discardableResult
    func load(_ host: String) async throws -> WKWebExtensionContext {
        let found = try await WKWebExtension(resourceBaseURL: folder)
        let context = WKWebExtensionContext(for: found)
        context.uniqueIdentifier = host
        context.baseURL = URL(string: "webkit-extension://\(host)/")!
        for permission in context.webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
        try controller.load(context)
        workers.loaded(context)
        contexts[host] = context
        return context
    }

    /// A test's launch ends with its extensions unloaded, so the next test's
    /// clearing and relaunches don't reach into it.
    func close() {
        for (id, context) in contexts {
            try? controller.unload(context)
            workers.unloaded(id)
        }
        contexts = [:]
        for view in pages { view.removeFromSuperview() }
        pages = []
        window?.orderOut(nil)
    }

    /// A message sent in the moment a worker starts can be answered with
    /// nothing before its listener is there, so one empty answer doesn't say
    /// the worker is dead; one that answers nothing three times running is.
    func ask(_ host: String) async throws -> String {
        let context = try XCTUnwrap(contexts[host])
        let view = try await openPage(context)
        // WebKit's own sendMessage, past the shim's, so the page's own worker
        // check plays no part.
        let script = """
        return await Promise.race([Object.getPrototypeOf(chrome.runtime).sendMessage.call(chrome.runtime, { hi: 1 }).then(String, (e) => "error " + e), new Promise((w) => setTimeout(() => w("late"), 5000))])
        """
        var answer = "undefined"
        for attempt in 0..<3 {
            let result = try await view.callAsyncJavaScript(script, in: nil, contentWorld: .page)
            answer = result as? String ?? String(describing: result)
            if answer != "undefined", answer != "late" { return answer }
            if attempt < 2 { try await Task.sleep(for: .milliseconds(500)) }
        }
        return answer
    }

    /// Runs `script` in a fresh page of the extension (`page.html`) and gives
    /// back what it returned, as a string.
    func evaluate(_ host: String, _ script: String) async throws -> String {
        let context = try XCTUnwrap(contexts[host])
        let view = try await openPage(context)
        let result = try await view.callAsyncJavaScript(script, in: nil, contentWorld: .page)
        return result as? String ?? String(describing: result)
    }

    /// Opens `page.html` in a fresh page of the extension, ready for a script.
    private func openPage(_ context: WKWebExtensionContext) async throws -> WKWebView {
        let view = try makePage(context)
        await waitForPage(view, url: try XCTUnwrap(context.baseURL).appendingPathComponent("page.html"))
        XCTAssertTrue(finished.contains(ObjectIdentifier(view)), "the extension's page didn't load: \(String(describing: view.url)) \(String(describing: lastNavigationError))")
        return view
    }

    private func makePage(_ context: WKWebExtensionContext) throws -> WKWebView {
        let configuration = try XCTUnwrap(context.webViewConfiguration)
        let view = WKWebView(frame: .init(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
        if window == nil {
            let made = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
            made.isReleasedWhenClosed = false
            window = made
        }
        window?.contentView?.addSubview(view)
        pages.append(view)
        view.navigationDelegate = self
        return view
    }

    private func waitForPage(_ view: WKWebView, url: URL) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiting[ObjectIdentifier(view)] = continuation
            view.load(URLRequest(url: url))
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.waiting.removeValue(forKey: ObjectIdentifier(view))?.resume()
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished.insert(ObjectIdentifier(webView))
        waiting.removeValue(forKey: ObjectIdentifier(webView))?.resume()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        lastNavigationError = error
        waiting.removeValue(forKey: ObjectIdentifier(webView))?.resume()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        lastNavigationError = error
        waiting.removeValue(forKey: ObjectIdentifier(webView))?.resume()
    }

    // Plays the part `ExtensionShims.answer` plays in the app.
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext) async throws -> Any? {
        if (message as? [String: Any])?["api"] as? String == "background.started",
           !silent.contains(extensionContext.uniqueIdentifier) {
            workers.started(extensionContext.uniqueIdentifier)
        }
        return ["value": NSNull()]
    }
}
