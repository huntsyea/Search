import Foundation

// One question to an ACP agent, away from any chat and with no tools: the
// side prompts' run when the person chose an agent other than pi for them
// (Settings › AI, docs/design/agents.md). The agent is started as a chat's
// would be — its sign-in, its adapter, its settings — but with no browser
// tools, asked once, and stopped. The wire itself stays in ACP.swift.

/// One question to an ACP agent, away from any chat and with no tools: the side prompts' run when the person chose
/// an agent other than pi for them (Settings › AI). The agent is started as a chat's would be — its sign-in, its
/// adapter, its settings — but with no browser tools, asked once, and stopped.
@MainActor
enum AgentOnce {
    /// The fixed "chat" every one-shot runs as: its own empty folder under
    /// Chats/Workspaces, which no chat ever uses.
    private static let oneShot = UUID(uuid: (0xA1, 0x1C, 0xE0, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01))
    /// How long a one-shot may take, from its entry to its answer. A test
    /// shortens it.
    static var deadline: TimeInterval = 60

    /// What asking an agent for its models came to, for Settings' menu.
    enum Models {
        case loaded([AgentOption.Choice])
        case needsSetUp(AgentNeedsSetUp)
        case needsSignIn(AgentSignIn)
        case failed(String)
    }

    /// The lists each agent gave, kept while Search runs. Only a list with
    /// something in it is kept: an empty one is worth asking again.
    private static var listed: [String: Models] = [:]
    /// The asks in flight, by agent: calls that arrive together share one.
    private static var asking: [String: Task<Models, Never>] = [:]

    /// A list an agent gave is stale once the agents themselves change.
    static func forgetModels() {
        listed = [:]
        asking.values.forEach { $0.cancel() }
        asking = [:]
    }

    /// The agent's whole answer as text. `model`: a value from its model option, set first when it is one the agent
    /// lists (not for an agent that keeps a chosen model as its own default). Sixty seconds at most, from entry.
    static func answer(agent id: String, system: String, prompt: String, model: String?) async throws -> String {
        let agent = Agents.shared.oneShotAgent(id)
        // One deadline for the whole run, start included.
        let run = Run(name: agent.name, deadline: deadline)
        // The run is set going apart from the wait, so the deadline can give
        // up on it; a start still away when it passes is stopped as it lands.
        let work = Task { @MainActor in
            do {
                let link = try await agent.start(oneShot, nil) { [weak run] says in run?.heard(says) }
                run.linked(link)
                guard !run.isOver else { return }
                // The model is chosen before the question, and only when the
                // agent lists it: one it refuses isn't worth failing over.
                if let model, !model.isEmpty, !Agents.shared.modelIsTheAgentsOwn(id),
                   let option = run.model, option.choices.contains(where: { $0.value == model }) {
                    try? await link.set(option.id, to: model)
                }
                guard !run.isOver else { return }
                try await link.prompt(system + "\n\n" + prompt)
            } catch {
                run.finish(.failure(error))
            }
        }
        do {
            let answer = try await run.wait()
            run.stop()
            return answer
        } catch {
            run.stop()
            work.cancel()
            throw error
        }
    }

    /// The models it offers, for Settings' picker: started without a prompt (no tokens), its model option's choices,
    /// then stopped. Calls for the same agent share one ask, and the list is kept while the agents don't change.
    static func models(agent id: String) async -> Models {
        if let known = listed[id] { return known }
        if let running = asking[id] { return await running.value }
        let task = Task { @MainActor in await askModels(agent: id) }
        asking[id] = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        asking[id] = nil
        if case .loaded(let choices) = result, !choices.isEmpty { listed[id] = result }
        return result
    }

    /// One ask, as the shared task runs it.
    private static func askModels(agent id: String) async -> Models {
        let agent = Agents.shared.oneShotAgent(id)
        let run = Run(name: agent.name, deadline: deadline)
        do {
            let link = try await agent.start(oneShot, nil) { [weak run] says in run?.heard(says) }
            // Settings may have changed its mind while the start was away.
            if Task.isCancelled {
                link.stop()
                return .failed("Asking \(agent.name) was given up on.")
            }
            defer { link.stop() }
            if run.isOver { return .failed("\(agent.name) took longer than \(Int(deadline)) seconds") }
            return .loaded(run.model?.choices ?? [])
        } catch let wanted as AgentNeedsSetUp {
            return .needsSetUp(wanted)
        } catch let wanted as AgentSignIn {
            return .needsSignIn(wanted)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// One one-shot's run as it goes: the words of the answer by item, the
/// options the agent listed, and the continuation waiting for it to finish.
/// Its clock starts at the run's entry and covers everything.
@MainActor
private final class Run {
    private let name: String
    private let deadline: TimeInterval
    /// The answer's items in the order they first appeared.
    private var order: [String] = []
    private var texts: [String: String] = [:]
    private(set) var options: [AgentOption] = []
    private var outcome: Result<String, Error>?
    private var waiting: CheckedContinuation<String, Error>?
    private var link: AgentLink?
    private var expired = false

    init(name: String, deadline: TimeInterval) {
        self.name = name
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) { [weak self] in
            self?.timedOut()
        }
    }

    /// The agent's model option, when it listed one.
    var model: AgentOption? { options.first { $0.category == .model } }

    /// Over: the deadline passed or an answer or failure came.
    var isOver: Bool { expired || outcome != nil }

    /// The answer as it stands: its assistant texts, in order, one a line.
    private var answer: String { order.map { texts[$0] ?? "" }.joined(separator: "\n") }

    /// Everything the agent says. One answer is wanted and no tools are
    /// given, so a browser call — which shouldn't come — is refused.
    func heard(_ says: AgentSays) {
        switch says {
        case let .text(id, kind, text, whole, _) where kind == .assistant:
            put(id, text, whole: whole)
        case let .options(list):
            options = list
        case .settled:
            finish(.success(answer))
        case .exit:
            finish(.failure(ChildProcess.Failure(why: "\(name) stopped")))
        case let .line(kind: kind, text: text) where kind == .error:
            finish(.failure(ChildProcess.Failure(why: text)))
        case let .tool(_, _, reply):
            reply(["content": [["type": "text", "text": "No tools here."]], "isError": true,
                   "details": ["summary": "No tools here."]])
        default:
            break
        }
    }

    private func put(_ id: String, _ text: String, whole: Bool) {
        if texts[id] == nil { order.append(id) }
        texts[id] = whole ? text : (texts[id] ?? "") + text
    }

    /// The link landed: keep it, and let it go at once when the run is over.
    func linked(_ link: AgentLink) {
        if isOver { link.stop(); return }
        self.link = link
    }

    /// Let the agent go, when it is here.
    func stop() {
        link?.stop()
        link = nil
    }

    func finish(_ result: Result<String, Error>) {
        guard outcome == nil else { return }
        outcome = result
        let waiting = waiting
        self.waiting = nil
        waiting?.resume(with: result)
    }

    private func timedOut() {
        guard outcome == nil else { return }
        expired = true
        stop()
        finish(.failure(ChildProcess.Failure(why: "\(name) took longer than \(Int(deadline)) seconds")))
    }

    /// Wait for the answer, or the deadline.
    func wait() async throws -> String {
        if let outcome { return try outcome.get() }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }
}
