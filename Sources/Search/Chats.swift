import Foundation

// The chats in the sidebar panel. A chat is its agent's session (pi's,
// today): the agent keeps the conversation itself, in its session file
// under Chats/sessions, and this keeps only what it takes to list the chats
// and open one again — chats.json: each chat's title, its session file, and
// when it was last used. Opening one starts the agent on that session and
// asks it for the messages.

@MainActor
final class Chat: ObservableObject, Identifiable {
    /// One line of the conversation as the panel draws it.
    struct Item: Identifiable, Equatable {
        enum Kind: Equatable { case user, assistant, thinking, tool, error, note }
        let id: String
        var kind: Kind
        var text: String
        /// For a tool: what it said when it failed.
        var detail = ""
        var done = true
        var failed = false
    }

    let id: UUID
    @Published var title: String
    @Published private(set) var items: [Item] = []
    /// From a message sent until pi says it has settled.
    @Published private(set) var busy = false
    /// A chat that has been written in, or listed at all: its agent is
    /// fixed, and a start for its menu alone doesn't count.
    var begun: Bool { busy || !items.isEmpty || Chats.all.contains(where: { $0 === self }) }
    /// "Starting pi…" and the like, while there is no answer to show yet.
    @Published private(set) var status: String?
    /// The agent asked the person to sign in, and how: the card over the box
    /// shows it. What was being done is kept to try again.
    @Published private(set) var signIn: AgentSignIn?
    /// The agent's ACP adapter isn't set up yet: the card over the box offers
    /// to install it, and what was being done is kept to try again.
    @Published private(set) var setUp: AgentNeedsSetUp?
    /// What was interrupted by the sign-in, done again on Try Again.
    enum Pending {
        case send(String)
        case open
        case option(String, String)
        /// The menu's start, before anything was sent.
        case load
    }
    private var waiting: Pending?
    /// Whether a message is waiting for a sign-in before it can be sent.
    var hasUnsent: Bool { if case .send = waiting { return true }; return false }
    var session: String?
    var updated: Date
    /// The window whose tabs the chat's tools act on.
    weak var browser: Browser?

    /// Ask before acting, or act without asking — as Claude in Chrome
    /// offers. Kept with the chat.
    enum Mode: String { case ask, act }
    @Published var mode: Mode = .ask {
        didSet { if mode != oldValue { Chats.save() } }
    }
    /// An act waiting for the person's answer, as the card over the box
    /// shows it. Calls made together wait in turn.
    struct Ask: Identifiable {
        let id = UUID()
        /// "click “Sign in” on github.com"
        let action: String
        /// The site it would act on, as permissions are kept: example.com.
        let site: String
        let answer: (Choice) -> Void
    }
    enum Choice: String { case once, chat, always, deny }
    @Published private(set) var asking: [Ask] = []
    /// Sites allowed for this chat, until Search quits.
    private var allowed: Set<String> = []
    /// Something was done in the browser since the last message: the pill
    /// over the page says so while the agent works.
    @Published private(set) var acting = false
    /// The tab group the chat's own tabs go in, when groups are on.
    private var group: UUID?
    /// Tabs marked as being acted on (Tab.agent), until the agent settles.
    private var marked: Set<Tab.ID> = []

    /// Paused: the agent's next step waits until it is resumed — the page
    /// is the person's meanwhile, as in Claude in Chrome. Stop still stops.
    @Published private(set) var paused = false
    private var held: [CheckedContinuation<Bool, Never>] = []

    /// Steps waiting for Resume now: what a test waits for before it stops a paused chat.
    var waitingSteps: Int { held.count }

    /// What the chat's agent offers, and what it uses: known once it runs.
    @Published private(set) var options: [AgentOption] = []

    /// The chat's agent by name, as the panel says it: "Starting pi…", or
    /// the name kept with a chat whose agent isn't here any more.
    private(set) var agentName: String
    /// Which agent the chat runs on: "pi", a known agent's id, or "custom.<uuid>".
    private(set) var agentID: String

