import Foundation

/// One space's tab row as a value: the tabs there, in order, with their
/// groups, pairs and pins. It keeps the rules `Browser` keeps — how the row is
/// arranged, what a group takes with it, when a pair stands — so a caller
/// never has to hold them by hand. It holds no `Tab` and touches no WebKit,
/// only ids and the few facts the rules need, so it can be put through its
/// paces on its own.
struct TabRow: Equatable {
    /// A pin is a square, or a pinned row under the squares (Tab.listed).
    enum Pin: Equatable { case square, listed }

    /// What the row knows about one tab: no page, no WebKit.
    struct Member: Equatable {
        let id: Tab.ID
        let shy: Bool        // a private tab
        let bench: Bool      // the bench's own tab
        var pin: Pin?
        var group: UUID?
        init(id: Tab.ID, shy: Bool = false, bench: Bool = false, pin: Pin? = nil, group: UUID? = nil) {
            self.id = id
            self.shy = shy
            self.bench = bench
            self.pin = pin
            self.group = group
        }
    }

    /// The settings the rules depend on: Settings › Tabs › groups, and Split View.
    struct Rules: Equatable {
        var groups: Bool
        var pairs: Bool
    }

    /// How soon a change should reach the session file. The case order is the
    /// order of urgency: `soon` before `now`.
    enum Urgency: Comparable { case soon, now }

    /// What changed since the change was last taken. `save` is how soon it
    /// should be written down; `goneGroups` are the groups that went away, in
    /// the order they went, so whoever holds the row can let go of what it
    /// keeps about a group that is gone — the name being typed, say.
    struct Change: Equatable {
        var save: Urgency
        var goneGroups: [UUID]
    }

    private(set) var members: [Member]   // the row, in order
    private(set) var groups: [TabGroup]  // in display order
    private(set) var pairs: [TabSplit]
    private(set) var rules: Rules
    private(set) var change: Change?

    init(members: [Member] = [], groups: [TabGroup] = [], pairs: [TabSplit] = [], rules: Rules) {
        self.members = members
        self.groups = groups
        self.pairs = pairs
        self.rules = rules
        change = nil
        // Split View on: the pairs are judged against the row as it stands,
        // before the arrangement could bring their pages back together.
        if rules.pairs { self.pairs = TabRow.standing(self.pairs, in: self.members) }
        // Whatever it was handed, it reads straight from here: a row is never
        // seen breaking a rule.
        _ = tidy()
    }

    // MARK: - reading

    /// The members' ids, in row order.
    var ids: [Tab.ID] { members.map(\.id) }

    func member(_ id: Tab.ID) -> Member? { members.first { $0.id == id } }

    func contains(_ id: Tab.ID) -> Bool { members.contains { $0.id == id } }

    /// The group a tab is shown in: none for a pin, an unknown tab, or a group
    /// this row doesn't have — which sits with the loose tabs rather than
    /// being lost.
    func group(of id: Tab.ID) -> UUID? {
        guard let member = member(id), member.pin == nil, let group = member.group,
              groups.contains(where: { $0.id == group }) else { return nil }
        return group
    }

    /// The non-pin tabs in a group, in row order; nil gives the loose ones.
    func tabs(in group: UUID?) -> [Tab.ID] {
        members.filter { $0.pin == nil && self.group(of: $0.id) == group }.map(\.id)
    }

    /// The pair a tab is in, while Split View is on. Turned off, pairs are
    /// kept, as groups are, and nothing acts on them until it is back on.
    func pair(of id: Tab.ID) -> TabSplit? {
        guard rules.pairs else { return nil }
        return pairs.first { $0.contains(id) }
    }

    /// The row as it reads: a pair's later pages share the first one's place.
    var shown: [Tab.ID] {
        guard rules.pairs else { return ids }
        return ids.filter { id in !pairs.contains { $0.contains(id) && $0.left != id } }
    }

    /// Whether a tab has a place of its own in the row: any tab but a pair's
    /// later pages.
    func standsInRow(_ id: Tab.ID) -> Bool {
        pair(of: id).map { $0.left == id } ?? true
    }

