import Darwin
import Foundation
import XCTest
@testable import Search

/// The test world a run of the tests lives in: one per test process,
/// "tests-<pid>", entered by every test class that reaches Store before
/// anything does. Store fixes its world, folder and settings at the first
/// touch, so one world per process is what there is; this names it
/// honestly and takes it away once, when the last test has run — not
/// class by class, while later classes still write to it.
enum TestWorld {
    /// Every test world a run has ever named itself, each with the pid of
    /// the run that made it: the process-wide world this file introduces,
    /// and the per-class worlds the test classes used to ask for.
    ///
    /// - `tests`: the one world a run lives in now, named after this file.
    /// - `download-ui`: DownloadLifecycleTests' downloads world.
    /// - `agent-tools`: AgentToolsActingTests' world.
    /// - `chat`: ChatTests' world.
    /// - `sec-file-access`: ExtensionFileAccessTests' world.
    /// - `sec-download-page`: ExtensionDownloadPageTests' world.
    /// - `popup-windows`: ExtensionPopupWindowTests' world.
    /// - `extension-workers`: ExtensionWorkersTests' world.
    /// - `find-stage`: FindStageTests' world.
    ///
    /// Nothing else is swept: a named world without a pid (`arch4`,
    /// `sidebar`, `aieval`…) is deliberate, and `import-tests-…` is a
    /// unique name a test makes for itself.
    private static let staleWorld = try! NSRegularExpression(
        pattern: "^(tests|download-ui|agent-tools|chat|sec-file-access|sec-download-page|popup-windows|extension-workers|find-stage)-([0-9]+)$"
    )

    /// Whether a world's name is one a run gave itself, with the pid of the
    /// run that made it.
    private static func stale(_ world: String) -> Bool {
        let range = NSRange(world.startIndex..., in: world)
        return staleWorld.firstMatch(in: world, range: range) != nil
    }

    nonisolated(unsafe) private static var entered = false

    /// Enter the run's test world. This must be called from `class func
    /// setUp()`, before anything else touches Store: Store.world,
    /// Store.folder and Store.settings are `static let`, fixed by the first
    /// access in the process, so a world entered after that first touch
    /// could not take effect — it would only mislabel the world already
    /// chosen.
    static func enter() {
        guard !entered else { return }
        entered = true
        sweep()
        setenv("SEARCH_PROBE", "tests-\(getpid())", 1)
        XCTestObservationCenter.shared.addTestObserver(Leaving.shared)
    }

    /// Take the world away, once, when the last test has run. Writes already
    /// asked for land first, so none lands after; then the settings and the
    /// folder are removed — only ever the world this process named, never
    /// the person's, never a named world.
    static func leave() {
        Disk.drain()
        guard let world = Store.world, world == "tests-\(getpid())" else { return }
        // The settings a test wrote land in the suite before the domain goes,
        // so cfprefsd has no backlog to write back afterwards.
        Store.settings.synchronize()
        erase(world)
        if Store.folder.lastPathComponent == "Search (\(world))" {
            remove(Store.folder)
        }
    }

    /// Leftovers of earlier runs that ended without leaving — a crash, a
    /// kill, or a run from before the world was taken away at the end. A
    /// world is swept only when it is one a run named and its pid is no
    /// longer running, so nothing a person or a deliberate probe made is
    /// touched.
    static func sweep() {
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let preferences = files.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences", isDirectory: true)

        var worlds: Set<String> = []
        let suitePrefix = "com.officecommun.search.test."
        let preferencesContents = (try? files.contentsOfDirectory(at: preferences, includingPropertiesForKeys: nil)) ?? []
        for file in preferencesContents {
            let name = file.deletingPathExtension().lastPathComponent
            guard name.hasPrefix(suitePrefix) else { continue }
            let world = String(name.dropFirst(suitePrefix.count))
            if stale(world) { worlds.insert(world) }
        }
        let folderPrefix = "Search ("
        let supportContents = (try? files.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)) ?? []
        for folder in supportContents {
            let name = folder.lastPathComponent
            guard name.hasPrefix(folderPrefix), name.hasSuffix(")") else { continue }
            let world = String(name.dropFirst(folderPrefix.count).dropLast())
            if stale(world) { worlds.insert(world) }
        }

        for world in worlds where dead(world) {
            erase(world)
            remove(support.appendingPathComponent("Search (\(world))", isDirectory: true))
        }
    }

    /// Drop a world's settings and their plist. `removePersistentDomain`
    /// alone leaves cfprefsd holding the domain and re-flushing it to
    /// ~/Library/Preferences a few seconds later — after the run, so a stub
    /// outlives it. Shelling out to `defaults delete` goes through cfprefsd
    /// and drops the domain for good, and the file is removed too for the
    /// rare empty stub that is still left behind.
    private static func erase(_ world: String) {
        let suite = "com.officecommun.search.test.\(world)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = Process()
        defaults.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        defaults.arguments = ["delete", suite]
        defaults.standardOutput = Pipe()
        let errors = Pipe()
        defaults.standardError = errors
        // A stuck `defaults` must not hang the run, so it is given a limit
        // and killed after it.
        let done = DispatchSemaphore(value: 0)
        defaults.terminationHandler = { _ in done.signal() }
        var ran = false
        do {
            try defaults.run()
            ran = true
        } catch {
            complain("could not run defaults delete \(suite): \(error)")
        }
        if ran {
            if done.wait(timeout: .now() + 10) == .timedOut {
                defaults.terminate()
                complain("defaults delete \(suite) did not finish in 10s")
            } else {
                let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                // An absent domain is success: `defaults` reports it as exit 1.
                if defaults.terminationStatus != 0,
                   !(defaults.terminationStatus == 1 && (stderr.contains("does not exist") || stderr.contains("not found"))) {
                    complain("defaults delete \(suite) failed (\(defaults.terminationStatus)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
        }
        let files = FileManager.default
        let plist = files.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(suite).plist")
        remove(plist)
    }

    /// Say what cleanup could not put away. Cleanup runs after the last test,
    /// so there is no test left to fail; the line goes to standard error for
    /// whoever reads the run's output.
    private static func complain(_ message: String) {
        FileHandle.standardError.write(Data("TestWorld: \(message)\n".utf8))
    }

    /// Remove `url`, and say so if it is still there afterwards. Cleanup runs
    /// after the last test, so a failure cannot fail a test — it is said on
    /// standard error, with the path and the error the removal gave.
    private static func remove(_ url: URL) {
        var failure: Error?
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError where absent(error) {
            // Already gone: what cleanup wants.
        } catch {
            failure = error
        }
        if FileManager.default.fileExists(atPath: url.path) {
            if let failure {
                complain("could not remove \(url.path): \(failure)")
            } else {
                complain("\(url.path) is still there after cleanup")
            }
        }
    }

    /// Whether an error just says the path is not there — the state cleanup
    /// wants, so not worth a complaint.
    private static func absent(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }

    /// Whether the pid a world is named for is gone: not running, and not
    /// this process.
    private static func dead(_ world: String) -> Bool {
        guard let digits = world.split(separator: "-").last,
              let pid = Int32(digits), pid > 0
        else { return false }
        return pid != getpid() && kill(pid, 0) == -1 && errno == ESRCH
    }
}

/// The end of the run, as XCTest sees it: the last test has run and the
/// world can be taken away.
private final class Leaving: NSObject, XCTestObservation {
    static let shared = Leaving()

    func testBundleDidFinish(_ testBundle: Bundle) {
        TestWorld.leave()
    }
}