    private var agent: ChatAgent
    private var link: AgentLink?
    /// The start whose agent the chat is listening to.
    private var current: UUID?
    /// The send now under way, so one the chat has moved on from can't clear
    /// a newer one's state.
    private var turn: UUID?
    /// Why an agent ended before it was held, for whoever sent to report.
    private var endedStarting: String?
    private var opened = false
    /// Bumped whenever the chat is closed or its agent is let go of: a set-up
    /// that finishes after that must not retry into a chat that moved on.
    private var life = 0
    /// Whether the session's history is on screen: a new chat has none, and
    /// a chat whose start failed has none yet.
    private var shown: Bool
    /// The start whose history is being heard, kept aside until it proves
    /// the start: a start that failed shows none of it.
    private var replaying: UUID?
    /// The history heard so far during a start, held until it succeeds, then
    /// shown once.
    private var history: [AgentSays] = []
    /// A session name heard before the link was held: given to it once it is.
    private var nameOnStart = false
    /// This start is a new chat, not a reopened one: it may take the agent's
    /// remembered model and fall back to pi.
    private var startedFresh = false
    /// For tests: the pi a fallback to pi starts, in place of the app's.
    static var piForTests: ChatPi?

    init(id: UUID = UUID(), title: String = "New chat", session: String? = nil, updated: Date = Date(), mode: Mode = .ask,
         agentID: String = "pi", agentName: String? = nil, agent: ChatAgent? = nil) {
        self.id = id
        self.title = title
        self.session = session
        self.updated = updated
        self.agentID = agentID
        let built = agent ?? Agents.shared.chatAgent(agentID, name: agentName)
        self.agent = built
        self.agentName = agentName ?? built.name
        self.shown = session == nil
        // The stored value itself: through the setter, a chat loaded in act
        // mode would save the list while the list is still being loaded.
        self._mode = Published(initialValue: mode)
    }

    // MARK: - asking

    @discardableResult
    func send(_ text: String) -> Bool {
        // While the sign-in card is up, sending would lose the message kept
        // for Try Again: it waits until the person deals with the card. The
        // same while the adapter needs setting up.
        guard signIn == nil, setUp == nil else { return false }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !busy else { return false }
        if title == "New chat" {
            // The message's start until pi has named the chat, in a few words.
            title = String(words.prefix(60))
            let page = browser?.active.flatMap { $0.pageAddress == nil ? nil : $0.label }
            Task {
                guard let named = await agent.title(words, page) else { return }
                title = named
                Chats.save()
                if session != nil, let link { link.name(named) }
            }
        }
        updated = Date()
        busy = true
        let mine = UUID()
        turn = mine
        Chats.remember(self)
        let message = context() + words
        Task {
            do {
                let link = try await ready()
                try await link.prompt(message)
            } catch {
                // A send the chat has moved on from mustn't touch the new one.
                guard turn == mine else { return }
                busy = false
                status = nil
                if let wanted = error as? AgentSignIn {
                    // The person is asked to sign in; their message is kept to
                    // send again once they have. No error line: it isn't one.
                    signIn = wanted
                    waiting = .send(words)
                } else if let wanted = error as? AgentNeedsSetUp {
                    // The adapter is offered; their message is kept the same
                    // way, and no error line is shown.
                    setUp = wanted
                    waiting = .send(words)
                } else {
                    items.append(Item(id: UUID().uuidString, kind: .error, text: error.localizedDescription))
                }
            }
        }
        return true
    }

    func stop() {
        dropAsks()
        release(false)
        guard busy, let link else { return }
        link.cancel()
    }

    // MARK: - permission

    /// Before an act on `url`'s site: nil when it may go ahead, else the
    /// words the agent is told — that the person didn't allow it.
    func permit(_ action: String, on url: URL?) async -> String? {
        // A website by its domain; a page with no host — a file, an
        // extension's page — by its kind.
        let site = url?.host().map { Chat.site($0.lowercased()) } ?? url?.scheme?.lowercased() ?? "this page"
        if mode == .act || allowed.contains(site) || Chat.alwaysAllowed(site) { return nil }
        return await withCheckedContinuation { done in
            let ask = Ask(action: action, site: site) { [weak self] choice in
                guard let self else { return done.resume(returning: "Stopped.") }
                switch choice {
                case .once: done.resume(returning: nil)
                case .chat:
                    self.allowed.insert(site)
                    done.resume(returning: nil)
                case .always:
                    Store.settings.set(true, forKey: Chat.grantKey(site))
                    done.resume(returning: nil)
                case .deny:
                    done.resume(returning: "The person didn't allow that. Stop and ask them what to do; don't try another way around it.")
                }
            }
            asking.append(ask)
        }
    }

