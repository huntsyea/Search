import XCTest
@testable import Search

// The chat's pi, scripted: the seam's second adapter (ChatPi.swift). A test
// gives `Chat(pi: script.pi)`, and then says exactly what pi answers, emits
// the events a real pi would, calls the browser's tools, stops it, or kills
// it — so the chat's lines, status and title can be checked without a
// provider (ChatTests.swift).

@MainActor
final class ScriptedPi {
    /// The data each command type answers with. Anything unlisted answers `[:]`.
    var answers: [String: [String: Any]] = [
        "get_state": ["thinkingLevel": "off"],
        "get_available_models": ["models": []],
        "get_available_thinking_levels": ["levels": []],
    ]
    /// Command types that fail, with why (an `NSError`'s description).
    var refusals: [String: String] = [:]
    /// What `title` answers, if anything.
    var titled: String?
    /// When set, `start` throws it.
    var startFailure: String?
    /// When set, `start` delivers `.exit(that)` before returning: pi died as it started.
    var exitWhileStarting: String??
    /// The session each start was given, in order.
    private(set) var starts: [String?] = []
    /// Every command any link was sent, in order.
    private(set) var sent: [[String: Any]] = []
    /// How many links were stopped.
    private(set) var stops = 0
    /// Every link made, in order, so a test can still call into an older one.
    private var links: [Link] = []

    /// The value to give `Chat(pi:)`.
    var pi: ChatPi {
        ChatPi(
            start: { [weak self] session, hear in
                guard let self else { throw ScriptedPi.gone }
                return try await self.start(session, hear)
            },
            title: { [weak self] _, _ in self?.titled }
        )
    }

    /// Every command type sent, in order.
    var sentTypes: [String] { sent.map { $0["type"] as? String ?? "" } }

    // MARK: - what the chat says to pi

    private func start(_ session: String?, _ hear: @escaping (PiSays) -> Void) async throws -> PiLink {
        starts.append(session)
        if let startFailure { throw ScriptedPi.refused(startFailure) }
        let link = Link(owner: self, hear: hear)
        latest = link
        links.append(link)
        if let exitWhileStarting { hear(.exit(exitWhileStarting)) }
        return link
    }

    // MARK: - what pi says to the chat

    private var latest: Link?

    /// A session event, delivered synchronously.
    func emit(_ event: [String: Any]) { latest?.deliver(.event(event)) }

    /// The lines as events, in order.
    func replay(_ events: [[String: Any]]) { for event in events { emit(event) } }

    /// A browser tool call, answered by the reply the task finishes with.
    func call(_ tool: String, _ args: [String: Any] = [:]) -> Task<[String: Any], Never> {
        call(tool, args, on: latest)
    }

    /// A browser tool call to the `index`th link, even one the chat has
    /// stopped: this plays a pi that hasn't died yet.
    func call(_ tool: String, _ args: [String: Any], on index: Int) -> Task<[String: Any], Never> {
        call(tool, args, on: links.indices.contains(index) ? links[index] : nil, evenIfEnded: true)
    }

    private func call(_ tool: String, _ args: [String: Any], on link: Link?,
                      evenIfEnded: Bool = false) -> Task<[String: Any], Never> {
        calls += 1
        let id = String(calls)
        return Task { @MainActor in
            await withCheckedContinuation { (done: CheckedContinuation<[String: Any], Never>) in
                let once = Once()
                let answer: ([String: Any]) -> Void = { reply in once.run { done.resume(returning: reply) } }
                // No link yet, or one that has ended: the call is answered as
                // pi would, rather than left hanging.
                guard let link, evenIfEnded || link.alive else {
                    return answer(["content": [["type": "text", "text": "pi isn't running"]], "isError": true])
                }
                let said = PiSays.tool(["kind": "tool", "id": id, "name": tool, "args": args], reply: answer)
                if evenIfEnded { link.force(said) } else { link.deliver(said) }
            }
        }
    }

    /// A tool call pi gave up on.
    func cancel() { latest?.deliver(.cancel) }

    /// pi ended, and why if it said.
    func exit(_ why: String?) { latest?.exit(why) }

    private var calls = 0

    // MARK: - pieces

    private static let gone = NSError(domain: "ScriptedPi", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "the scripted pi is gone"])
    private static func refused(_ why: String) -> NSError {
        NSError(domain: "ScriptedPi", code: 2, userInfo: [NSLocalizedDescriptionKey: why])
    }

    /// One running pi, as the chat holds it.
    @MainActor
    private final class Link: PiLink {
        private weak var owner: ScriptedPi?
        private let hear: (PiSays) -> Void
        private var ended = false

        /// Whether pi has ended, and nothing more is heard.
        var alive: Bool { !ended }

        init(owner: ScriptedPi, hear: @escaping (PiSays) -> Void) {
            self.owner = owner
            self.hear = hear
        }

        func request(_ command: [String: Any]) async throws -> [String: Any] {
            owner?.sent.append(command)
            guard !ended else {
                throw NSError(domain: "ScriptedPi", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "pi stopped"])
            }
            let type = command["type"] as? String ?? ""
            if let why = owner?.refusals[type] { throw ScriptedPi.refused(why) }
            return owner?.answers[type] ?? [:]
        }

        func stop() {
            owner?.stops += 1
            exit(nil)
        }

        func exit(_ why: String?) {
            guard !ended else { return }
            ended = true
            hear(.exit(why))
        }

        /// Nothing is delivered after this link has ended.
        func deliver(_ said: PiSays) {
            guard !ended else { return }
            hear(said)
        }

        /// Delivers even after this link has ended: a pi that hasn't died
        /// yet can still call just before it does.
        func force(_ said: PiSays) { hear(said) }
    }

    /// Resumes a continuation once, however many times it is called.
    private final class Once {
        private var done = false
        func run(_ body: () -> Void) {
            guard !done else { return XCTFail("a tool call was answered twice") }
            done = true
            body()
        }
    }
}

/// A tool call's reply, or nil (and a failed test) if none came within `seconds`.
@MainActor
func reply(_ step: Task<[String: Any], Never>, within seconds: Double = 5,
           file: StaticString = #filePath, line: UInt = #line) async -> [String: Any]? {
    var stored: [String: Any]?
    Task { stored = await step.value }
    await until(seconds, file: file, line: line) { stored != nil }
    return stored
}

/// Until `condition` holds, running the main run loop; fails the test after `seconds`.
@MainActor
func until(_ seconds: Double = 5, file: StaticString = #filePath, line: UInt = #line,
           _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("timed out", file: file, line: line)
}
