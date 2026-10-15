import SwiftUI
import WebKit

// The sidebar panel: a column on the side away from the tabs — the right with
// the tabs across the top or down the left, the left with them down the
// right — for one thing at a time: an extension's side panel, or the chat.
//
// Off unless turned on in Settings › Tabs. Then ⌥⌘B shows or hides it, per
// window, opening on whatever it showed last. It goes while a page fills the
// screen and comes back after; ⌘S folds the tabs, never this.
//
// See docs/design/right-sidebar-and-agent.md for where this is going.

/// What the sidebar panel shows.
enum UtilityPane: Hashable {
    /// The chat about what is on screen.
    case chat
    /// An extension's side panel, by the extension's id.
    case panel(String)

    /// As it is remembered: "chat", or "panel:<id>".
    var key: String {
        switch self {
        case .chat: return "chat"
        case .panel(let id): return "panel:" + id
        }
    }

    init?(key: String) {
        if key == "chat" { self = .chat; return }
        guard key.hasPrefix("panel:"), key.count > 6 else { return nil }
        self = .panel(String(key.dropFirst(6)))
    }

    /// The one shown last, in any window: what ⌥⌘B opens on.
    static var last: UtilityPane? {
        get { Store.settings.string(forKey: "utility.last").flatMap(UtilityPane.init(key:)) }
        set { Store.settings.set(newValue?.key, forKey: "utility.last") }
    }
}

extension Browser {
    /// ⌥⌘B, and View › Show Sidebar Panel.
    func toggleUtility() {
        guard prefs.utilitySidebar else {
            settingsPage = .tabs
            tuning = true
            announce("Turn on Sidebar panel in Settings › Tabs")
            return
        }
        if utility != nil {
            utility = nil
        } else {
            let last = UtilityPane.last
            showUtility(last.flatMap { utilityPanes.contains($0) ? $0 : nil } ?? .chat)
        }
    }

    func showUtility(_ pane: UtilityPane) {
        guard prefs.utilitySidebar else { return }
        utility = pane
        UtilityPane.last = pane
    }

    /// What the panel can show: the chat, then each extension switched on
    /// that has a side panel, in the order they were added.
    var utilityPanes: [UtilityPane] {
        var panes: [UtilityPane] = [.chat]
        if #available(macOS 15.4, *) {
            let extensions = Extensions.shared
            for item in extensions.installed where item.enabled {
                guard let context = extensions.contexts[item.id], SidePanels.hasPanel(context) else { continue }
                panes.append(.panel(item.id))
            }
        }
        return panes
    }

    /// A pane by the name it shows.
    func utilityName(_ pane: UtilityPane) -> String {
        switch pane {
        case .chat:
            return "Chat"
        case .panel(let id):
            if #available(macOS 15.4, *), let item = Extensions.shared.installed.first(where: { $0.id == id }) {
                return item.name
            }
            return "Extension"
        }
    }
}

/// The sidebar icon that hides the panel, drawn on the side the panel is.
struct UtilityHide: View {
    @ObservedObject var browser: Browser
    let onLeft: Bool

    var body: some View {
        Door(icon: onLeft ? "sidebar.left" : "sidebar.right", help: "Hide the sidebar panel (⌥⌘B)") { browser.utility = nil }
    }
}

/// The column itself: a head naming what it shows, with the others a click
/// away and a cross, and what it shows under it. With the tabs down the
/// side it is a card on the window's ground, as the page is (see CardEdge).
struct UtilitySidebar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    let pane: UtilityPane
    /// On the window's left edge, rather than its right.
    let onLeft: Bool
    /// On the window's ground beside the page's card.
    let onFrame: Bool

    @State private var grabbed: CGFloat?
    @State private var onEdge = false

    var body: some View {
        VStack(spacing: 0) {
            // The chat's own bar is the head: its title, new chat, hide.
            if pane != .chat {
                head
                Rectangle().fill(Palette.hairline).frame(height: 1)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Whatever is in it, never wider than the column.
        .frame(maxWidth: .infinity)
        .clipped()
        .background(Palette.ground)
        .modifier(CardEdge(on: onFrame))
        // With the page as a card: the card's gap between the two cards, and
        // from the window's edges. The page gives up its own far gap to this
        // column (see ContentView.utilityRoom).
        .padding(.horizontal, onFrame ? Metrics.cardGap : 0)
        .padding(.bottom, onFrame ? Metrics.cardGap : 0)
        .frame(width: prefs.utilityWidth)
        .frame(maxHeight: .infinity)
        .background(onFrame ? Palette.frame : Palette.ground)
        .overlay(alignment: innerEdge) {
            if !onFrame { Rectangle().fill(Palette.hairline).frame(width: 1) }
        }
        .overlay(alignment: innerEdge) { edge }
    }

    /// The side facing the page.
    private var innerEdge: Alignment { onLeft ? .trailing : .leading }

    private var head: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(browser.utilityPanes, id: \.self) { item in
                    Button {
                        browser.showUtility(item)
                    } label: {
                        if item == pane {
                            Label(browser.utilityName(item), systemImage: "checkmark")
                        } else {
                            Text(browser.utilityName(item))
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: pane == .chat ? "bubble.left" : "puzzlepiece.extension")
                        .font(.system(size: 11, weight: .medium))
                    Text(browser.utilityName(pane))
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                }
                .foregroundStyle(Palette.ink)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(-1)
            UtilityHide(browser: browser, onLeft: onLeft)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 38)
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .chat:
            ChatPanel(browser: browser, onLeft: onLeft)
        case .panel(let id):
            if #available(macOS 15.4, *), let page = SidePanels.page(for: id, in: browser) {
                SidePanelView(page: page)
                    .id(ObjectIdentifier(page))
            } else {
                VStack(spacing: 0) {
                    Nothing("This extension has no side panel now.")
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// The column's edge, as the tab column's: pull it wider or narrower,
    /// double-click it to put it back.
    private var edge: some View {
        Rectangle()
            .fill(Palette.ink.opacity(onEdge || grabbed != nil ? 0.18 : 0))
            .frame(width: onEdge || grabbed != nil ? 2 : 1)
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { over in
                onEdge = over
                if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if grabbed == nil { grabbed = prefs.utilityWidth }
                        let delta = onLeft ? value.translation.width : -value.translation.width
                        let wanted = (grabbed ?? prefs.utilityWidth) + delta
                        prefs.utilityWidth = min(Metrics.utilityMax, max(Metrics.utilityMin, wanted))
                    }
                    .onEnded { _ in grabbed = nil }
            )
            .modifier(OneClick(double: true) {
                withAnimation(Motion.settle) { prefs.utilityWidth = Metrics.utility }
            })
            .animation(Motion.quick, value: onEdge)
    }
}
