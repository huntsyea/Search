import AppKit
import SwiftUI

// The chat, as the sidebar panel shows it (see Chats.swift for what a chat
// is). A bar with the chat's name — a menu of the others — a new one and
// the panel's hide, the panel's head while the chat shows;
// the conversation, the steps the agent took as single lines, as Claude in
// Chrome shows them; and a box to write in, with Stop while it works.

struct ChatPanel: View {
    @ObservedObject var browser: Browser
    /// The panel is on the window's left: its hide icon says so.
    var onLeft = false

    var body: some View {
        let chat = browser.chat ?? fresh
        ChatBody(browser: browser, chat: chat, onLeft: onLeft)
            .id(chat.id)
    }

    /// The chat the panel opens on: the last one, or a new one.
    private var fresh: Chat {
        let chat = Chats.all.first ?? Chats.make()
        DispatchQueue.main.async { if browser.chat == nil { browser.chat = chat } }
        return chat
    }
}

private struct ChatBody: View {
    @ObservedObject var browser: Browser
    @ObservedObject var chat: Chat
    let onLeft: Bool
    @State private var draft = ""
    @FocusState private var writing: Bool

    var body: some View {
        VStack(spacing: 0) {
            bar
            Rectangle().fill(Palette.hairline).frame(height: 1)
            conversation
            composer
        }
        .onAppear {
            chat.open(in: browser)
            chat.loadOptions()
            writing = true
        }
    }

    // MARK: - the bar