    /// The pairs that stand in the row as it is now: at least two pages, all
    /// here, next to each other in the pair's order, none pinned or the
    /// bench's, of one kind and one group, and no page in two pairs. Used where
    /// the pairs are judged before the row is arranged — Split View coming on,
    /// or a row handed in — so this runs ahead of `tidy()`.
    private static func standing(_ pairs: [TabSplit], in members: [Member]) -> [TabSplit] {
        var placed = Set<Tab.ID>()
        var kept: [TabSplit] = []
        for pair in pairs where TabRow.holds(pair, in: members) {
            guard pair.tabs.allSatisfy({ !placed.contains($0) }) else { continue }
            placed.formUnion(pair.tabs)
            kept.append(pair)
        }
        return kept
    }

    /// Whether a pair can hold at all, whatever place its pages are in: at
    /// least two distinct pages, all here, none pinned or the bench's, of one
    /// kind and one group, and no page already spoken for. The one thing left
    /// to the arrangement is whether the pages end up next to each other.
    private static func couldHold(_ pair: TabSplit, in members: [Member], claimed: inout Set<Tab.ID>) -> Bool {
        guard pair.tabs.count >= 2, Set(pair.tabs).count == pair.tabs.count,
              pair.tabs.allSatisfy({ !claimed.contains($0) }) else { return false }
        let pages = pair.tabs.compactMap { id in members.first { $0.id == id } }
        guard pages.count == pair.tabs.count,
              pages.allSatisfy({ $0.pin == nil && !$0.bench
                  && $0.shy == pages[0].shy && $0.group == pages[0].group }) else { return false }
        claimed.formUnion(pair.tabs)
        return true
    }

    /// Whether a pair can stand as it is in a row: all its pages there, next
    /// to each other in its order, none pinned or the bench's, of one kind and
    /// one group. A pair kept while Split View was off may have come apart.
    static func holds(_ pair: TabSplit, in members: [Member]) -> Bool {
        let places = pair.tabs.compactMap { id in members.firstIndex { $0.id == id } }
        guard pair.tabs.count >= 2, places.count == pair.tabs.count, let first = places.first,
              places == Array(first..<first + places.count) else { return false }
        let pages = places.map { members[$0] }
        return pages.allSatisfy { member in
            member.pin == nil && !member.bench
                && member.shy == pages[0].shy && member.group == pages[0].group
        }
    }

    /// The change since it was last taken, and clears it: whoever saves the
    /// session asks once.
    mutating func takeChange() -> Change? {
        defer { change = nil }
        return change
    }

    // MARK: - settings

    /// Settings › Tabs changed. Groups turned on arrange the row; Split View
    /// turned on drops the pairs that came apart while it was off, as
    /// `Browser.follow()` does. Turning things off keeps them, so nothing is
    /// recorded.
    mutating func setRules(_ rules: Rules) {
        guard rules != self.rules else { return }
        let before = self
        self.rules = rules
        var urgency: Urgency?
        if rules.groups && !before.rules.groups { urgency = .now }
        if rules.pairs && !before.rules.pairs { urgency = .now }
        // Split View coming on: a pair is judged against the row as it stands,
        // as `Browser.follow()` does, before the arrangement could move its
        // pages back together.
        if rules.pairs && !before.rules.pairs {
            pairs = TabRow.standing(pairs, in: members)
        }
        let gone = tidy()
        finish(urgency, since: before, gone: gone)
    }

    // MARK: - tabs coming and going

    /// A tab arriving: a link, a new one, or a peek kept. A link from a
    /// grouped tab joins its group, while groups are on — turned off, they
    /// sleep, and nothing new goes into one. A private or bench tab keeps its
    /// own place. A pin joins the end of its kind.
    mutating func open(_ member: Member, at index: Int, from source: Tab.ID? = nil) {
        guard !contains(member.id) else { return }
        let before = self
        var member = member
        if rules.groups, !member.shy, !member.bench, let source {
            member.group = self.member(source).flatMap(\.group)
        }
        members.insert(member, at: insertionIndex(index, for: member))
        let gone = tidy()
        finish(.soon, since: before, gone: gone)
    }

    /// A tab coming back, from ⇧⌘T or the History menu. Its group is kept only
    /// while groups are on and it is there to go into; a group Close Group took
    /// comes back first, unfolded, at the index it left.
    mutating func reopen(_ member: Member, at index: Int, closedGroup: (group: TabGroup, at: Int)? = nil) {
        guard !contains(member.id) else { return }
        let before = self
        var member = member
        var cameBack = false
        if rules.groups, let id = member.group {
            if groups.contains(where: { $0.id == id }) {
                // Still here: back into it.
            } else if let closed = closedGroup, closed.group.id == id {
                var group = closed.group
                group.collapsed = false
                groups.insert(group, at: min(closed.at, groups.count))
                cameBack = true
            } else {
                member.group = nil
            }
        } else {
            member.group = nil
        }
        members.insert(member, at: insertionIndex(index, for: member))
        let gone = tidy()
        finish(cameBack ? .now : .soon, since: before, gone: gone)
    }

