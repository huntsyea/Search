import Foundation
import WebKit

/// Knows whether each extension's worker runs, and brings back the ones
/// WebKit left dead. A worker is dead when WebKit has been asked to start the
/// extension's background and the worker hasn't said it started within a
/// while (`patience`). WebKit leaves one
/// dead when it takes up a registration kept from an earlier launch, or from
/// before its network process started again. Bringing one back means clearing
/// every registration, since WebKit can't clear one alone, and that stops
/// every worker. So every extension with a worker is loaded again (`reload`),
/// at most once a minute. For callers: `forgetKept()` must finish before the
/// first extension loads at launch.
@available(macOS 15.4, *)
@MainActor
final class ExtensionWorkers {
    private let store: WKWebsiteDataStore
    private let patience: Duration
    private let watch: Duration
    private let reviveEvery: TimeInterval
    private let networkProcessLookup: (() -> pid_t)?
    private let reload: (_ ids: [String], _ reason: String) async -> Void

    private var clearing: Task<Void, Never>?
    private var recovering: Task<Void, Never>?
    private var deferred: (reason: String, task: Task<Void, Never>)?
    private var reviving: Set<String> = []
    private var lastRevived: Set<String> = []
    private var givenUp: Set<String> = []
    private var contexts: [String: WKWebExtensionContext] = [:]
    private var running: Set<String> = []
    private var loads: Set<String> = []
    private var before: Set<String> = []
    private var errorWatchers: [String: NSObjectProtocol] = [:]
    private var networkProcess: pid_t = 0
    private var watching: Task<Void, Never>?
    private var lastRevive: Date = .distantPast

    /// `networkProcess` only the module's own tests pass one, to stand for
    /// WebKit's network process starting again.
    init(store: WKWebsiteDataStore,
         patience: Duration = .seconds(10),
         watch: Duration = .seconds(5),
         reviveEvery: TimeInterval = 60,
         networkProcess: (() -> pid_t)? = nil,
         reload: @escaping (_ ids: [String], _ reason: String) async -> Void) {
        self.store = store
        self.patience = patience
        self.watch = watch
        self.reviveEvery = reviveEvery
        self.networkProcessLookup = networkProcess
        self.reload = reload
    }

    /// Clears the registrations WebKit kept, once; later calls wait for that
    /// same clearing. Every load awaits the latest clearing first; a load
    /// already past that wait when a revive starts clearing is caught anyway,
    /// because the revive takes its list of extensions only after clearing.
    /// Websites' workers go with them and are registered again the next time
    /// the site is opened online; until then a site kept for offline use
    /// doesn't open without a connection.
    func forgetKept() async {
        if clearing == nil { clearing = Task { await store.removeData(ofTypes: [WKWebsiteDataTypeServiceWorkerRegistrations], modifiedSince: .distantPast) } }
        await clearing?.value
    }

