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
    /// How long a one-shot may take, from its start to its answer.
    private static let deadline = 60

    /// The models each agent listed, kept while Search runs: asking starts
    /// the agent, which isn't worth doing again for the same menu.
    private static var listed: [String: [AgentOption.Choice]] = [:]

    /// The agent's whole answer as text. `model`: a value from its model option, set first when it is one the agent
    /// lists (not for an agent that keeps a chosen model as its own default). Sixty seconds at most.
    static func answer(agent id: String, system: String, prompt: String, model: String?) async throws -> String {
        let agent = Agents.shared.oneShotAgent(id)
        let run = Run(name: agent.name)
        let link = try await agent.start(oneShot, nil) { [weak run] says in run?.heard(says) }
        defer { link.stop() }
        // The model is chosen before the question, and only when the agent
        // lists it: one it refuses isn't worth failing the answer over.
        if let model, !model.isEmpty, !Agents.shared.modelIsTheAgentsOwn(id),
           let option = run.model, option.choices.contains(where: { $0.value == model }) {
            try? await link.set(option.id, to: model)
        }
        try await link.prompt(system + "\n\n" + prompt)
        return try await run.wait(seconds: deadline)
    }

    /// The models it offers, for Settings' picker: started without a prompt (no tokens), its model option's choices,
    /// then stopped. Kept while Search runs, per agent.
    static func models(agent id: String) async -> [AgentOption.Choice] {
        if let known = listed[id] { return known }
        let agent = Agents.shared.oneShotAgent(id)
        let run = Run(name: agent.name)
        guard let link = try? await agent.start(oneShot, nil, { [weak run] says in run?.heard(says) }) else {
            return []
        }
        link.stop()
        let choices = run.model?.choices ?? []
        listed[id] = choices
        return choices
    }
}

/// One one-shot's run as it goes: the words of the answer by item, the
/// options the agent listed, and the continuation waiting for it to finish.
@MainActor
private final class Run {
    private let name: String
    /// The answer's items in the order they first appeared.
    private var order: [String] = []
    private var texts: [String: String] = [:]
    private(set) var options: [AgentOption] = []
    private var outcome: Result<String, Error>?
    private var waiting: CheckedContinuation<String, Error>?

    init(name: String) { self.name = name }

    /// The agent's model option, when it listed one.
    var model: AgentOption? { options.first { $0.category == .model } }

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

    private func finish(_ result: Result<String, Error>) {
        guard outcome == nil else { return }
        outcome = result
        let waiting = waiting
        self.waiting = nil
        waiting?.resume(with: result)
    }

    /// Wait for it to finish, and no longer than `seconds`: past that the run
    /// is over.
    func wait(seconds: Int) async throws -> String {
        if let outcome { return try outcome.get() }
        return try await withCheckedThrowingContinuation { continuation in
            waiting = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self] in
                guard let self else { return }
                self.finish(.failure(ChildProcess.Failure(why: "\(self.name) took longer than \(seconds) seconds")))
            }
        }
    }
}