    /// The card's buttons (and the bench's): the first act waiting answered,
    /// and the others for the same site with it when the answer covers them.
    func answer(_ choice: Choice) {
        guard let first = asking.first else { return }
        asking.removeFirst()
        first.answer(choice)
        if choice == .chat || choice == .always {
            let same = asking.filter { $0.site == first.site }
            asking.removeAll { $0.site == first.site }
            same.forEach { $0.answer(.once) }
        }
    }

    /// Every act still waiting, refused: the chat was stopped.
    func dropAsks() {
        let waiting = asking
        asking = []
        waiting.forEach { $0.answer(.deny) }
    }

    /// An act is going ahead, in `tab` when it has one: its row and page
    /// are marked until the agent settles.
    func acted(on tab: Tab? = nil) {
        acting = true
        guard let tab else { return }
        tab.agent = true
        marked.insert(tab.id)
    }

    private func unmark() {
        guard let browser else { marked = []; return }
        for tab in browser.tabs where marked.contains(tab.id) { tab.agent = false }
        marked = []
    }

    // MARK: - pausing

    func pause() {
        guard busy else { return }
        paused = true
    }

    func resume() {
        paused = false
        release(true)
    }

    /// Before each step: at once, or once resumed. False when the chat was
    /// stopped meanwhile — the step isn't taken.
    func whilePaused() async -> Bool {
        guard paused else { return true }
        return await withCheckedContinuation { held.append($0) }
    }

    private func release(_ go: Bool) {
        if !go { paused = false }
        let waiting = held
        held = []
        waiting.forEach { $0.resume(returning: go) }
    }

    // MARK: - options

    /// One of the agent's options by `category` — the model, how hard it
    /// thinks — when it has said one.
    func option(_ category: AgentOption.Category) -> AgentOption? { options.first { $0.category == category } }

    /// The model menu: this chat's model. New chats start on the one chosen
    /// in Settings › AI.
    func choose(_ option: String, _ value: String) {
        // What the person picked for this agent's model is used for its next
        // chat too; pi's comes from Settings, so only the others are kept.
        // An agent that keeps the model as its own default is left alone.
        if agentID != "pi", option == self.option(.model)?.id, !Agents.shared.modelIsTheAgentsOwn(agentID) {
            Agents.shared.remember(model: value, for: agentID)
        }
        Task {
            do {
                let link = try await ready()
                try await link.set(option, to: value)
            } catch {
                if let wanted = error as? AgentSignIn { signIn = wanted; waiting = .option(option, value) }
                else if let wanted = error as? AgentNeedsSetUp { setUp = wanted; waiting = .option(option, value) }
                else { items.append(Item(id: UUID().uuidString, kind: .error, text: error.localizedDescription)) }
            }
        }
    }

    /// The menu wants the list before anything was sent: the agent started
    /// for it. A start that needs a sign-in or its adapter shows the card, as
    /// a send does — the menu is the first thing a chosen agent does. Any
    /// other failure stays quiet: nothing was asked for.
    func loadOptions() {
        guard options.isEmpty else { return }
        Task {
            do {
                _ = try await ready(quietly: true)
            } catch let wanted as AgentSignIn {
                signIn = wanted
                if waiting == nil { waiting = .load }
            } catch let wanted as AgentNeedsSetUp {
                setUp = wanted
                if waiting == nil { waiting = .load }
            } catch {
                // Quiet: a menu is no reason to show an agent's failure.
            }
        }
    }

    /// A tab the agent opened goes in the chat's group, when groups are on,
    /// as Claude in Chrome keeps its tabs in a group of its own.
    func gather(_ tab: Tab) {
        guard let browser, browser.prefs.usesTabGroups, !tab.shy, tab.pin == nil else { return }
        if let group, browser.tabGroups.contains(where: { $0.id == group }) {
            browser.move(tab, toGroup: group)
        } else {
            let made = browser.addTabGroup(containing: tab)
            browser.renameTabGroup(made, to: agent.name + " · " + String(title.prefix(30)))
            group = made
        }
    }

