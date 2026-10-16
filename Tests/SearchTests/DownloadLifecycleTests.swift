import AppKit
import Darwin
import Foundation
import SwiftUI
import WebKit
import XCTest
@testable import Search

private typealias BrowserTab = Search.Tab

@MainActor
final class DownloadLifecycleTests: XCTestCase {
    private var browser: Browser!
    private var fixture: LocalDownloadServer!
    private var downloadFolder: URL!
    private var window: NSWindow!
    private var page: BrowserTab?

    override class func setUp() {
        // Browser settings, history, WebKit data, and files live in this
        // process-specific test world, never in the user's Search profile.
        TestWorld.enter()
        super.setUp()
    }

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        fixture = try LocalDownloadServer()
        browser = Browser(record: WindowRecord())
        browser.history.forget()
        browser.loot.forgetAll()

        downloadFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Search-download-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)
        browser.prefs.downloads = downloadFolder
        browser.prefs.asksWhereToSave = false

        window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 700, height: 680),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        browser.window = window
    }

    override func tearDown() async throws {
        try? nothingShown()
        if let browser {
            for entry in browser.fetches.entries { browser.cancelDownload(entry) }
            try? await waitUntil {
                browser.fetches.entries.isEmpty && browser.downloading.isEmpty
            }
            if let page { browser.close(page) }
            browser.loot.forgetAll()
            browser.history.forget()
        }
        fixture?.stop()
        try? nothingShown()
        window?.orderOut(nil)
        window?.close()
        if let downloadFolder { try? FileManager.default.removeItem(at: downloadFolder) }
        try await super.tearDown()
    }

    func testWebKitFailureWithResumeDataResumesSameEntryAndDestination() async throws {
        let tab = try await openFixturePage()
        let entry = try await startDownload("/failure.bin", in: tab)
        try await waitUntil { entry.state == .failed }

        let originalID = entry.id
        let reason = try XCTUnwrap(entry.errorDescription)
        let destination = try XCTUnwrap(entry.destination)
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(entry.canResume, "WebKit should return resume data for the ranged fixture")
        XCTAssertTrue(entry.canRetry)

        if let snapshotPath = ProcessInfo.processInfo.environment["SEARCH_DOWNLOAD_SNAPSHOT"], !snapshotPath.isEmpty {
            let paused = try await startDownload("/range.bin", in: tab)
            try await waitUntil { paused.completedBytes >= 64 * 1024 && paused.destination != nil }
            browser.pauseDownload(paused)
            try await waitUntil { paused.state == .paused }
            XCTAssertTrue(paused.canResume)
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(paused.destination).path))

            let active = try await startDownload("/range.bin", in: tab)
            try await waitUntil { active.completedBytes >= 32 * 1024 }
            try writePanelSnapshot(to: URL(fileURLWithPath: snapshotPath))
        }

        browser.resumeDownload(entry)
        // A repeated click while WebKit is creating the resumed download must
        // not start a second attempt or replace the row.
        browser.resumeDownload(entry)
        try await waitUntil { entry.state == .downloading }
        XCTAssertEqual(entry.id, originalID)
        XCTAssertEqual(entry.destination, destination)

        try await waitUntil {
            browser.loot.kept.contains { $0.path == destination.path }
        }
        XCTAssertFalse(browser.fetches.entries.contains { $0.id == originalID })
        XCTAssertEqual(try Data(contentsOf: destination), fixture.expectedBytes())
        XCTAssertTrue(fixture.ranges("/failure.bin").contains { Self.rangeOffset($0) > 0 })
        XCTAssertTrue(fixture.cookies("/failure.bin").allSatisfy { $0?.contains("download-session=fixture-cookie") == true })
    }

    func testPauseResumeKeepsBytesAndDestination() async throws {
        let tab = try await openFixturePage()
        let entry = try await startDownload("/range.bin", in: tab)
        try await waitUntil { entry.completedBytes >= 64 * 1024 && entry.destination != nil }

        let originalID = entry.id
        let destination = try XCTUnwrap(entry.destination)
        browser.pauseDownload(entry)
        // The second request arrives while the first cancellation is pending.
        // It must not ask WebKit to stop twice.
        browser.pauseDownload(entry)
        try await waitUntil { entry.state == .paused }
        let pausedBytes = entry.completedBytes
        XCTAssertTrue(entry.canResume)
        XCTAssertEqual(entry.id, originalID)
        XCTAssertEqual(entry.destination, destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        browser.resumeDownload(entry)
        browser.resumeDownload(entry)
        try await waitUntil { entry.state == .downloading }
        // The row, the ring and Finder's bar go on from what had come in,
        // not from nothing: the first measure after the resume already
        // counts the bytes on disk.
        var ring: Double?
        let watching = browser.fetches.$fraction.sink { if let value = $0, ring == nil { ring = value } }
        try await waitUntil { entry.completedBytes > 0 && ring != nil || browser.loot.kept.contains { $0.path == destination.path } }
        watching.cancel()
        XCTAssertGreaterThanOrEqual(entry.completedBytes, pausedBytes, "the row started over after the resume")
        if let ring, entry.totalBytes > 0 {
            XCTAssertGreaterThanOrEqual(ring, Double(pausedBytes) / Double(entry.totalBytes) - 0.02, "the ring started over after the resume")
        }
        XCTAssertEqual(entry.id, originalID)
        XCTAssertEqual(entry.destination, destination)
        try await waitUntil { browser.loot.kept.contains { $0.path == destination.path } }

        XCTAssertFalse(browser.fetches.entries.contains { $0.id == originalID })
        XCTAssertEqual(try Data(contentsOf: destination), fixture.expectedBytes())
        XCTAssertTrue(fixture.ranges("/range.bin").contains { Self.rangeOffset($0) > 0 })
        XCTAssertTrue(fixture.cookies("/range.bin").allSatisfy { $0?.contains("download-session=fixture-cookie") == true })
    }

    func testFailureWithoutResumeDataKeepsReasonAndCanRetryFromStart() async throws {
        let tab = try await openFixturePage()
        let entry = try await startDownload("/retry.bin", in: tab)
        try await waitUntil { entry.state == .failed }

        let originalID = entry.id
        let reason = try XCTUnwrap(entry.errorDescription)
        XCTAssertFalse(reason.isEmpty)
        XCTAssertFalse(entry.canResume)
        XCTAssertTrue(entry.canRetry)

        browser.retryDownload(entry)
        XCTAssertEqual(entry.id, originalID)
        try await waitUntil { entry.state == .downloading }
        XCTAssertNil(entry.errorDescription)
        try await waitUntil { browser.loot.kept.contains { $0.name.hasPrefix("fixture") } }

        let keep = try XCTUnwrap(browser.loot.kept.first { $0.name.hasPrefix("fixture") })
        XCTAssertEqual(try Data(contentsOf: keep.url), fixture.expectedBytes())
        XCTAssertEqual(fixture.count("/retry.bin"), 2)
        XCTAssertTrue(fixture.ranges("/retry.bin").allSatisfy { $0 == nil })
        XCTAssertTrue(fixture.cookies("/retry.bin").allSatisfy { $0?.contains("download-session=fixture-cookie") == true })
    }

    func testDeletedSpaceTakesItsRunningDownloadWithIt() async throws {
        let tab = try await openFixturePage()
        let entry = try await startDownload("/cancel.bin", in: tab)
        try await waitUntil { entry.completedBytes >= 64 * 1024 && entry.destination != nil }
        let destination = try XCTUnwrap(entry.destination)
        let store = try XCTUnwrap(entry.store)
        let id = entry.id

        browser.forgetDownloads(of: store)
        try await waitUntil {
            !browser.fetches.entries.contains { $0.id == id } && browser.downloading.isEmpty
        }

        XCTAssertNil(entry.store, "a forgotten store is still kept by its row")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCancelRemovesEntryAndPartialFile() async throws {
        let tab = try await openFixturePage()
        let entry = try await startDownload("/cancel.bin", in: tab)
        try await waitUntil { entry.completedBytes >= 64 * 1024 && entry.destination != nil }
        let destination = try XCTUnwrap(entry.destination)
        let id = entry.id

        browser.cancelDownload(entry)
        browser.cancelDownload(entry)
        try await waitUntil {
            !browser.fetches.entries.contains { $0.id == id } && browser.downloading.isEmpty
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(browser.loot.kept.isEmpty)
    }

    func testRemovingPausedDownloadPreservesAReplacementFile() async throws {
        let tab = try await openFixturePage()
        let entry = try await startDownload("/range.bin", in: tab)
        try await waitUntil { entry.completedBytes >= 64 * 1024 && entry.destination != nil }
        let destination = try XCTUnwrap(entry.destination)

        browser.pauseDownload(entry)
        try await waitUntil { entry.state == .paused }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        let replacement = Data("a file placed here after the pause".utf8)
        try replacement.write(to: destination, options: .atomic)
        browser.cancelDownload(entry)
        try await waitUntil { !browser.fetches.entries.contains { $0.id == entry.id } }

        XCTAssertEqual(try Data(contentsOf: destination), replacement)
    }

    func testPrivateDownloadNeverEntersSharedEntriesHistoryOrCompletedList() async throws {
        let privateSource = Tab(shy: true)
        let tab = browser.open(URL(string: "about:blank")!, foreground: true, from: privateSource)
        page = tab
        window.contentView = tab.web
        tab.go(to: fixture.url("/page"))
        try await waitUntil { tab.committed == fixture.url("/page") && !tab.loading }
        try await waitUntil { fixture.completed("/page") == 1 }

        _ = await keptDownload("/private.bin", from: tab.web)
        XCTAssertTrue(browser.fetches.entries.isEmpty)

        try await waitUntil {
            fixture.completed("/private.bin") == 1 && browser.downloading.isEmpty
        }
        XCTAssertTrue(browser.fetches.entries.isEmpty)
        XCTAssertTrue(browser.loot.kept.isEmpty)
        XCTAssertFalse(browser.history.everything(matching: "127.0.0.1").contains { $0.url == fixture.url("/page") })
        XCTAssertTrue(fixture.cookies("/private.bin").contains { $0?.contains("download-session=fixture-cookie") == true })
    }

    /// A download started in code is kept before WebKit can ask where it goes,
    /// however long the main thread is busy after asking for it. Holding the
    /// main thread puts WebKit's handler and its question in line together; a
    /// download kept one hop after the handler would be asked about first, with
    /// no delegate, and cancelled.
    func testADownloadStartedInCodeIsKeptBeforeWebKitAsks() async throws {
        let tab = try await openFixturePage()
        var started: WKDownload?
        browser.download(URLRequest(url: fixture.url("/range.bin")), through: tab.web) { started = $0 }
        // The main thread busy while WebKit answers: both of its calls wait behind this.
        Thread.sleep(forTimeInterval: 1.5)
        try await waitUntil { started != nil }
        let download = try XCTUnwrap(started)
        try await waitUntil { browser.fetches.entry(for: download) != nil }
        let entry = try XCTUnwrap(browser.fetches.entry(for: download))
        try await waitUntil { entry.completedBytes > 0 || entry.state != .downloading }
        XCTAssertNotEqual(entry.state, .failed, "WebKit gave up on it: \(downloadsNow())")
        XCTAssertGreaterThan(entry.completedBytes, 0, downloadsNow())
        browser.cancelDownload(entry)
    }

    private func openFixturePage() async throws -> BrowserTab {
        let tab = browser.open(URL(string: "about:blank")!, foreground: true)
        page = tab
        window.contentView = tab.web
        tab.go(to: fixture.url("/page"))
        try await waitUntil { tab.committed == fixture.url("/page") && !tab.loading }
        try await waitUntil { fixture.completed("/page") == 1 }
        return tab
    }

    private func startDownload(_ path: String, in tab: BrowserTab) async throws -> FetchEntry {
        let download = await keptDownload(path, from: tab.web)
        return try XCTUnwrap(browser.fetches.entry(for: download))
    }

    /// Kept inside WebKit's handler, so the download's delegate is there before
    /// WebKit asks where the file goes. Kept one main-actor hop later, a busy
    /// machine let WebKit ask first, find no delegate, and cancel.
    private func keptDownload(_ path: String, from webView: WKWebView) async -> WKDownload {
        let request = URLRequest(url: fixture.url(path))
        return await withCheckedContinuation { continuation in
            webView.startDownload(using: request) { download in
                MainActor.assumeIsolated { self.browser.keep(download, from: webView) }
                continuation.resume(returning: download)
            }
        }
    }

    private func writePanelSnapshot(to destination: URL) throws {
        let host = NSHostingView(rootView: DownloadsPanel(browser: browser, loot: browser.loot))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 680)
        let snapshotWindow = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 560, height: 680),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        snapshotWindow.isReleasedWhenClosed = false
        snapshotWindow.contentView = host
        snapshotWindow.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw SnapshotError.couldNotRender
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.couldNotEncode
        }
        try data.write(to: destination, options: .atomic)
        snapshotWindow.close()
    }

    /// These tests never put a window in, nor bring the app forward: one
    /// that did would be on someone's screen. It fails the test, and
    /// everything is put away at once.
    private func nothingShown(file: StaticString = #filePath, line: UInt = #line) throws {
        let shown = NSApp.windows.filter(\.isVisible)
        guard !shown.isEmpty || NSApp.isActive else { return }
        for window in NSApp.windows { window.orderOut(nil); window.close() }
        NSApp.hide(nil)
        XCTFail("a window was shown or the app came forward: \(shown)", file: file, line: line)
        throw WaitError.timedOut
    }

    /// Waits on the downloads, not on a clock: it gives up when nothing about
    /// them has changed for `idle` seconds — the shape of a real hang — or
    /// after two minutes in all. A busy machine makes a download slow, not
    /// still, so a download that is still moving is never mistaken for a stuck
    /// one.
    private func waitUntil(
        idle: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let start = Date()
        let cap = start.addingTimeInterval(120)
        var last = downloadsNow()
        var quietSince = Date()
        while Date().timeIntervalSince(quietSince) < idle && Date() < cap {
            try nothingShown(file: file, line: line)
            if condition() { return }
            let now = downloadsNow()
            if now != last {
                last = now
                quietSince = Date()
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if condition() { return }   // woken late with it already true: not a timeout
        let message = Date() >= cap
            ? "Still not there after 120 s waiting for the download state: \(downloadsNow())"
            : "Nothing moved for \(Int(idle)) s waiting for the download state: \(downloadsNow())"
        XCTFail(message, file: file, line: line)
        throw WaitError.timedOut
    }

    /// What every download row and WebKit download was doing at a timeout, so
    /// a real failure isn't a mystery.
    private func downloadsNow() -> String {
        let entries = browser.fetches.entries.map { entry in
            "\(entry.state) \(entry.completedBytes)/\(entry.totalBytes)\(entry.errorDescription.map { " (\($0))" } ?? "")"
        }
        return "entries: \(entries); downloading: \(browser.downloading.count); kept: \(browser.loot.kept.map(\.name))"
    }

    private static func rangeOffset(_ header: String?) -> Int {
        guard let header, let equals = header.firstIndex(of: "="), let dash = header.firstIndex(of: "-") else { return 0 }
        return Int(header[header.index(after: equals)..<dash]) ?? 0
    }

    private enum WaitError: Error { case timedOut }
    private enum SnapshotError: Error { case couldNotRender, couldNotEncode }
}
