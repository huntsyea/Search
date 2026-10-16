import AppKit
import Foundation

// The agents a chat can run on: pi, the ACP agents Search knows and finds on
// the person's login PATH, and any they added themselves
// (docs/design/agents.md, "Discovery"). Finding is the login shell's PATH
// (LoginShell), as pi's own lookup is; what is here is the table of known
// agents, the person's additions, which ones they hid, and which agent a
// chat runs on.

/// An agent a chat can run on: pi, an ACP agent Search knows and found on the person's login PATH, or one they added.
struct AgentChoice: Identifiable, Equatable {
    /// "pi", a known agent's id ("opencode"), or "custom.<uuid>".
    let id: String
    let name: String
    /// Where its program is; nil for a custom one whose program isn't found.
    let path: String?
    /// How it is run: nil for pi; the ACP launch otherwise.
    let spec: ACPSpec?
    /// What happens to the agent's own tools, as Settings says it.
    let ownTools: OwnTools
    /// The command that signs in to it in a terminal, when there is one.
    let login: [String]?
    /// True when the agent keeps a model chosen over ACP as its own default
    /// (cursor-agent): Search never chooses or remembers one for it.
    let modelIsTheAgentsOwn: Bool
    /// The ACP adapter that carries it, for an agent that doesn't speak ACP
    /// itself (Claude Code, Codex). Nil for the rest.
    var adapter: Adapter? = nil
    var custom: Bool { id.hasPrefix("custom.") }
}

enum OwnTools: Equatable {
    /// Switched off by its own settings (pi's flags, Claude's options, opencode's permissions).
    case off
    /// It can't be told to drop them: Search refuses each one it asks for, and it runs in an empty folder.
    case refused
}

/// Why a command line the person typed can't be an agent.
enum AgentAddError: LocalizedError, Equatable {
    case unclosedQuote
    case noProgram
    case relativePath

    var errorDescription: String? {
        switch self {
        case .unclosedQuote: return "That command line has an unclosed quote."
        case .noProgram: return "That command line has no program."
        case .relativePath: return "Give the program's full path, or a name on your PATH."
        }
    }
}

/// What Settings shows for an agent: the last thing a start said.
enum AgentState {
    case ready
    case signIn
    case unknown
}

/// The agent's ACP adapter isn't set up yet: Set Up installs it.
struct AgentNeedsSetUp: LocalizedError {
    let agent: String
    let adapter: Adapter
    var errorDescription: String? { "\(agent) needs its ACP adapter set up first." }
}

/// One known agent: the program that carries it and how Search starts it.
struct KnownAgent: Sendable {
    let id: String
    let name: String
    let program: String
    let arguments: [String]
    let environment: [String: String]
    let ownTools: OwnTools
    let login: [String]?
    /// True for an agent that keeps a model chosen over ACP as its own
    /// default.
    var modelIsTheAgentsOwn = false
    /// The adapter that carries it, when its program doesn't speak ACP
    /// itself (Claude Code, Codex). Nil for the rest.
    var adapter: Adapter? = nil
    /// Config options to set as each session starts, by the option's id:
    /// the agent's sandbox, say. One the session doesn't list is skipped.
    var startOptions: [String: String] = [:]
}

/// The agents Search knows, finds and lets the person add; and which ones they hid.
@MainActor
final class Agents: ObservableObject {
    static let shared = Agents()

    /// pi first (always: a chat on pi says so when it isn't installed), then
    /// each known agent found, in the table's order, then the person's own.
    /// Found once a run, off the main thread; again on refresh().
    @Published private(set) var all: [AgentChoice] = []
    /// The ones not hidden in Settings: what the chat's menu offers. pi is never hidden.
    var visible: [AgentChoice] { all.filter { !isHidden($0.id) } }
    /// Whether the first look has finished.
    @Published private(set) var looked = false

    /// Settings: the agents the person hid, and the ones they added.
    nonisolated static let hiddenKey = "chat.agents.hidden"
    nonisolated static let customKey = "chat.agents.custom"

    /// For tests: the PATH to look on instead of the login shell's, and nothing kept between tests.
    nonisolated(unsafe) static var searchPathForTests: String?