    /// The site a permission is kept for: the registrable domain, so
    /// allowing github.com covers gist.github.com too.
    static func site(_ host: String) -> String { Vault.registrable(host) }
    static func grantKey(_ site: String) -> String { "agent.site." + site }
    static func alwaysAllowed(_ site: String) -> Bool { Store.settings.bool(forKey: grantKey(site)) }

    /// The sites answered "Always", for Settings to list and take back.
    static var alwaysSites: [String] {
        Store.settings.dictionaryRepresentation()
            .filter { $0.key.hasPrefix("agent.site.") && ($0.value as? Bool) == true }
            .map { String($0.key.dropFirst("agent.site.".count)) }
            .sorted()
    }

    static func forget(_ site: String) { Store.settings.removeObject(forKey: grantKey(site)) }

    /// The panel is showing this chat: its messages, from the agent, the first time.
    func open(in browser: Browser) {
        self.browser = browser
        guard !opened else { return }
        opened = true
        guard session != nil else { return }
        status = "Opening…"
        Task {
            do {
                _ = try await ready(quietly: true)
                status = nil
            } catch {
                status = nil
                if let wanted = error as? AgentSignIn { signIn = wanted; waiting = .open }
                else if let wanted = error as? AgentNeedsSetUp { setUp = wanted; waiting = .open }
                else { items.append(Item(id: UUID().uuidString, kind: .error, text: error.localizedDescription)) }
            }
        }
    }

    /// The chat's agent changed, before anything was sent: no message, no
    /// session, nothing busy. A link started already (the model menu starts
    /// one) is let go of, and the agent is built again from the new choice.
    /// False when it is too late to change.
    @discardableResult
    func use(_ id: String) -> Bool {
        guard !begun else { return false }
        close()
        agentID = id
        if let kept = Agents.shared.choice(id)?.name ?? Agents.keptName(id) { agentName = kept }
        agent = Agents.shared.chatAgent(id, name: agentName)
        options = []
        // The old agent opened a session as it started, only for its menu:
        // it is the agent's and empty, so it is let go of, not kept.
        session = nil
        return true
    }

    /// The person signed in with `method`: remembered for this agent's next
    /// chats, and this one's agent built again so it signs in as it starts,
    /// then the message that asked is sent again.
    func signIn(with method: String) {
        // The method is tried, not remembered yet: the agent's wrapper keeps
        // it only once a start that used it worked.
        close()
        agent = Agents.shared.chatAgent(agentID, name: agentName, signIn: method)
        signIn = nil
        retry()
    }

    /// Try what the sign-in interrupted again: the message, the open, or the
    /// option that asked for it. Nothing when there was none.
    func retry() {
        signIn = nil
        setUp = nil
        switch waiting {
        case .send(let text):
            // Let the message go only once the agent has taken it again.
            if send(text) { waiting = nil }
        case .open:
            waiting = nil
            opened = false
            if let browser { open(in: browser) }
        case .option(let option, let value):
            waiting = nil
            choose(option, value)
        case .load:
            waiting = nil
            loadOptions()
        case nil:
            break
        }
    }

    /// The person said no to signing in: the card goes, and what it
    /// interrupted with it.
    func dismissSignIn() {
        signIn = nil
        waiting = nil
    }

    /// Install the agent's ACP adapter, then try what asked for it again.
    /// The box says what is happening meanwhile; a failure is an error line.
    func setUpAdapter() {
        guard let wanted = setUp else { return }
        setUp = nil
        // What asked is retried only for the chat as it was: closed, deleted
        // or switched while the install ran, it belongs to no one.
        let mine = life
        Task {
            guard life == mine else { return }
            status = "Setting up \(wanted.agent)…"
            do {
                try await Adapters.setUp(wanted.adapter)
                guard life == mine else { return }
                status = nil
                retry()
            } catch {
                guard life == mine else { return }
                status = nil
                items.append(Item(id: UUID().uuidString, kind: .error, text: error.localizedDescription))
            }
        }
    }

    /// The person said no to setting up the adapter: the card goes, and what
    /// it interrupted with it.
    func dismissSetUp() {
        setUp = nil
        waiting = nil
    }

