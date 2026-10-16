import Foundation

// What a chat needs of its agent, as one seam, at the conversation: a way to
// start one on a session and hear what it says, as the chat draws it, and a
// way to name a chat (docs/design/agents.md). Each agent's own wire stays in
// its adapter — pi's RPC (ChatPi.swift), ACP — and every rule of the chat
// (busy, settled, "Stopped.", asks, pauses, marks) stays in Chat.

/// Everything a chat's agent says, in the order it says it, on the main actor.
///
/// What it says before `start` returns is the session's history, as it was
/// said live: the chat shows it once, when it hasn't yet, and lets it go
/// after that (a chat whose agent is started again).
enum AgentSays {
    /// A message of the person's, as it was sent.
    case user(String)
    /// Words of the answer or of its thinking (`kind` .assistant or
    /// .thinking), in the item `id`: added to it, or put in its place when
    /// `whole`. `done` once that item won't change again.
    case text(id: String, kind: Chat.Item.Kind, text: String, whole: Bool, done: Bool)
    /// The item `id` won't change again.
    case done(id: String)
    /// A step begun: a browser tool called by `name` with `args`.
    case toolStarted(id: String, name: String, args: [String: Any])
    /// The step `id` finished: the line it ends on (`summary`) when it went
    /// well, what it said (`detail`) when it failed.
    case toolEnded(id: String, failed: Bool, summary: String?, detail: String)
    /// The line an answer ends on, when it didn't just finish: `.note`
    /// ("Stopped.") or `.error` (why the model failed).
    case line(kind: Chat.Item.Kind, text: String)
    /// Done with the person's message: nothing more until the next one.
    case settled
    /// The session the chat is kept as, once the agent has one.
    case session(String)
    /// A name the agent gave the chat.
    case named(String)
    /// "Retrying…" while there is nothing new to show; nil once there is.
    case status(String?)
    /// What can be chosen for this chat — its model, how hard it thinks —
    /// and what is chosen now, whenever that changes.
    case options([AgentOption])
    /// A call to one of the browser's tools, answered with `reply` exactly
    /// once. `givenUp` says whether the agent has since given the call up:
    /// then it isn't done, whatever was answered meanwhile.
    case tool([String: Any], givenUp: @MainActor () -> Bool, reply: ([String: Any]) -> Void)
    /// A tool call the agent gave up on (Stop) while Search was still on it.
    case cancel
    /// The agent ended, and why if it said. Nothing is heard after it, and
    /// the link fails from then on. It may come before `start` returns.
    case exit(String?)
}

/// Something a chat can choose for its agent, as ACP's session config
/// options have it: the model, how hard it thinks.
struct AgentOption: Identifiable, Equatable {
    enum Category: Equatable { case model, thought }

    struct Choice: Identifiable, Equatable {
        let value: String
        let name: String
        /// The heading it is listed under: a model's provider.
        var group: String?
        var id: String { value }
    }

    let id: String
    let name: String
    let category: Category
    var current: String?
    let choices: [Choice]

    /// The choice made now, if it is one listed.
    var chosen: Choice? { choices.first { $0.value == current } }
}

/// One running agent, as the chat holds it.
@MainActor
protocol AgentLink: AnyObject {
    /// The person's message, `text` with the chat's own context ahead of it.
    /// Returns once the agent has taken it; what it says comes as `AgentSays`.
    /// Throws when it refuses it or has ended.
    func prompt(_ text: String) async throws
    /// The person's Stop: the agent stops what it's doing and settles.
    func cancel()
    /// One of its options set to `value`; the options follow, as `.options`.
    func set(_ option: String, to value: String) async throws
    /// The chat's name, kept with the session where the agent keeps one.
    func name(_ title: String)
    /// Let go of it: the agent is asked to end, and `.exit` follows.
    func stop()
}

/// What a chat needs of the agent it runs on: the app's adapters are pi
/// (`ChatAgent.pi`) and ACP; the tests' is a scripted pi behind the first.
@MainActor
struct ChatAgent {
    /// The agent's name, as the chat says it: "Starting pi…", "pi stopped."
    let name: String
    /// The agent started on `session`, or on a new session when nil or when
    /// the agent no longer has it, with `hear` told everything it says from
    /// then on — the session's history first. `chat` is the chat's id, which
    /// an agent that keeps sessions by folder runs in.
    var start: (_ chat: UUID, _ session: String?, _ hear: @escaping (AgentSays) -> Void) async throws -> AgentLink
    /// A chat's name, in a few words, from its first message and the page it
    /// was sent on; nil when none came.
    var title: (_ words: String, _ page: String?) async -> String?
}