    /// Which look is the newest: a look that started before a refresh() must
    /// not put its older answer over the newer one.
    private var generation = 0
    /// Chats waiting for the first look before they know their agent: resumed
    /// together when it lands.
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// The known table, in the order the picker offers them. Every one was
    /// checked to start over ACP against a real `initialize` on 15 Oct 2026.
    /// Claude Code and Codex don't speak ACP themselves: an adapter carries
    /// each, run with the person's node.
    nonisolated static let known: [KnownAgent] = [
        KnownAgent(id: "claude", name: "Claude Code", program: "claude",
                   arguments: [], environment: [:], ownTools: .off, login: ["claude"],
                   adapter: Adapters.claude),
        // Codex's sandbox, whatever its own default: a patch it writes is
        // refused by it, not only by Search. Its shell is off, but code mode,
        // apply_patch and a few others remain, so its own tools are refused.
        KnownAgent(id: "codex", name: "Codex", program: "codex",
                   arguments: [], environment: [:], ownTools: .refused, login: ["codex", "login"],
                   adapter: Adapters.codex, startOptions: ["mode": "read-only"]),
        KnownAgent(id: "opencode", name: "opencode", program: "opencode",
                   arguments: ["acp"],
                   environment: [
                       "OPENCODE_CLIENT": "acp",
                       "OPENCODE_ENABLE_QUESTION_TOOL": "false",
                       "OPENCODE_DISABLE_CLAUDE_CODE": "1",
                       "OPENCODE_PERMISSION": #"{"*":"deny","search_*":"allow"}"#,
                   ],
                   ownTools: .off, login: ["opencode", "auth", "login"]),
        KnownAgent(id: "omp", name: "Oh My Pi", program: "omp",
                   arguments: ["--no-tools", "--no-extensions", "--no-skills", "--no-rules", "acp"],
                   environment: [:], ownTools: .refused, login: nil),
        KnownAgent(id: "grok", name: "Grok", program: "grok",
                   arguments: ["agent", "--no-leader", "stdio"],
                   environment: [:], ownTools: .refused, login: ["grok", "login"]),
        KnownAgent(id: "hermes", name: "Hermes", program: "hermes",
                   arguments: ["acp"],
                   environment: [:], ownTools: .refused, login: ["hermes", "setup"]),
        KnownAgent(id: "gemini", name: "Gemini", program: "gemini",
                   arguments: ["--acp"],
                   environment: [:], ownTools: .refused, login: ["gemini"]),
        KnownAgent(id: "cursor", name: "Cursor", program: "cursor-agent",
                   arguments: ["acp"],
                   environment: [:], ownTools: .refused, login: ["cursor-agent", "login"],
                   modelIsTheAgentsOwn: true),
        KnownAgent(id: "kimi", name: "Kimi", program: "kimi",
                   arguments: ["acp"],
                   environment: [:], ownTools: .refused, login: ["kimi", "login"]),
    ]

    init() {
        look()
    }

    /// Look again, off the main thread: the login shell is asked afresh, so a
    /// program installed since Search started is found.
    func refresh() {
        LoginShell.forget()
        looked = false
        look()
    }

    /// The agent with that id, from what was found and what the person added.
    func choice(_ id: String) -> AgentChoice? { all.first { $0.id == id } }

    /// Whether the agent keeps a chosen model as its own default: Search
    /// mustn't choose one for it, or remember one for its next chat.
    func modelIsTheAgentsOwn(_ id: String) -> Bool { choice(id)?.modelIsTheAgentsOwn ?? false }

    /// Wait for the first look, when it hasn't finished: what a saved chat's
    /// agent needs before it can tell whether it is still here.
    func ready() async {
        if looked { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiting.append(continuation)
        }
    }

    /// The method the person signed in with, remembered for the agent's next
    /// chat: put in its spec, so a start signs in without a card.
    func remember(signIn method: String, for id: String) {
        Store.settings.set(method, forKey: Agents.signInKey(id))
    }

    /// Forget the remembered sign-in method: the agent rejected it.
    func forget(signInFor id: String) {
        Store.settings.removeObject(forKey: Agents.signInKey(id))
    }

    /// The model the person chose for this agent, remembered for its next
    /// chat too.
    func remember(model value: String, for id: String) {
        Store.settings.set(value, forKey: Agents.modelKey(id))
    }

    /// What the agent's last start said: ready, sign-in wanted, or nothing yet.
    func state(_ id: String) -> AgentState {
        switch Store.settings.string(forKey: Agents.stateKey(id)) {
        case "ready": return .ready
        case "signin": return .signIn
        default: return .unknown
        }
    }