    /// An extension just loaded into the controller (every load: launch,
    /// enable, install, reload, update, a revive's).
    func loaded(_ context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        // Only the first load of each id during a revive counts as the
        // revive's; any other load starts afresh.
        if reviving.remove(id) == nil {
            givenUp.remove(id)
            lastRevived.remove(id)
        }
        if contexts[id] == nil, loads.contains(id) { before.insert(id) }
        loads.insert(id)
        contexts[id] = context
        running.remove(id)
        guard context.webExtension.hasBackgroundContent else { return }

        // WebKit records a worker that failed to start as an error on its
        // context, and doesn't try again.
        if let old = errorWatchers[id] { NotificationCenter.default.removeObserver(old) }
        errorWatchers[id] = NotificationCenter.default.addObserver(forName: WKWebExtensionContext.errorsDidUpdateNotification, object: context, queue: .main) { [weak self, weak context] _ in
            MainActor.assumeIsolated {
                guard let self, let context, self.contexts[id] === context else { return }
                let failed = context.errors.contains { error in
                    let e = error as NSError
                    return e.domain == WKWebExtensionContext.errorDomain && e.code == WKWebExtensionContext.Error.backgroundContentFailedToLoad.rawValue
                }
                guard failed else { return }
                // A worker that failed to start isn't running, whatever it
                // said before.
                self.running.remove(id)
                self.needRevive(because: "its worker failed to start", for: id)
            }
        }

        if networkProcess == 0 { networkProcess = currentNetworkProcess() }
        if watching == nil {
            // A network process that starts again keeps the registrations but
            // starts none of their workers, and WebKit says nothing about it,
            // so its process is looked at every few seconds while any
            // extension has a worker.
            let every = watch
            watching = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: every)
                    if Task.isCancelled { return }
                    guard let self else { return }
                    let now = self.currentNetworkProcess()
                    if now == 0 { continue }
                    if self.networkProcess == 0 {
                        self.networkProcess = now
                    } else if now != self.networkProcess {
                        self.networkProcess = now
                        self.needRevive(because: "WebKit's network process started again", for: nil)
                    }
                }
            }
        }

        let wait = patience
        Task { [weak self] in
            guard let self else { return }
            await self.loadBackground(context)
            try? await Task.sleep(for: wait)
            if self.contexts[id] === context, !self.running.contains(id) {
                self.needRevive(because: "its worker didn't start", for: id)
            }
        }
    }

    /// An extension just unloaded. `removed`: uninstalled, so it no longer
    /// counts as loaded before.
    func unloaded(_ id: String, removed: Bool = false) {
        contexts[id] = nil
        running.remove(id)
        if let old = errorWatchers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(old) }
        if removed {
            loads.remove(id)
            before.remove(id)
        }
        if !contexts.values.contains(where: { $0.webExtension.hasBackgroundContent }) {
            watching?.cancel()
            watching = nil
        }
    }

    /// The extension's worker (or background page) says it has started — its
    /// shim says so each time it starts.
    func started(_ id: String) {
        guard contexts[id] != nil else { return }
        running.insert(id)
    }

    /// Loaded at least once since the browser started, and loaded again.
    func loadedBefore(_ id: String) -> Bool {
        before.contains(id)
    }

    /// Called when a worker doesn't start or is missing. One that didn't
    /// start even after a revive won't be helped by another, so it is given
    /// up on until it is loaded afresh. Otherwise the revive runs, or waits
    /// until any one in progress and the minute since the last have passed.
    private func needRevive(because reason: String, for id: String?) {
        if let id, givenUp.contains(id) { return }
        if let id, lastRevived.contains(id), Date().timeIntervalSince(lastRevive) < reviveEvery {
            // One that didn't start even after a revive won't be helped by
            // another; it waits until it is loaded afresh.
            givenUp.insert(id)
            return
        }
        if recovering != nil || Date().timeIntervalSince(lastRevive) < reviveEvery || deferred != nil {
            let network = "WebKit's network process started again"
            if let waiting = deferred {
                // The network process starting again is the reason that must
                // not be lost: it wins over the others waiting.
                if waiting.reason != network, reason == network { deferred = (reason, waiting.task) }
            } else {
                let at = lastRevive.addingTimeInterval(reviveEvery)
                deferred = (reason, Task { [weak self] in
                    let delay = at.timeIntervalSinceNow
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    guard let self else { return }
                    await self.recovering?.value
                    let held = self.deferred?.reason ?? reason
                    self.deferred = nil
                    // With a reason other than the network process's, nothing
                    // is done if every loaded extension with a worker is
                    // running or already given up on.
                    if held == network || self.contexts.contains(where: { $0.value.webExtension.hasBackgroundContent && !self.running.contains($0.key) && !self.givenUp.contains($0.key) }) {
                        self.revive(because: held)
                    }
                })
            }
            return
        }
        revive(because: reason)
    }

    /// One dead worker means clearing every registration, because WebKit
    /// can't clear one extension's alone, and clearing them all stops every
    /// worker — so every extension with a worker is loaded again. The list is
    /// taken after the clearing, so a load that finished while it ran is
    /// included, and every load waits for the clearing (`forgetKept`).
    private func revive(because reason: String) {
        lastRevive = Date()
        recovering = Task { [weak self] in
            guard let self else { return }
            let cleared = Task { await self.store.removeData(ofTypes: [WKWebsiteDataTypeServiceWorkerRegistrations], modifiedSince: .distantPast) }
            self.clearing = cleared
            await cleared.value
            let ids = self.contexts.filter { $0.value.webExtension.hasBackgroundContent }.keys.sorted()
            if ids.isEmpty {
                self.recovering = nil
                return
            }
            self.lastRevived = Set(ids)
            self.reviving = Set(ids)
            await self.reload(ids, reason)
            self.reviving = []
            self.recovering = nil
        }
    }

    /// WebKit never calls back after some failed starts, so the wait is over
    /// when the completion handler runs or after eight seconds, whichever
    /// comes first. The result doesn't matter here; the start check decides.
    private func loadBackground(_ context: WKWebExtensionContext) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            let finish = {
                guard !finished else { return }
                finished = true
                continuation.resume()
            }
            context.loadBackgroundContent { _ in
                MainActor.assumeIsolated { finish() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                MainActor.assumeIsolated { finish() }
            }
        }
    }

    /// The name is outside the public framework, and Safari uses it.
    private func currentNetworkProcess() -> pid_t {
        if let networkProcessLookup { return networkProcessLookup() }
        let sel = NSSelectorFromString("_networkProcessIdentifier")
        guard store.responds(to: sel) else { return 0 }
        typealias Getter = @convention(c) (AnyObject, Selector) -> pid_t
        return unsafeBitCast(store.method(for: sel), to: Getter.self)(store, sel)
    }
}
