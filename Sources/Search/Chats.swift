import Foundation

// The chats in the sidebar panel. A chat is a pi session: pi keeps the
// conversation itself, in its session file under Chats/sessions, and this
// keeps only what it takes to list the chats and open one again —
// chats.json: each chat's title, its session file, and when it was last
// used. Opening one starts pi on that session and asks it for the messages.

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
    /// "Starting pi…" and the like, while there is no answer to show yet.
    @Published private(set) var status: String?
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

    /// A model pi can use, as its list names it.
    struct Model: Hashable, Identifiable {
        let provider: String
        let id: String
        let name: String
        let reasoning: Bool
        var key: String { provider + "/" + id }
    }
    /// What pi has to offer, and what this chat uses: known once pi is running.
    @Published private(set) var models: [Model] = []
    @Published private(set) var model: Model?
    @Published private(set) var thinking: String?
    @Published private(set) var levels: [String] = []

    private let pi: ChatPi
    private var link: PiLink?
    /// The start whose pi the chat is listening to.
    private var current: UUID?
    /// Why a pi ended before it was held, for whoever sent to report.
    private var endedStarting: String?
    private var opened = false
    /// Content blocks of the assistant message streaming now, by index.
    private var streaming: [Int: String] = [:]
    private var messageCount = 0

    init(id: UUID = UUID(), title: String = "New chat", session: String? = nil, updated: Date = Date(), mode: Mode = .ask, pi: ChatPi? = nil) {
        self.id = id
        self.title = title
        self.session = session
        self.updated = updated
        self.pi = pi ?? .rpc
        // The stored value itself: through the setter, a chat loaded in act
        // mode would save the list while the list is still being loaded.
        self._mode = Published(initialValue: mode)
    }

    // MARK: - asking

    func send(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !busy else { return }
        if title == "New chat" {
            // The message's start until pi has named the chat, in a few words.
            title = String(words.prefix(60))
            let page = browser?.active.flatMap { $0.pageAddress == nil ? nil : $0.label }
            Task {
                guard let named = await pi.title(words, page) else { return }
                title = named
                Chats.save()
                if session != nil, let link {
                    _ = try? await link.request(["type": "set_session_name", "name": named])
                }
            }
        }
        updated = Date()
        busy = true
        Chats.remember(self)
        let message = context() + words
        Task {
            do {
                let link = try await ready()
                _ = try await link.request(["type": "prompt", "message": message])
                if session == nil, let state = try? await link.request(["type": "get_state"]),
                   let file = state["sessionFile"] as? String {
                    session = file
                    _ = try? await link.request(["type": "set_session_name", "name": title])
                    Chats.remember(self)
                }
            } catch {
                busy = false
                status = nil
                items.append(Item(id: UUID().uuidString, kind: .error, text: error.localizedDescription))
            }
        }
    }

    func stop() {
        dropAsks()
        release(false)
        guard busy, let link else { return }
        Task { _ = try? await link.request(["type": "abort"]) }
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

    // MARK: - models

    /// What pi offers and what it uses now, asked as it starts.
    private func learnModels(_ link: PiLink) async {
        if let list = try? await link.request(["type": "get_available_models"]),
           let raw = list["models"] as? [[String: Any]] {
            models = raw.compactMap { m in
                guard let provider = m["provider"] as? String, let id = m["id"] as? String else { return nil }
                return Model(provider: provider, id: id, name: m["name"] as? String ?? id, reasoning: m["reasoning"] as? Bool ?? false)
            }
        }
        await learnState(link)
    }

    private func learnState(_ link: PiLink) async {
        if let state = try? await link.request(["type": "get_state"]) {
            if let m = state["model"] as? [String: Any], let provider = m["provider"] as? String, let id = m["id"] as? String {
                model = models.first { $0.provider == provider && $0.id == id }
                    ?? Model(provider: provider, id: id, name: m["name"] as? String ?? id, reasoning: m["reasoning"] as? Bool ?? false)
            }
            thinking = state["thinkingLevel"] as? String
        }
        if let data = try? await link.request(["type": "get_available_thinking_levels"]) {
            levels = data["levels"] as? [String] ?? []
        }
    }

    /// The model menu: this chat's model. New chats start on the one chosen
    /// in Settings › AI.
    func choose(_ model: Model) {
        Task {
            do {
                let link = try await ready()
                _ = try await link.request(["type": "set_model", "provider": model.provider, "modelId": model.id])
                await learnState(link)
            } catch {
                items.append(Item(id: UUID().uuidString, kind: .error, text: error.localizedDescription))
            }
        }
    }

    func choose(thinking level: String) {
        Task {
            guard let link = try? await ready() else { return }
            _ = try? await link.request(["type": "set_thinking_level", "level": level])
            await learnState(link)
        }
    }

    /// The menu wants the list before anything was sent: pi started for it.
    func loadModels() {
        guard models.isEmpty else { return }
        Task { _ = try? await ready(quietly: true) }
    }

    /// A tab the agent opened goes in the chat's group, when groups are on,
    /// as Claude in Chrome keeps its tabs in a group of its own.
    func gather(_ tab: Tab) {
        guard let browser, browser.prefs.usesTabGroups, !tab.shy, tab.pin == nil else { return }
        if let group, browser.tabGroups.contains(where: { $0.id == group }) {
            browser.move(tab, toGroup: group)
        } else {
            let made = browser.addTabGroup(containing: tab)
            browser.renameTabGroup(made, to: "pi · " + String(title.prefix(30)))
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

    /// The panel is showing this chat: its messages, from pi, the first time.
    func open(in browser: Browser) {
        self.browser = browser
        guard !opened else { return }
        opened = true
        guard session != nil else { return }
        status = "Opening…"
        Task {
            do {
                let link = try await ready()
                let data = try await link.request(["type": "get_messages"])
                rebuild(data["messages"] as? [[String: Any]] ?? [])
                status = nil
            } catch {
                status = nil
                items.append(Item(id: UUID().uuidString, kind: .error, text: error.localizedDescription))
            }
        }
    }

    /// pi let go of: closed, deleted, or idle. A chat closed while working
    /// is settled the same way, without an error line: the person closed it.
    func close() {
        // Let go first: the exit that stopping it brings is then not heard
        // as pi ending on its own, however soon it comes.
        let link = self.link
        self.link = nil
        current = nil
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

    // MARK: - pi

    private func ready(quietly: Bool = false) async throws -> PiLink {
        if let link { return link }
        if !quietly { status = "Starting pi…" }
        // Asked again while starting (the model menu, then a message): the
        // one pi being started, not a second.
        if let starting { return try await starting.value }
        let start = Task { try await launch() }
        starting = start
        defer { starting = nil }
        return try await start.value
    }

    private var starting: Task<PiLink, Error>?

    private func launch() async throws -> PiLink {
        let start = UUID()
        current = start
        let link = try await pi.start(session.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }) { [weak self] said in
            if case let .tool(call, reply) = said {
                // A pi let go of is told no; one the chat holds acts in its window.
                guard let self, self.current == start else {
                    return reply(["content": [["type": "text", "text": "Stopped."]], "isError": true,
                                  "details": ["summary": "Stopped."]])
                }
                return AgentTools.run(call, for: self, reply: reply)
            }
            self?.hear(said, from: start)
        }
        // pi ended while starting, or the chat let go of it meanwhile: a
        // start that failed, said once, by whoever sent.
        guard current == start else {
            link.stop()
            defer { endedStarting = nil }
            throw PiProcess.Failure(why: endedStarting ?? "pi stopped.")
        }
        self.link = link
        status = nil
        Task { await learnModels(link) }
        return link
    }

    /// Everything pi says, from the start it belongs to.
    private func hear(_ said: PiSays, from start: UUID) {
        switch said {
        case let .event(event):
            guard start == current else { return }
            handle(event)
        case .cancel:
            guard start == current else { return }
            dropAsks()
        case let .exit(why):
            guard start == current else { return }
            current = nil
            // Ended before it was held: whoever sent reports it, once.
            guard link != nil else {
                endedStarting = why.map { "pi stopped: \($0)" } ?? "pi stopped."
                return
            }
            link = nil
            let wasBusy = busy
            settle()
            if wasBusy { items.append(Item(id: UUID().uuidString, kind: .error, text: why.map { "pi stopped: \($0)" } ?? "pi stopped.")) }
        case .tool:
            // Answered where pi said it, so it still gets a reply.
            break
        }
    }

    // MARK: - what pi says

    /// The person's message is done with, however it ended: nothing is
    /// busy, no act waits for an answer or a Resume, and the tabs acted on
    /// are unmarked.
    private func settle() {
        busy = false
        acting = false
        dropAsks()
        release(false)
        unmark()
        status = nil
    }

    private func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "message_start":
            guard let message = event["message"] as? [String: Any] else { return }
            if message["role"] as? String == "user" {
                let text = Chat.withoutContext(Chat.text(of: message["content"]))
                items.append(Item(id: UUID().uuidString, kind: .user, text: text))
            } else if message["role"] as? String == "assistant" {
                messageCount += 1
                streaming = [:]
            }
        case "message_update":
            guard let update = event["assistantMessageEvent"] as? [String: Any],
                  let index = update["contentIndex"] as? Int else { return }
            let kind = update["type"] as? String ?? ""
            let delta = update["delta"] as? String ?? ""
            if kind == "text_delta" {
                put(index, .assistant, append: delta, done: false)
            } else if kind == "thinking_delta" {
                put(index, .thinking, append: delta, done: false)
            } else if kind == "text_end", let content = update["content"] as? String {
                put(index, .assistant, replace: content, done: true)
            } else if kind == "thinking_end", let content = update["content"] as? String {
                put(index, .thinking, replace: content, done: true)
            }
        case "message_end":
            guard let message = event["message"] as? [String: Any], message["role"] as? String == "assistant" else { return }
            for key in streaming.keys { finish(key) }
            if let end = Chat.ending(message) { items.append(Item(id: UUID().uuidString, kind: end.kind, text: end.text)) }
        case "tool_execution_start":
            guard let call = event["toolCallId"] as? String else { return }
            let name = event["toolName"] as? String ?? ""
            items.append(Item(id: "tool-" + call, kind: .tool, text: Chat.label(name, event["args"] as? [String: Any] ?? [:]), done: false))
        case "tool_execution_end":
            guard let call = event["toolCallId"] as? String,
                  let at = items.firstIndex(where: { $0.id == "tool-" + call }) else { return }
            let result = event["result"] as? [String: Any] ?? [:]
            items[at].done = true
            items[at].failed = event["isError"] as? Bool ?? false
            if let summary = (result["details"] as? [String: Any])?["summary"] as? String, !items[at].failed {
                items[at].text = summary
            }
            if items[at].failed { items[at].detail = Chat.text(of: result["content"]) }
        case "auto_retry_start":
            status = "Retrying…"
        case "auto_retry_end":
            status = nil
        case "session_info_changed":
            if let name = event["name"] as? String, !name.isEmpty { title = name }
        case "agent_settled":
            settle()
            updated = Date()
            Chats.remember(self)
        default:
            break
        }
    }

    /// The line an assistant message ends on, live or reopened: the person's
    /// Stop, or the model failing; none when it just finished.
    private static func ending(_ message: [String: Any]) -> (kind: Item.Kind, text: String)? {
        var stop = message["stopReason"] as? String
        // Stopped between steps, the request in flight fails as an error:
        // still the person's Stop, not a failure.
        if stop == "error", (message["errorMessage"] as? String)?.localizedCaseInsensitiveContains("aborted") == true { stop = "aborted" }
        switch stop {
        case "error": return (.error, message["errorMessage"] as? String ?? "The model couldn't answer.")
        case "aborted": return (.note, "Stopped.")
        default: return nil
        }
    }

    private func put(_ index: Int, _ kind: Item.Kind, append: String = "", replace: String? = nil, done: Bool) {
        let key = "\(messageCount)-\(index)"
        if let at = items.firstIndex(where: { $0.id == key }) {
            if let replace { items[at].text = replace } else { items[at].text += append }
            items[at].done = done
        } else {
            guard !(replace ?? append).isEmpty || kind == .assistant else { return }
            items.append(Item(id: key, kind: kind, text: replace ?? append, done: done))
            streaming[index] = key
        }
    }

    private func finish(_ index: Int) {
        guard let key = streaming[index], let at = items.firstIndex(where: { $0.id == key }) else { return }
        items[at].done = true
    }

    /// A chat opened again: its messages as pi kept them.
    private func rebuild(_ messages: [[String: Any]]) {
        var out: [Item] = []
        for (n, message) in messages.enumerated() {
            switch message["role"] as? String {
            case "user":
                out.append(Item(id: "m\(n)", kind: .user, text: Chat.withoutContext(Chat.text(of: message["content"]))))
            case "assistant":
                for (i, block) in (message["content"] as? [[String: Any]] ?? []).enumerated() {
                    switch block["type"] as? String {
                    case "text":
                        let text = block["text"] as? String ?? ""
                        if !text.isEmpty { out.append(Item(id: "m\(n)-\(i)", kind: .assistant, text: text)) }
                    case "thinking":
                        let text = block["thinking"] as? String ?? ""
                        if !text.isEmpty { out.append(Item(id: "m\(n)-\(i)", kind: .thinking, text: text)) }
                    case "toolCall":
                        let id = block["id"] as? String ?? "\(n)-\(i)"
                        out.append(Item(id: "tool-" + id, kind: .tool,
                                        text: Chat.label(block["name"] as? String ?? "", block["arguments"] as? [String: Any] ?? [:])))
                    default:
                        break
                    }
                }
                if let end = Chat.ending(message) { out.append(Item(id: "m\(n)-end", kind: end.kind, text: end.text)) }
            case "toolResult":
                guard let call = message["toolCallId"] as? String,
                      let at = out.firstIndex(where: { $0.id == "tool-" + call }) else { continue }
                out[at].failed = message["isError"] as? Bool ?? false
                if let summary = (message["details"] as? [String: Any])?["summary"] as? String, !out[at].failed {
                    out[at].text = summary
                }
                if out[at].failed { out[at].detail = Chat.text(of: message["content"]) }
            default:
                break
            }
        }
        items = out
        messageCount = messages.count
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
    static let suggestModelKey = "chat.suggest.model"
    static let titleModelKey = "chat.title.model"
    static let suggestsKey = "chat.suggests"
    /// The model Sort Tabs asks (TabSort.swift); empty: pi's default.
    static let sortModelKey = "tabs.sort.model"
    static var sessions: URL { folder.appendingPathComponent("sessions", isDirectory: true) }
    private static var file: URL { folder.appendingPathComponent("chats.json") }

    private struct Entry: Codable {
        var id: UUID
        var title: String
        var session: String?
        var updated: Date
        var mode: String?
    }

    private(set) static var all: [Chat] = load()

    /// A new chat, not listed until something is sent in it.
    static func make() -> Chat { Chat() }

    /// Listed, or listed again: put first, and written down.
    static func remember(_ chat: Chat) {
        all.removeAll { $0 === chat }
        all.insert(chat, at: 0)
        save()
    }

    /// Gone from the list, its pi stopped and its session file removed.
    static func delete(_ chat: Chat) {
        chat.close()
        all.removeAll { $0 === chat }
        if let session = chat.session, session.hasPrefix(sessions.path) {
            try? FileManager.default.removeItem(atPath: session)
        }
        save()
    }

    private static func load() -> [Chat] {
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.sorted { $0.updated > $1.updated }
            .map { Chat(id: $0.id, title: $0.title, session: $0.session, updated: $0.updated,
                        mode: $0.mode.flatMap(Chat.Mode.init(rawValue:)) ?? .ask) }
    }

    static func save() {
        let entries = all.filter { $0.session != nil || !$0.items.isEmpty }
            .map { Entry(id: $0.id, title: $0.title, session: $0.session, updated: $0.updated, mode: $0.mode.rawValue) }
        let file = file
        Disk.write(file) { try? JSONEncoder().encode(entries) }
    }
}