    /// Note what a start said, for Settings to show.
    func note(_ state: AgentState, for id: String) {
        switch state {
        case .ready: Store.settings.set("ready", forKey: Agents.stateKey(id))
        case .signIn: Store.settings.set("signin", forKey: Agents.stateKey(id))
        case .unknown: Store.settings.removeObject(forKey: Agents.stateKey(id))
        }
    }

    /// Whether the person hid it in Settings. pi is never hidden.
    func isHidden(_ id: String) -> Bool {
        id != "pi" && Agents.hiddenIDs().contains(id)
    }

    /// Hide it — or show it again. pi is never hidden.
    func hide(_ id: String, _ hidden: Bool) {
        guard id != "pi" else { return }
        var ids = Agents.hiddenIDs()
        if hidden {
            if !ids.contains(id) { ids.append(id) }
        } else {
            ids.removeAll { $0 == id }
        }
        Store.settings.set(ids, forKey: Agents.hiddenKey)
        // `visible` is worked out from what is written; tell the menus it changed.
        objectWillChange.send()
    }

    /// One the person added: a name and a command line, run as an ACP agent.
    /// Fails with why the line can't be used.
    func add(name: String, command: String) -> Result<AgentChoice, AgentAddError> {
        guard let words = Agents.words(command) else { return .failure(.unclosedQuote) }
        guard let program = words.first, !program.isEmpty else { return .failure(.noProgram) }
        // A relative path would mean something else run from the chat's own
        // folder: only a full path, a "~/" path, or a name on the PATH.
        let relative = program.contains("/") && !program.hasPrefix("/") && !program.hasPrefix("~/")
        guard !relative else { return .failure(.relativePath) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = "custom." + UUID().uuidString
        let called = trimmed.isEmpty ? program : trimmed
        var entries = Agents.customEntries()
        entries.append(["id": id, "name": called, "command": command])
        Store.settings.set(entries, forKey: Agents.customKey)
        let choice = Agents.customChoice(id: id, name: called, command: command)
        all.append(choice)
        return .success(choice)
    }

    /// A custom one the person took away. Known agents and pi are not removed.
    func remove(_ id: String) {
        guard id.hasPrefix("custom.") else { return }
        var entries = Agents.customEntries()
        entries.removeAll { $0["id"] == id }
        Store.settings.set(entries, forKey: Agents.customKey)
        all.removeAll { $0.id == id }
    }

    /// The chat's agent for `id`: pi, or one whose spec is looked up when it
    /// starts — not when the chat is made, before Agents' first look has
    /// finished. One that isn't there any more starts by failing with
    /// "\(name) isn't on this Mac any more." — the name kept with the chat
    /// when there is one.
    func chatAgent(_ id: String, name: String? = nil, signIn method: String? = nil) -> ChatAgent {
        if id == "pi" { return .pi() }
        let called = name ?? Agents.keptName(id) ?? id
        return ChatAgent(name: called, start: { [weak self] chat, session, hear in
            // A saved chat is opened at startup, while the first look may
            // still be in flight: wait for it before calling an agent gone.
            guard let self else { throw ChildProcess.Failure(why: "\(called) isn't on this Mac any more.") }
            await self.ready()
            guard let choice = self.choice(id), let spec = choice.spec else {
                throw ChildProcess.Failure(why: "\(called) isn't on this Mac any more.")
            }
            // An agent that needs an adapter Search set up first: the chat's
            // card offers to install it.
            if let adapter = choice.adapter, !Adapters.isSetUp(adapter) {
                throw AgentNeedsSetUp(agent: called, adapter: adapter)
            }
            var signed = spec
            signed.signIn = method ?? Agents.signIn(for: id)
            do {
                let link = try await ChatAgent.acp(signed).start(chat, session, hear)
                self.note(.ready, for: id)
                // A method that worked is remembered now, so one the agent
                // rejects is never kept to trap the next start.
                if let used = signed.signIn { self.remember(signIn: used, for: id) }
                return link
            } catch let wanted as AgentSignIn {
                self.note(.signIn, for: id)
                if wanted.stale { self.forget(signInFor: id) }
                throw wanted
            }
        }, title: { words, page in
            await PiOnce.title(for: words, on: page)
        })
    }

    /// Open the agent's own sign-in in a terminal: the login command (or the
    /// one given), as a .command file Terminal runs. False when there is none.
    @discardableResult
    func openLogin(_ choice: AgentChoice, command: [String]? = nil, environment: [String: String] = [:]) -> Bool {
        guard var words = command ?? choice.login, let first = words.first else { return false }
        // The agent's own program, found, rather than whatever the shell finds.
        if first == Agents.programName(choice), let path = choice.path { words[0] = path }
        let script = Agents.loginScript(command: words, environment: environment)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("Search sign-in – \(choice.name).command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            return false
        }
        NSWorkspace.shared.open(file)
        return true
    }

    /// The .command file's text: the variables it needs, then the command,
    /// each word and value single-quoted.
    nonisolated static func loginScript(command: [String], environment: [String: String]) -> String {
        var lines = ["#!/bin/zsh -l"]
        for (name, value) in environment.sorted(by: { $0.key < $1.key }) {
            lines.append("export \(name)=\(shellQuote(value))")
        }
        lines.append(command.map(shellQuote).joined(separator: " "))
        lines.append("echo; echo \"Signed in? Go back to Search and press Try Again.\"")
        return lines.joined(separator: "\n") + "\n"
    }

    /// One word, single-quoted; a single quote inside is escaped as '\''.
    nonisolated static func shellQuote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - looking

    private func look() {
        generation += 1
        let mine = generation
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = Agents.found()
            await MainActor.run { [weak self] in
                guard let self, self.generation == mine else { return }
                // The custom tail is read here, not in the snapshot: one
                // added or removed while the look was away still stands.
                self.all = found + Agents.customChoices()
                self.looked = true
                let waiting = self.waiting
                self.waiting = []
                waiting.forEach { $0.resume() }
            }
        }
    }