    private var bar: some View {
        HStack(spacing: 4) {
            Menu {
                Section("Chats") {
                    ForEach(Chats.all.prefix(30)) { other in
                        Button(other.title) { browser.chat = other }
                    }
                }
                if Chats.all.contains(where: { $0 === chat }) {
                    Divider()
                    Button("Delete This Chat", role: .destructive) {
                        Chats.delete(chat)
                        browser.chat = Chats.make()
                    }
                }
                // The panel's other panes — extensions' side panels — once
                // the chat's bar became the panel's head.
                let panels = browser.utilityPanes.filter { $0 != .chat }
                if !panels.isEmpty {
                    Divider()
                    Section("Side Panels") {
                        ForEach(panels, id: \.self) { pane in
                            Button(browser.utilityName(pane)) { browser.showUtility(pane) }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(chat.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            // As wide as the bar lets it be, and no wider: a long title is
            // cut short rather than pushing the column out of the window.
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(-1)
            Door(icon: "square.and.pencil", help: "New chat") {
                browser.chat = Chats.make()
            }
            UtilityHide(browser: browser, onLeft: onLeft)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 38)
    }

    // MARK: - the conversation

    private var conversation: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.items.isEmpty, chat.status == nil {
                        empty
                    }
                    ForEach(chat.items) { item in
                        ChatLine(item: item)
                            .id(item.id)
                    }
                    if let status = chat.status {
                        Text(status)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                    } else if chat.busy, chat.items.last.map({ $0.kind == .user || ($0.kind == .tool && $0.done) }) ?? true {
                        Thinking()
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: chat.items) { _, _ in reader.scrollTo("end", anchor: .bottom) }
            .onChange(of: chat.busy) { _, _ in reader.scrollTo("end", anchor: .bottom) }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask about this page")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.ink)
            Text("Or have it do things across your tabs: open pages, click, fill in forms. The agent is pi, on this Mac. It asks before it acts unless you let it act without asking.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    // MARK: - writing

    private var composer: some View {
        VStack(spacing: 6) {
            if let ask = chat.asking.first {
                AskCard(ask: ask, waiting: chat.asking.count - 1) { chat.answer($0) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if chat.items.isEmpty, chat.status == nil, !chat.busy, !sendable {
                // Only to start a conversation: once it's under way, the
                // page's suggestions would be in the way of it.
                PagePills(browser: browser) { send($0) }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(chat.busy ? "Working…" : "Ask about this page", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...8)
                    .focused($writing)
                    .onSubmit(send)
                    .padding(.vertical, 6)
                Button(action: chat.busy ? chat.stop : send) {
                    Image(systemName: chat.busy ? "stop.fill" : "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.ground)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(sendable || chat.busy ? Palette.ink : Palette.faint))
                }
                .buttonStyle(.plain)
                .disabled(!sendable && !chat.busy)
                .help(chat.busy ? "Stop" : "Send")
                .padding(.bottom, 3)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.wash))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            HStack(spacing: 6) {
                modeMenu
                if chat.busy {
                    Quick(chat.paused ? "Resume" : "Pause") { chat.paused ? chat.resume() : chat.pause() }
                        .help(chat.paused ? "Let pi go on" : "Hold pi before its next step; the page is yours meanwhile")
                }
                Spacer(minLength: 0)
                modelMenu
            }
        }
        .padding(10)
        .animation(Motion.settle, value: chat.asking.map(\.id))
    }

    /// Ask before acting, or act without asking (asked about the first time).
    private var modeMenu: some View {
        Menu {
            Button {
                chat.mode = .ask
            } label: {
                if chat.mode == .ask { Label("Ask before acting", systemImage: "checkmark") } else { Text("Ask before acting") }
            }
            Button {
                chat.mode = .act
            } label: {
                if chat.mode == .act { Label("Act without asking", systemImage: "checkmark") } else { Text("Act without asking") }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: chat.mode == .act ? "bolt.fill" : "hand.raised")
                    .font(.system(size: 10))
                Text(chat.mode == .act ? "Act without asking" : "Ask before acting")
                    .font(.system(size: 11))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(chat.mode == .act ? Palette.unsafe : Palette.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.leading, 4)
    }

    /// The model this chat's agent uses, and how hard it thinks.
    /// The choice is also where new chats start.
    private var modelMenu: some View {
        Menu {
            let model = chat.option("model")
            if model?.choices.isEmpty ?? true {
                Text("Starting \(chat.agentName)…")
            }
            ForEach(providers, id: \.self) { provider in
                Section(provider) {
                    ForEach(model?.choices.filter { $0.group == provider } ?? []) { choice in
                        Button {
                            chat.choose("model", choice.value)
                        } label: {
                            if choice.value == model?.current { Label(choice.name, systemImage: "checkmark") } else { Text(choice.name) }
                        }
                    }
                }
            }
            if let thinking = chat.option("thinking"), !thinking.choices.isEmpty {
                Divider()
                Section(thinking.name) {
                    ForEach(thinking.choices) { choice in
                        Button {
                            chat.choose("thinking", choice.value)
                        } label: {
                            if choice.value == thinking.current { Label(choice.name, systemImage: "checkmark") } else { Text(choice.name) }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(modelLabel)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(Palette.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(-1)
        .padding(.trailing, 4)
        .help("Model")
    }

    private var providers: [String] {
        var seen = Set<String>()
        return (chat.option("model")?.choices ?? []).compactMap { $0.group }.filter { seen.insert($0).inserted }
    }

    private var modelLabel: String {
        guard let model = chat.option("model"), let chosen = model.chosen else { return "Model" }
        if let level = chat.option("thinking")?.current, level != "off" { return "\(chosen.name) · \(level)" }
        return chosen.name
    }

    private var sendable: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard sendable, !chat.busy else { return }
        chat.browser = browser
        chat.send(draft)
        draft = ""
    }

    /// A pill's words, sent as if typed.
    private func send(_ text: String) {
        guard !chat.busy else { return }
        chat.browser = browser
        chat.send(text)
    }
}

/// Over the box, for the page in front: a summary, and what pi suggests
/// doing with this page in particular (PageSuggestions), sent when clicked.
private struct PagePills: View {
    @ObservedObject var browser: Browser
    let pick: (String) -> Void

    var body: some View {
        if let tab = browser.active {
            Pills(tab: tab, pick: pick)
        }
    }

    private struct Pills: View {
        @ObservedObject var tab: Tab
        @ObservedObject private var suggestions = PageSuggestions.shared
        let pick: (String) -> Void

        var body: some View {
            if let address = tab.pageAddress, ["http", "https", "file"].contains(address.scheme ?? "") {
                let key = address.absoluteString
                Flow(spacing: 6) {
                    pill(PageSuggestions.summary, icon: "text.alignleft")
                    if suggestions.address == key {
                        ForEach(suggestions.pills, id: \.self) { pill($0, icon: "sparkle") }
                        if suggestions.loading {
                            Text("Reading the page…")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.faint)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 5)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(Motion.settle, value: suggestions.pills)
                // Asked again once the page has loaded, and for each new one.
                .task(id: "\(tab.id)|\(key)|\(tab.loading)") {
                    guard !tab.loading else { return }
                    await suggestions.load(for: tab)
                }
            }
        }

        private func pill(_ text: String, icon: String) -> some View {
            Button { pick(text) } label: {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Palette.muted)
                    Text(text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Palette.wash))
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(text)
        }
    }
}

/// An act waiting for the person: what it would do and where, and the
/// answers Claude in Chrome gives — once, for this chat, always on the site.
private struct AskCard: View {
    let ask: Chat.Ask
    let waiting: Int
    let answer: (Chat.Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.unsafe)
                    .padding(.top, 1)
                Text("pi wants to \(ask.action)")
                    .lineLimit(3)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if waiting > 0 {
                Text("\(waiting) more waiting")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            HStack(spacing: 6) {
                Quick("Allow once") { answer(.once) }
                    .help("Just this once")
                Quick("This chat") { answer(.chat) }
                    .help("Anything on \(ask.site), for the rest of this chat")
                Quick("Always") { answer(.always) }
                    .help("Anything on \(ask.site), in every chat, until you take it back")
                Spacer(minLength: 0)
                Quick("Deny", tint: Palette.unsafe) { answer(.deny) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.ground))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }
}

/// Over the page while the chat's agent is working in the browser: who,
/// and Stop — as the recording pill says who records.
struct AgentPill: View {
    @ObservedObject var chat: Chat

    var body: some View {
        if chat.busy, chat.acting || !chat.asking.isEmpty {
            HStack(spacing: 8) {
                Circle().fill(chat.paused ? Palette.muted : Palette.unsafe).frame(width: 7, height: 7)
                Text(!chat.asking.isEmpty ? "pi is waiting for you in the chat" : chat.paused ? "pi is paused" : "pi is working in your tabs")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                if chat.asking.isEmpty {
                    Quick(chat.paused ? "Resume" : "Pause") { chat.paused ? chat.resume() : chat.pause() }
                }
                Quick("Stop") { chat.stop() }
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(Capsule().fill(Palette.ground))
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.1), radius: 10, y: 3)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// One line of the conversation.
private struct ChatLine: View {
    let item: Chat.Item
    @State private var open = false

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(item.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.wash))
            }
        case .assistant:
            Text(markdown(item.text))
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking:
            VStack(alignment: .leading, spacing: 4) {
                Button { open.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text(item.done ? "Thought" : "Thinking…")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                if open {
                    Text(item.text)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .tool:
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: item.failed ? "exclamationmark.circle" : item.done ? "checkmark.circle" : "circle.dotted")
                        .font(.system(size: 11))
                        .foregroundStyle(item.failed ? Palette.unsafe : Palette.muted)
                    Text(item.text)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                if item.failed, !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .padding(.leading, 17)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .error:
            Text(item.text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.unsafe)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .note:
            Text(item.text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
        }
    }

    /// Markdown as text: emphasis, code and links; paragraphs and lists kept
    /// as their lines.
    private func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Three dots while the agent works and nothing has come back yet.
private struct Thinking: View {
    @State private var on = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { n in
                Circle()
                    .fill(Palette.muted)
                    .frame(width: 5, height: 5)
                    .opacity(on ? 1 : 0.3)
                    .animation(Motion.reduced ? nil : .easeInOut(duration: 0.6).repeatForever().delay(Double(n) * 0.2), value: on)
            }
        }
        .padding(.vertical, 4)
        .onAppear { on = true }
    }
}