    /// pi let go of: closed, deleted, or idle. A chat closed while working
    /// is settled the same way, without an error line: the person closed it.
    func close() {
        life += 1
        // Let go first: the exit that stopping it brings is then not heard
        // as pi ending on its own, however soon it comes.
        let link = self.link
        self.link = nil
        current = nil
        // A start still in flight is forgotten too, so the next look starts
        // the agent now chosen; the old start stops its own link when it lands.
        starting = nil
        link?.stop()
        settle()
    }

    /// What the person is looking at, said ahead of what they typed: the
    /// tab in front. Taken off again when the chat is drawn.
    private func context() -> String {
        guard let browser, let tab = browser.active, let address = tab.pageAddress else { return "" }
        return "<browser>\nThe tab in front: “\(tab.label)” — \(address.absoluteString) (tab \(AgentTools.short(tab)))\n</browser>\n\n"
    }

    static func withoutContext(_ text: String) -> String {
        guard text.hasPrefix("<browser>"), let end = text.range(of: "</browser>") else { return text }
        return String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - the agent

    private func ready(quietly: Bool = false) async throws -> AgentLink {
        if let link { return link }
        if !quietly { status = "Starting \(agent.name)…" }
        // Asked again while starting (the model menu, then a message): the
        // one agent being started, not a second.
        if let starting { return try await starting.value }
        // The newest start's own token, so an earlier ready() that returns
        // later can't clear the one that has taken its place.
        startToken += 1
        let token = startToken
        let start = Task { try await launch() }
        starting = start
        defer { if startToken == token { starting = nil } }
        return try await start.value
    }

    private var starting: Task<AgentLink, Error>?
    private var startToken = 0

    private func launch() async throws -> AgentLink {
        // The agent chosen for a new chat may not be on this Mac, or the
        // first look may not have finished: a chat that has exchanged
        // nothing falls back to pi before anything is sent.
        if agentID != "pi" {
            await Agents.shared.ready()
            if items.isEmpty, session == nil, Agents.shared.choice(agentID) == nil {
                agentID = "pi"
                agentName = "pi"
                agent = Chat.piForTests.map { ChatAgent.pi($0) } ?? .pi()
            }
        }
        let start = UUID()
        current = start
        endedStarting = nil
        // A chat with no session is a new one: this start may take the
        // agent's remembered model.
        startedFresh = session == nil
        // The history a start says before returning is the session's, kept
        // aside until the start succeeds: a start that failed shows none of it.
        history = []
        replaying = start
        let link: AgentLink
        do {
            link = try await agent.start(id, session) { [weak self] said in
                if case let .tool(call, givenUp, reply) = said {
                    // An agent let go of is told no; one the chat holds acts in its window.
                    guard let self, self.current == start else {
                        return reply(["content": [["type": "text", "text": "Stopped."]], "isError": true,
                                      "details": ["summary": "Stopped."]])
                    }
                    return AgentTools.run(call, for: self, givenUp: givenUp, reply: reply)
                }
                self?.hear(said, from: start)
            }
        } catch {
            // Only the start that owns the buffer clears it.
            if replaying == start { replaying = nil; history = [] }
            throw error
        }
        // The agent ended while starting, or the chat let go of it meanwhile:
        // a start that failed, said once, by whoever sent.
        guard current == start else {
            if replaying == start { replaying = nil; history = [] }
            link.stop()
            defer { endedStarting = nil }
            throw PiProcess.Failure(why: endedStarting ?? "\(agent.name) stopped.")
        }
        // The history once, when it succeeds, and only by the start that owns
        // it: a step it began but never finished isn't left spinning either.
        if replaying == start {
            if !shown {
                shown = true
                history.forEach(handle)
                history = []
                for i in items.indices { items[i].done = true }
            }
            replaying = nil
        }
        // A new chat on another agent starts on the model its last chat used,
        // set before the link is handed out so the first message waits for it.
        if startedFresh, agentID != "pi", !Agents.shared.modelIsTheAgentsOwn(agentID),
           let remembered = Agents.model(for: agentID),
           let model = option(.model), remembered != model.current,
           model.choices.contains(where: { $0.value == remembered }) {
            try? await link.set(model.id, to: remembered)
        }
        self.link = link
        if nameOnStart {
            nameOnStart = false
            link.name(title)
        }
        status = nil
        return link
    }

    /// Everything the agent says, from the start it belongs to.
    private func hear(_ said: AgentSays, from start: UUID) {
        switch said {
        case .cancel:
            guard start == current else { return }
            dropAsks()
        case let .exit(why):
            guard start == current else { return }
            current = nil
            // Ended before it was held: whoever sent reports it, once.
            guard link != nil else {
                endedStarting = why.map { "\(agent.name) stopped: \($0)" } ?? "\(agent.name) stopped."
                return
            }
            link = nil
            let wasBusy = busy
            settle()
            if wasBusy { items.append(Item(id: UUID().uuidString, kind: .error, text: why.map { "\(agent.name) stopped: \($0)" } ?? "\(agent.name) stopped.")) }
        case .tool:
            // Answered where it was heard, so it still gets a reply.
            break
        default:
            guard start == current else { return }
            // The transcript said during a start is held aside until the
            // start succeeds; anything else — its session, its options — is
            // this start's, said at once. A session already shown hears its
            // history again when an agent starts again, and drops it.
            if replaying == start, Chat.isHistory(said) {
                if !shown { history.append(said) }
                return
            }
            handle(said)
        }
    }

    // MARK: - what pi says

    /// The person's message is done with, however it ended: nothing is
    /// busy, no act waits for an answer or a Resume, and the tabs acted on
    /// are unmarked.
    private func settle() {
        busy = false
        turn = nil
        acting = false
        dropAsks()
        release(false)
        unmark()
        status = nil
    }

    /// Whether what an agent says during a start is the session's transcript,
    /// which is held aside until the start proves it. The rest — its new
    /// session, its options, its name, its status, its settling — belongs to
    /// this start and is said at once.
    private static func isHistory(_ said: AgentSays) -> Bool {
        switch said {
        case .user, .text, .done, .toolStarted, .toolEnded, .line:
            return true
        case .session, .options, .named, .status, .settled, .tool, .cancel, .exit:
            return false
        }
    }

    /// Everything the agent says that the chat draws, once it is the start
    /// being listened to.
    private func handle(_ said: AgentSays) {
        switch said {
        case let .user(text):
            items.append(Item(id: UUID().uuidString, kind: .user, text: Chat.withoutContext(text)))
        case let .text(id, kind, text, whole, done):
            put(id, kind, text, whole: whole, done: done)
        case let .done(id):
            guard let at = items.firstIndex(where: { $0.id == id }) else { return }
            items[at].done = true
        case let .toolStarted(id, name, args):
            items.append(Item(id: "tool-" + id, kind: .tool, text: Chat.label(name, args), done: false))
        case let .toolEnded(id, failed, summary, detail):
            guard let at = items.firstIndex(where: { $0.id == "tool-" + id }) else { return }
            items[at].done = true
            items[at].failed = failed
            if let summary, !failed { items[at].text = summary }
            if failed { items[at].detail = detail }
        case let .line(kind, text):
            items.append(Item(id: UUID().uuidString, kind: kind, text: text))
        case .settled:
            settle()
            updated = Date()
            Chats.remember(self)
        case let .session(file):
            guard session == nil else { return }
            session = file
            // The session can be said while the link isn't held yet: the name
            // is given once it is.
            if let link { link.name(title) } else { nameOnStart = true }
            // A session alone doesn't list a chat: an agent started only for
            // its menu mustn't appear in the list with nothing in it. A chat
            // already listed is written down again with its session.
            if Chats.all.contains(where: { $0 === self }) { Chats.save() }
        case let .named(name):
            title = name
        case let .status(text):
            status = text
        case let .options(list):
            options = list
        case .tool, .cancel, .exit:
            break
        }
    }

    /// Words of an item: put in its place when `whole`, else added to it;
    /// and made done or not, as said.
    private func put(_ id: String, _ kind: Item.Kind, _ text: String, whole: Bool, done: Bool) {
        if let at = items.firstIndex(where: { $0.id == id }) {
            if whole { items[at].text = text } else { items[at].text += text }
            items[at].done = done
        } else {
            guard !text.isEmpty || kind == .assistant else { return }
            items.append(Item(id: id, kind: kind, text: text, done: done))
        }
    }

    // MARK: - words

    static func text(of content: Any?) -> String {
        if let text = content as? String { return text }
        return (content as? [[String: Any]] ?? [])
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
    }

    /// A step as the chat says it before it has finished.
    static func label(_ tool: String, _ args: [String: Any]) -> String { AgentTools.label(tool, args) }
}

/// Every chat, newest first, and the file they are listed in.
@MainActor
enum Chats {
    static var folder: URL { Store.folder.appendingPathComponent("Chats", isDirectory: true) }
    /// Settings › AI: the model new chats start on, the ones that suggest
    /// what to do with the page and name chats (empty: pi's default), and
    /// whether suggestions are made at all.
    static let modelKey = "chat.model"
    /// Settings › AI: the agent new chats start on (pi).
    static let agentKey = "chat.agent"
    static let suggestModelKey = "chat.suggest.model"
    static let titleModelKey = "chat.title.model"
    static let suggestsKey = "chat.suggests"
    /// The model Sort Tabs asks (TabSort.swift); empty: pi's default.
    static let sortModelKey = "tabs.sort.model"
    static var sessions: URL { folder.appendingPathComponent("sessions", isDirectory: true) }
    /// One chat's empty workspace folder, where an agent that keeps sessions
    /// by folder runs: the same each time, so it finds its session again.
    static func workspace(_ id: UUID) -> URL {
        folder.appendingPathComponent("Workspaces", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }
    /// Where an ACP chat's step lines are kept, by its session id with every
    /// character outside [A-Za-z0-9_-] replaced by "_".
    static func stepsFile(_ session: String) -> URL {
        let safe = String(session.map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber) || character == "_" || character == "-"
                ? character : "_"
        })
        return folder.appendingPathComponent("Steps", isDirectory: true).appendingPathComponent(safe + ".json")
    }
    private static var file: URL { folder.appendingPathComponent("chats.json") }