    /// Every agent to offer: pi, then the known ones found on the PATH. The
    /// person's own are added on the main actor, when the look lands.
    nonisolated static func found() -> [AgentChoice] {
        var out = [piChoice()]
        for known in known {
            if let adapter = known.adapter {
                if let choice = adapterChoice(known, adapter) { out.append(choice) }
            } else if let path = path(of: known.program) {
                out.append(AgentChoice(id: known.id, name: known.name, path: path,
                                       spec: ACPSpec(id: known.id, name: known.name, path: path,
                                                     arguments: known.arguments, environment: known.environment,
                                                     startOptions: known.startOptions),
                                       ownTools: known.ownTools, login: known.login,
                                       modelIsTheAgentsOwn: known.modelIsTheAgentsOwn))
            }
        }
        return out
    }

    /// One an adapter carries: found when the person's own CLI — whose
    /// sign-in the adapter uses — and node are both on the PATH. Node runs
    /// the adapter; each agent is given its own tools off.
    nonisolated static func adapterChoice(_ known: KnownAgent, _ adapter: Adapter) -> AgentChoice? {
        guard firstExecutable(named: known.program) != nil,
              let node = firstExecutable(named: "node") else { return nil }
        var environment: [String: String] = [:]
        var sessionMeta: [String: Any]?
        switch adapter.agent {
        case "claude": sessionMeta = Adapters.claudeMeta
        case "codex": environment = Adapters.codexEnvironment()
        default: break
        }
        let spec = ACPSpec(id: known.id, name: known.name, path: node,
                           arguments: [Adapters.script(adapter).path],
                           environment: environment, sessionMeta: sessionMeta,
                           startOptions: known.startOptions)
        return AgentChoice(id: known.id, name: known.name, path: node, spec: spec,
                           ownTools: known.ownTools, login: known.login,
                           modelIsTheAgentsOwn: known.modelIsTheAgentsOwn, adapter: adapter)
    }

    /// The custom agents the person added, as choices.
    nonisolated static func customChoices() -> [AgentChoice] {
        customEntries().compactMap { entry in
            guard let id = entry["id"], let name = entry["name"], let command = entry["command"] else { return nil }
            return customChoice(id: id, name: name, command: command)
        }
    }

    /// pi itself: always offered, whether or not it is installed, so a chat
    /// on pi can say so. Its own tools are off through its flags (Pi.confined).
    nonisolated static func piChoice() -> AgentChoice {
        AgentChoice(id: "pi", name: "pi", path: Pi.locate()?.path, spec: nil, ownTools: .off, login: nil,
                    modelIsTheAgentsOwn: false)
    }

    /// One the person added, as it stands now: its program found as the path
    /// says, and the rest of the command line as its arguments.
    nonisolated static func customChoice(id: String, name: String, command: String) -> AgentChoice {
        let words = words(command) ?? []
        let program = words.first ?? ""
        let path = program.isEmpty ? nil : customPath(program)
        let spec = path.map { ACPSpec(id: id, name: name, path: $0, arguments: Array(words.dropFirst())) }
        return AgentChoice(id: id, name: name, path: path, spec: spec, ownTools: .refused, login: nil,
                           modelIsTheAgentsOwn: false)
    }