    /// A tab closed. Its pair goes with it; its group goes if it was the last
    /// ordinary tab in it.
    mutating func remove(_ id: Tab.ID) {
        guard let index = members.firstIndex(where: { $0.id == id }) else { return }
        let before = self
        members.remove(at: index)
        pairs.removeAll { $0.contains(id) }
        let gone = tidy()
        finish(.soon, since: before, gone: gone)
    }

    // MARK: - groups

    /// A new group around some tabs, as the tab menu and Sort Tabs make one.
    /// Nothing joins from a pin, a private tab or the bench's, and a group
    /// nothing can join is no group at all.
    @discardableResult
    mutating func addGroup(named name: String? = nil, containing ids: [Tab.ID]) -> UUID? {
        let joinable = ids.compactMap { member($0) }
            .filter { $0.pin == nil && !$0.shy && !$0.bench }
        guard !joinable.isEmpty else { return nil }
        let before = self
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let groupName = trimmed.isEmpty ? "Group \(groups.count + 1)" : trimmed
        let id = UUID()
        groups.append(TabGroup(id: id, name: groupName, collapsed: false))
        // A pair is one place in the row: both halves go, and stay a pair.
        var moving = Set<Tab.ID>()
        for member in joinable {
            moving.insert(member.id)
            if let inPair = pair(of: member.id) { moving.formUnion(inPair.tabs) }
        }
        for index in members.indices where moving.contains(members[index].id) {
            members[index].group = id
        }
        let gone = tidy()
        finish(.now, since: before, gone: gone)
        return id
    }

    /// A tab moved into a group, or out of one. A pair is one place in the
    /// row: both halves go together. The group it lands in is unfolded, so you
    /// see what you moved.
    mutating func join(_ id: Tab.ID, group: UUID?) {
        guard let index = members.firstIndex(where: { $0.id == id }),
              members[index].pin == nil, !members[index].shy, !members[index].bench,
              group == nil || groups.contains(where: { $0.id == group }),
              members[index].group != group else { return }
        let before = self
        var moving: Set<Tab.ID> = [id]
        if let inPair = pair(of: id) { moving.formUnion(inPair.tabs) }
        for index in members.indices where moving.contains(members[index].id) {
            members[index].group = group
        }
        if let group, let at = groups.firstIndex(where: { $0.id == group }) {
            groups[at].collapsed = false
        }
        let gone = tidy()
        finish(.now, since: before, gone: gone)
    }

    /// A group renamed. A name that is only spaces is no name, and leaves it
    /// as it was.
    mutating func renameGroup(_ id: UUID, to name: String) {
        guard let at = groups.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, groups[at].name != trimmed else { return }
        let before = self
        groups[at].name = trimmed
        let gone = tidy()
        finish(.now, since: before, gone: gone)
    }

    /// Folded away, or open again.
    mutating func setFolded(_ id: UUID, _ folded: Bool) {
        guard let at = groups.firstIndex(where: { $0.id == id }), groups[at].collapsed != folded else { return }
        let before = self
        groups[at].collapsed = folded
        let gone = tidy()
        finish(.now, since: before, gone: gone)
    }

    /// A group taken apart: its tabs go loose, and the group itself is gone,
    /// named in the change so whoever holds the row can let go of what it
    /// keeps about the group.
    mutating func ungroup(_ id: UUID) {
        guard groups.contains(where: { $0.id == id }) else { return }
        let before = self
        for index in members.indices where members[index].group == id {
            members[index].group = nil
        }
        groups.removeAll { $0.id == id }
        let gone = [id] + tidy()
        finish(.now, since: before, gone: gone)
    }

    /// A group moved among the groups. Its tabs come with it.
    mutating func moveGroup(_ id: UUID, to index: Int) {
        guard let from = groups.firstIndex(where: { $0.id == id }),
              groups.indices.contains(index), from != index else { return }
        let before = self
        groups.move(fromOffsets: IndexSet(integer: from), toOffset: index > from ? index + 1 : index)
        let gone = tidy()
        finish(.now, since: before, gone: gone)
    }