    private struct Entry: Codable {
        var id: UUID
        var title: String
        var session: String?
        var updated: Date
        var mode: String?
        var agent: String?
        var agentName: String?
    }

    private(set) static var all: [Chat] = load()

    /// A new chat, not listed until something is sent in it. It starts on the
    /// agent chosen in Settings › AI, pi otherwise. The choice is taken even
    /// before the first look has finished — whether it is hidden needs only
    /// the settings — and a chat whose agent isn't found falls back to pi
    /// when it starts.
    static func make() -> Chat {
        let chosen = Store.settings.string(forKey: agentKey)
        if let chosen, !chosen.isEmpty, !Agents.shared.isHidden(chosen) {
            return Chat(agentID: chosen, agentName: Agents.shared.choice(chosen)?.name ?? Agents.keptName(chosen))
        }
        return Chat()
    }

    /// Listed, or listed again: put first, and written down.
    static func remember(_ chat: Chat) {
        all.removeAll { $0 === chat }
        all.insert(chat, at: 0)
        save()
    }

    /// Gone from the list, its agent stopped, its session file removed (or
    /// its ACP step lines), and its workspace folder.
    static func delete(_ chat: Chat) {
        chat.close()
        all.removeAll { $0 === chat }
        if let session = chat.session {
            if session.hasPrefix(sessions.path) {
                try? FileManager.default.removeItem(atPath: session)
            } else {
                try? FileManager.default.removeItem(at: stepsFile(session))
            }
        }
        try? FileManager.default.removeItem(at: workspace(chat.id))
        save()
    }

    private static func load() -> [Chat] {
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.sorted { $0.updated > $1.updated }
            .map { Chat(id: $0.id, title: $0.title, session: $0.session, updated: $0.updated,
                        mode: $0.mode.flatMap(Chat.Mode.init(rawValue:)) ?? .ask,
                        agentID: $0.agent ?? "pi", agentName: $0.agentName) }
    }

    static func save() {
        let entries = all.filter { $0.session != nil || !$0.items.isEmpty }
            .map { Entry(id: $0.id, title: $0.title, session: $0.session, updated: $0.updated, mode: $0.mode.rawValue,
                         agent: $0.agentID, agentName: $0.agentName) }
        let file = file
        Disk.write(file) { try? JSONEncoder().encode(entries) }
    }
}