    /// Where a custom agent's program is: a full path or a "~/" path used as
    /// written (the home expanded), a bare name found on the PATH. A relative
    /// path is refused (nil), and so is a bare name not found.
    nonisolated static func customPath(_ program: String) -> String? {
        if program.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.path + String(program.dropFirst(1))
        }
        if program.hasPrefix("/") { return program }
        if program.contains("/") { return nil }
        return firstExecutable(named: program)
    }

    /// The name an id is known by, found or not: a known agent's, or a custom
    /// one's; nil when it isn't any agent's.
    nonisolated static func keptName(_ id: String) -> String? {
        if let known = known.first(where: { $0.id == id }) { return known.name }
        return customEntries().first { $0["id"] == id }?["name"]
    }

    /// The program an agent runs as, when it is a known or custom one: the
    /// first word of its command line. Nil for pi.
    nonisolated static func programName(_ choice: AgentChoice) -> String? {
        if let known = known.first(where: { $0.id == choice.id }) { return known.program }
        guard choice.custom, let entry = customEntries().first(where: { $0["id"] == choice.id }) else { return nil }
        return (words(entry["command"] ?? "") ?? []).first
    }

    /// The settings key an agent's remembered sign-in method is kept under.
    nonisolated static func signInKey(_ id: String) -> String { "chat.agents.signin." + id }
    /// The settings key an agent's last known state is kept under.
    nonisolated static func stateKey(_ id: String) -> String { "chat.agents.state." + id }
    /// The settings key an agent's last chosen model is kept under.
    nonisolated static func modelKey(_ id: String) -> String { "chat.agents.model." + id }
    /// The sign-in method the person used before, when there is one.
    nonisolated static func signIn(for id: String) -> String? { Store.settings.string(forKey: signInKey(id)) }
    /// The model the agent's last chat used, when there is one.
    nonisolated static func model(for id: String) -> String? { Store.settings.string(forKey: modelKey(id)) }

    /// Where a program is: a path named with a "/" is used as it is (it is
    /// the person's own path, not a name to look for), anything else on the PATH.
    nonisolated static func path(of program: String) -> String? {
        if program.contains("/") { return program }
        return firstExecutable(named: program)
    }

    /// The first executable called `name` on the PATH: the test world's when
    /// a test set one, the login shell's otherwise.
    nonisolated static func firstExecutable(named name: String) -> String? {
        if let path = searchPathForTests {
            return path.split(separator: ":").map(String.init)
                .map { $0 + "/" + name }
                .first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        return LoginShell.find(name)
    }

    /// The custom agents the person added, as written in Settings.
    nonisolated static func customEntries() -> [[String: String]] {
        (Store.settings.array(forKey: customKey) ?? []).compactMap { item in
            guard let item = item as? [String: Any],
                  let id = item["id"] as? String,
                  let name = item["name"] as? String,
                  let command = item["command"] as? String else { return nil }
            return ["id": id, "name": name, "command": command]
        }
    }

    /// The ids the person hid.
    nonisolated static func hiddenIDs() -> [String] {
        Store.settings.stringArray(forKey: hiddenKey) ?? []
    }

    /// A command line, split like a shell's words: whitespace separates,
    /// single and double quotes group, and a backslash keeps the character
    /// after it — except inside single quotes, where a backslash is just a
    /// character. Nil when a quote is left open: the line isn't valid.
    nonisolated static func words(_ line: String) -> [String]? {
        var out: [String] = []
        var word = ""
        var quote: Character?
        var started = false
        var escaped = false
        for character in line {
            if escaped {
                word.append(character)
                started = true
                escaped = false
                continue
            }
            if let open = quote {
                if character == open { quote = nil; continue }
                // Shell rules: inside single quotes a backslash is kept as it is.
                if open == "'" && character == "\\" { word.append(character); started = true; continue }
                word.append(character)
                started = true
                continue
            }
            if character == "\\" { escaped = true; continue }
            if character == "\"" || character == "'" { quote = character; started = true; continue }
            if character.isWhitespace {
                if started { out.append(word); word = ""; started = false }
                continue
            }
            word.append(character)
            started = true
        }
        guard quote == nil else { return nil }
        if started { out.append(word) }
        return out
    }
}