    /// The row put back as `before` found it, as Sort Tabs' Undo does. Each
    /// member that was there takes its group back; the order follows the old
    /// one, tabs opened since after the rest, and a group whose tabs all closed
    /// since goes as it would have.
    mutating func restore(_ before: TabRow) {
        let was = self
        // A group this row has that the snapshot didn't goes with the restore;
        // the change names it, so whoever holds the row can let go of it.
        let kept = Set(before.groups.map(\.id))
        var gone = groups.map(\.id).filter { !kept.contains($0) }
        for index in members.indices {
            // The old group is taken as it was, nil included: a tab Sort Tabs
            // moved into one of your groups must go loose again on Undo.
            if let member = before.member(members[index].id) {
                members[index].group = member.group
            }
        }
        groups = before.groups
        let place = Dictionary(uniqueKeysWithValues: before.members.enumerated().map { ($1.id, $0) })
        let count = before.members.count
        members = members.enumerated()
            .sorted { (place[$0.element.id] ?? count + $0.offset) < (place[$1.element.id] ?? count + $1.offset) }
            .map(\.element)
        gone.append(contentsOf: tidy().filter { !gone.contains($0) })
        finish(.now, since: was, gone: gone)
    }

    // MARK: - pins and pairs

    /// A tab pinned, unpinned, or moved between the squares and the pinned
    /// rows. A pin leaves its pair and its group, and takes its place among
    /// the pins: a square at the end of the squares, a pinned row at the end
    /// of the rows, and a square made a row at the head of the rows.
    mutating func setPin(_ id: Tab.ID, _ pin: Pin?) {
        guard let index = members.firstIndex(where: { $0.id == id }),
              !members[index].shy, members[index].pin != pin else { return }
        let before = self
        let was = members[index].pin
        if let pin {
            members[index].pin = pin
            if was == nil {
                // A pin is in neither a pair nor a group.
                pairs.removeAll { $0.contains(id) }
                members[index].group = nil
            }
            settlePin(id, first: was == .square && pin == .listed)
        } else {
            members[index].pin = nil
            settlePin(id)
        }
        let gone = tidy()
        finish(.now, since: before, gone: gone)
    }

    /// A pair made, as Start Split View does with a new page or the row's half
    /// of a drag. Its pages come together in the pair's order where the anchor
    /// stood, and every one takes the anchor's group. Any pair they were in
    /// goes first.
    mutating func addPair(_ pair: TabSplit, keeping anchor: Tab.ID) {
        let pages = pair.tabs
        let found = pages.compactMap { self.member($0) }
        guard pages.count >= 2, found.count == pages.count, pages.contains(anchor),
              found.allSatisfy({ $0.pin == nil && !$0.bench }),
              Set(found.map(\.shy)).count == 1,
              let origin = members.firstIndex(where: { $0.id == anchor }) else { return }
        let before = self
        pairs.removeAll { existing in pages.contains { existing.contains($0) } }
        let group = self.member(anchor)?.group
        for index in members.indices where pages.contains(members[index].id) {
            members[index].group = group
        }
        let block = pages.compactMap { id in members.first { $0.id == id } }
        let at = members[..<origin].filter { !pages.contains($0.id) }.count
        members = members.filter { !pages.contains($0.id) }
        members.insert(contentsOf: block, at: min(at, members.count))
        pairs.append(pair)
        let gone = tidy()
        finish(.soon, since: before, gone: gone)
    }

    /// A pair taken apart, as closing one page or dragging it out does.
    mutating func removePair(containing id: Tab.ID) {
        guard pairs.contains(where: { $0.contains(id) }) else { return }
        let before = self
        pairs.removeAll { $0.contains(id) }
        let gone = tidy()
        finish(.soon, since: before, gone: gone)
    }

