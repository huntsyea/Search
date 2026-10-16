import Foundation
import XCTest
@testable import Search

/// How a program is held and let go of: its stdin written without blocking the
/// caller, and a dropped one reaped (LineProcess.swift).
@MainActor
final class LineProcessTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("line-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A program that never reads its stdin, with a pipe that soon fills: the
    /// writes wait on the process's own queue, not the caller's.
    func testSendDoesNotBlockOnAFullPipe() async throws {
        let child = try ChildProcess.spawn("/bin/sleep", ["30"], in: folder, environment: [:], bridge: false)
        let process = LineProcess()
        let ended = expectation(description: "it ended")
        process.onEnd = { _ in ended.fulfill() }
        process.start(child)

        let began = Date()
        for _ in 0..<20 {
            XCTAssertTrue(process.send(["line": String(repeating: "x", count: 64 * 1024)]))
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 1)

        process.stop(grace: 0.2)
        await fulfillment(of: [ended], timeout: 5)
    }

    /// A connection dropped before its program ended still reaps it: none of
    /// the pids is left behind, as a zombie would be.
    func testADroppedProcessIsReaped() async throws {
        var pids: [pid_t] = []
        for _ in 0..<20 {
            let child = try ChildProcess.spawn("/bin/sleep", ["30"], in: folder, environment: [:], bridge: false)
            pids.append(child.pid)
            drop(child)
        }
        try? await Task.sleep(for: .seconds(5))
        for pid in pids {
            XCTAssertNotEqual(kill(pid, 0), 0, "pid \(pid) is still there")
        }
    }

    /// A LineProcess made and dropped at once: its deinit signals the program
    /// and hands it to a background wait.
    private func drop(_ child: ChildProcess) {
        let process = LineProcess()
        process.start(child)
    }
}