    /// A tab dragged onto the row: before another tab, or at the end when it
    /// was dropped on the empty space below. A pin stays among its own kind,
    /// and a pair is one place, so a tab dropped on a page of a pair lands
    /// before the pair rather than between its pages. A tab dropped before a
    /// tab takes that tab's group. `pin`: the dragged member is a pin and this
    /// is given, its kind becomes that before it is placed, as a pin dragged
    /// across the hidden line between the squares and the pinned rows does.
    mutating func drop(_ id: Tab.ID, before target: Tab.ID?, as pin: Pin? = nil) {
        guard let sourceIndex = members.firstIndex(where: { $0.id == id }) else { return }
        if let target {
            guard target != id,
                  let targetIndex = members.firstIndex(where: { $0.id == target }),
                  pair(of: id)?.contains(target) != true,
                  (members[sourceIndex].pin == nil) == (members[targetIndex].pin == nil) else { return }
            // The pair the target is in is one place: land before its first
            // page, whatever page of it the pointer was over.
            let targetStart = pair(of: target).flatMap { inPair in members.firstIndex { $0.id == inPair.left } }
                ?? targetIndex
            let before = self
            pairs.removeAll { $0.contains(id) }
            members[sourceIndex].group = members[targetIndex].group
            if let pin, members[sourceIndex].pin != nil { members[sourceIndex].pin = pin }
            let dragged = members.remove(at: sourceIndex)
            members.insert(dragged, at: sourceIndex < targetStart ? targetStart - 1 : targetStart)
            let gone = tidy()
            finish(.soon, since: before, gone: gone)
        } else {
            let before = self
            pairs.removeAll { $0.contains(id) }
            if let pin, members[sourceIndex].pin != nil { members[sourceIndex].pin = pin }
            let dragged = members.remove(at: sourceIndex)
            // A loose tab goes to the end; a pin goes at the end of its kind,
            // so a square stays among squares and a pinned row among rows.
            let amongPins = members.filter {
                $0.pin != nil && (dragged.pin == .listed || $0.pin == .square)
            }.count
            members.insert(dragged, at: dragged.pin == nil ? members.count : amongPins)
            let gone = tidy()
            finish(.soon, since: before, gone: gone)
        }
    }

    /// A tab dragged along the row as it is shown: the tab, or the whole pair
    /// it is in, takes the place the pointer is over. A pair is one place, so
    /// dropping onto a page lands beside the pair, never between its pages.
    /// `pin`: the dragged member is a pin and this is given, its kind becomes
    /// that before it is placed, as a pin dragged across the hidden line
    /// between the squares and the pinned rows does.
    mutating func moveShown(_ id: Tab.ID, to index: Int, as pin: Pin? = nil) {
        let shown = self.shown
        guard shown.indices.contains(index),
              let representative = pair(of: id)?.left ?? (contains(id) ? id : nil),
              let from = shown.firstIndex(of: representative), from != index,
              let anchor = member(shown[index]) else { return }
        var moving: [Member]
        if let inPair = pair(of: id) {
            moving = members.filter { inPair.contains($0.id) }
        } else if let only = member(id) {
            moving = [only]
        } else {
            return
        }
        guard moving.allSatisfy({ ($0.pin == nil) == (anchor.pin == nil) }) else { return }
        // The kind, before it is placed: a pin dragged across the hidden line
        // lands as the kind it was dropped among, and the stable partition in
        // `tidy` keeps it there. Every moving member is a pin then, since a
        // pair holds none.
        if let pin, moving.allSatisfy({ $0.pin != nil }) {
            for at in moving.indices { moving[at].pin = pin }
        }
        let targetSize = pair(of: anchor.id)?.tabs.count ?? 1
        let remaining = members.filter { member in !moving.contains { $0.id == member.id } }
        guard let target = remaining.firstIndex(where: { $0.id == anchor.id }) else { return }
        let before = self
        members = remaining
        members.insert(contentsOf: moving, at: from < index ? target + targetSize : target)
        let gone = tidy()
        finish(.soon, since: before, gone: gone)
    }

    /// The divider between a pair's pages dragged: each page's share of the
    /// stage. Shares that can't be shown, or a list that doesn't fit the
    /// pages, leave the pair as it was.
    mutating func setPairSizes(_ pair: UUID, _ sizes: [Double]) {
        guard let index = pairs.firstIndex(where: { $0.id == pair }),
              sizes.count == pairs[index].tabs.count,
              sizes.allSatisfy(\.isFinite) else { return }
        let clamped = TabSplit.clamp(sizes)
        guard pairs[index].sizes != clamped else { return }
        let before = self
        pairs[index].sizes = clamped
        let gone = tidy()
        finish(.soon, since: before, gone: gone)
    }

    /// The page of a pair just looked at, to come back to when the pair is
    /// chosen again. A tab in no pair has no other page to come back to.
    mutating func focusPage(_ id: Tab.ID) {
        guard let index = pairs.firstIndex(where: { $0.contains(id) }),
              pairs[index].focused != id else { return }
        let before = self
        pairs[index].focused = id
        let gone = tidy()
        finish(.soon, since: before, gone: gone)
    }

    /// The divider's menu › Swap Pages: a pair's pages and their shares change
    /// places, and the row keeps the pair where it stood.
    mutating func swapPair(_ pair: UUID) {
        guard let index = pairs.firstIndex(where: { $0.id == pair }) else { return }
        let found = pairs[index]
        let moving = found.tabs.compactMap { member($0) }
        guard moving.count == found.tabs.count,
              let start = members.firstIndex(where: { $0.id == found.left }) else { return }
        let before = self
        pairs[index].tabs.reverse()
        pairs[index].sizes.reverse()
        members.removeAll { found.contains($0.id) }
        members.insert(contentsOf: moving.reversed(), at: min(start, members.count))
        let gone = tidy()
        finish(.soon, since: before, gone: gone)
    }

    /// A tab taking another's place in the row, as an extension's page going
    /// to the web, or an open tab filling a pair's empty page. It stands where
    /// the old one stood, takes its group and its place in the pair, and the
    /// old one is gone.
    mutating func replace(_ old: Tab.ID, with new: Member) {
        guard members.contains(where: { $0.id == old }), new.id != old else { return }
        let before = self
        var incoming = new
        // A tab already in the row fills the place from wherever it was; its
        // old group goes if that left it empty.
        if let at = members.firstIndex(where: { $0.id == new.id }) {
            pairs.removeAll { $0.contains(new.id) }
            members.remove(at: at)
        }
        guard let place = members.firstIndex(where: { $0.id == old }) else { return }
        incoming.group = members[place].group
        if let index = pairs.firstIndex(where: { $0.contains(old) }) {
            pairs[index].replace(old, with: new.id)
        }
        members[place] = incoming
        let gone = tidy()
        finish(.soon, since: before, gone: gone)
    }

    /// Another window changed the space's pins: the pin section becomes that
    /// list, in its order, and every other tab keeps its place after them. A
    /// pin the list doesn't name goes, and one it names but this row doesn't
    /// have comes in. The list is another window's copy of what is already
    /// saved, so it can wait for the delay.
    mutating func setPins(_ pins: [Member]) {
        let wanted = pins.filter { $0.pin != nil && !$0.shy }
        var rest = members.filter { $0.pin == nil || $0.shy }
        var section: [Member] = []
        for pin in wanted {
            if let existing = members.first(where: { $0.id == pin.id }) {
                var member = existing
                member.pin = pin.pin
                section.append(member)
                rest.removeAll { $0.id == pin.id }
            } else {
                section.append(pin)
            }
        }
        let before = self
        members = section + rest
        let gone = tidy()
        finish(.soon, since: before, gone: gone)
    }

    // MARK: - the rules themselves

    /// One place for the urgency table, so every action says when it is worth
    /// saving: a group, and a pin you make or move, are saved at once — they
    /// live in their own file and are shared by every window — while the row's
    /// order, its pairs, and the pins another window sends (`setPins`) can wait
    /// for the delay. A group that went away, or came back, can't wait either.
    /// An action that changed nothing records nothing.
    private mutating func finish(_ urgency: Urgency?, since before: TabRow, gone: [UUID] = []) {
        guard self != before, let urgency else { return }
        var merged = change ?? Change(save: urgency, goneGroups: [])
        merged.save = max(merged.save, urgency)
        if !gone.isEmpty { merged.save = max(merged.save, .now) }
        merged.goneGroups.append(contentsOf: gone)
        change = merged
    }

    /// Puts the row straight: unique ids, a pin in no group, a group with at
    /// least one ordinary tab, the pins first, the row arranged, and only
    /// pairs that still hold. Returns the groups that went away, in order.
    private mutating func tidy() -> [UUID] {
        // One of each id; the first place wins.
        var seen = Set<Tab.ID>()
        members = members.filter { seen.insert($0.id).inserted }

        // R2: a pin is never in a group, and a group must be one this row has.
        let known = Set(groups.map(\.id))
        for index in members.indices {
            if members[index].pin != nil {
                members[index].group = nil
            } else if let group = members[index].group, !known.contains(group) {
                members[index].group = nil
            }
        }

        // R3: a group lasts as long as its ordinary tabs; the last one gone,
        // it goes too, and the change carries it.
        let holding = Set(members.filter { $0.pin == nil }.compactMap(\.group))
        let gone = groups.map(\.id).filter { !holding.contains($0) }
        groups = groups.filter { holding.contains($0.id) }

        // R4: the pins at the head, squares before pinned rows, everything
        // else as it was.
        let squares = members.filter { $0.pin == .square }
        let rows = members.filter { $0.pin == .listed }
        let rest = members.filter { $0.pin == nil }
        members = squares + rows + rest

        // R6, first part: while Split View is on, a pair that can't hold
        // however the row is arranged goes now — before the arrangement, which
        // would otherwise try to make a place for its pages.
        if rules.pairs {
            var claimed = Set<Tab.ID>()
            var possible: [TabSplit] = []
            for pair in pairs where TabRow.couldHold(pair, in: members, claimed: &claimed) {
                possible.append(pair)
            }
            pairs = possible
        }

        // R5: with groups on, the row in the order it is shown. This comes
        // before the rest of the pairs are judged, because the arrangement
        // itself may put a pair's pages back together.
        arrange()

        // R6, second part: a pair still apart goes, and the row is put straight
        // once more, because a page let go of belongs in its own group's
        // section.
        if rules.pairs {
            let count = pairs.count
            pairs = pairs.filter { TabRow.holds($0, in: members) }
            if pairs.count != count { arrange() }
        }

        return gone
    }

    /// The row in the order it is shown: the pins, each group's tabs in the
    /// groups' order, then the tabs in none. Each pair keeps the first page's
    /// place with its later pages beside it. Nothing while groups are off.
    private mutating func arrange() {
        guard rules.groups else { return }
        let representatives = shown
        let pins = representatives.filter { member($0)?.pin != nil }
        let grouped = groups.flatMap { group in representatives.filter { self.group(of: $0) == group.id } }
        let ungrouped = representatives.filter { member($0)?.pin == nil && group(of: $0) == nil }
        let order = (pins + grouped + ungrouped).flatMap { id -> [Tab.ID] in
            guard let inPair = pair(of: id), inPair.left == id else { return [id] }
            return inPair.tabs
        }
        // Every id once: the first place wins. Only pairs that can hold reach
        // here, so no page is lost or listed twice; this is a guard against a
        // row handed in already doubled.
        var seen = Set<Tab.ID>()
        let settled = order.compactMap { id -> Member? in
            guard seen.insert(id).inserted else { return nil }
            return member(id)
        }
        guard settled.map(\.id) != ids else { return }
        members = settled
    }

    /// Where a new member goes: no further than the end, and never inside a
    /// pair — a pair's later page moves the place one on. A tab that isn't a
    /// pin never lands among the pins: it comes at least after all of them.
    /// A pin goes at the end of its kind.
    private func insertionIndex(_ proposed: Int, for member: Member) -> Int {
        if let pin = member.pin {
            return pin == .square ? members.filter { $0.pin == .square }.count
                                  : members.filter { $0.pin != nil }.count
        }
        let safe = safeInsertionIndex(min(max(0, proposed), members.count))
        return max(safe, members.filter { $0.pin != nil }.count)
    }

    /// A place in the row that doesn't split a pair: the later page of a pair
    /// occupies no place of its own, so an index pointing at one moves on.
    private func safeInsertionIndex(_ proposed: Int) -> Int {
        let index = min(max(0, proposed), members.count)
        guard index < members.count,
              pair(of: members[index].id).map({ $0.left != members[index].id }) == true else { return index }
        return index + 1
    }

    /// A pin put in its place among the pins: the squares, then the rows.
    /// `first`: at the head of its kind rather than the end. Not a pin, it
    /// goes to the head of the loose tabs, after every pin.
    private mutating func settlePin(_ id: Tab.ID, first: Bool = false) {
        guard let here = members.firstIndex(where: { $0.id == id }) else { return }
        var row = members
        let member = row.remove(at: here)
        guard let pin = member.pin else {
            row.insert(member, at: row.filter { $0.pin != nil }.count)
            members = row
            return
        }
        let squares = row.filter { $0.pin == .square }.count
        let pins = row.filter { $0.pin != nil }.count
        row.insert(member, at: pin == .listed ? (first ? squares : pins) : squares)
        members = row
    }
}
