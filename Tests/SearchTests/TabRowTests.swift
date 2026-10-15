import XCTest
@testable import Search

/// The tab row as a value: the rules `Browser` keeps, put through their paces
/// on their own. Plain `UUID`s stand in for tabs, so no page and no WebKit is
/// needed to know where a tab goes.
final class TabRowTests: XCTestCase {
    private let on = TabRow.Rules(groups: true, pairs: true)
    private let off = TabRow.Rules(groups: false, pairs: false)

    private func member(_ id: UUID, pin: TabRow.Pin? = nil, group: UUID? = nil,
                        shy: Bool = false, bench: Bool = false) -> TabRow.Member {
        TabRow.Member(id: id, shy: shy, bench: bench, pin: pin, group: group)
    }

    // MARK: - the shape of the row

    func testTheRowReadsPinsThenGroupsThenLooseWhateverOrderTheyWereOpenedIn() {
        var row = TabRow(rules: on)
        let s1 = UUID(), s2 = UUID(), r1 = UUID()
        let a1 = UUID(), a2 = UUID(), b1 = UUID(), l1 = UUID()

        // Opened scattered: the row is arranged, not the order of opening.
        row.open(member(l1), at: 0)
        row.open(member(a2), at: 0)
        row.open(member(s1, pin: .square), at: 0)
        row.open(member(b1), at: 0)
        row.open(member(a1), at: 0)
        row.open(member(r1, pin: .listed), at: 0)
        row.open(member(s2, pin: .square), at: 0)

        let ga = row.addGroup(named: "A", containing: [a1, a2])
        let gb = row.addGroup(named: "B", containing: [b1])
        XCTAssertNotNil(ga)
        XCTAssertNotNil(gb)

        XCTAssertEqual(row.ids, [s1, s2, r1, a1, a2, b1, l1])
        XCTAssertEqual(row.tabs(in: ga), [a1, a2])
        XCTAssertEqual(row.tabs(in: gb), [b1])
        XCTAssertEqual(row.tabs(in: nil), [l1])
    }

    func testWithGroupsOffATabStaysWhereItIsPutAndTurningThemOnArranges() {
        var row = TabRow(rules: off)
        let a1 = UUID(), a2 = UUID()
        row.open(member(a1), at: 0)
        row.open(member(a2), at: 1)
        let g = row.addGroup(containing: [a1, a2])
        XCTAssertNotNil(g)

        let mid = UUID()
        row.open(member(mid), at: 1)   // into the middle of the grouped tabs
        XCTAssertEqual(row.ids, [a1, mid, a2])
        XCTAssertNil(row.group(of: mid))          // it kept its own place, no group
        XCTAssertEqual(row.tabs(in: g), [a1, a2]) // membership is kept as it is

        _ = row.takeChange()
        row.setRules(on)
        XCTAssertEqual(row.ids, [a1, a2, mid])
        XCTAssertEqual(row.takeChange()?.save, .now)
    }

    func testTheLastTabClosedTakesItsGroupWithIt() throws {
        var row = TabRow(rules: on)
        let a1 = UUID(), a2 = UUID()
        row.open(member(a1), at: 0)
        row.open(member(a2), at: 1)
        let g = try XCTUnwrap(row.addGroup(containing: [a1]))
        row.join(a2, group: g)
        _ = row.takeChange()

        row.remove(a1)
        var change = row.takeChange()
        XCTAssertEqual(change?.save, .soon)
        XCTAssertEqual(change?.goneGroups, [])
        XCTAssertTrue(row.groups.contains { $0.id == g })

        row.remove(a2)
        change = row.takeChange()
        XCTAssertEqual(change?.save, .now)
        XCTAssertEqual(change?.goneGroups, [g])
        XCTAssertFalse(row.groups.contains { $0.id == g })
    }

    func testJoiningTakesAPairsPartnerAlongAndEmptiesTheOldGroup() throws {
        var row = TabRow(rules: on)
        let a = UUID(), b1 = UUID(), b2 = UUID()
        row.open(member(a), at: 0)
        let ga = try XCTUnwrap(row.addGroup(containing: [a]))
        row.setFolded(ga, true)

        row.open(member(b1), at: row.ids.count)
        row.open(member(b2), at: row.ids.count)
        let gb = try XCTUnwrap(row.addGroup(containing: [b1, b2]))
        row.addPair(TabSplit(tabs: [b1, b2]), keeping: b1)
        _ = row.takeChange()

        row.join(b1, group: ga)
        XCTAssertEqual(row.group(of: b1), ga)
        XCTAssertEqual(row.group(of: b2), ga)                 // the partner came too
        XCTAssertFalse(row.groups.contains { $0.id == gb })   // its old group emptied out
        XCTAssertEqual(row.groups.first { $0.id == ga }?.collapsed, false)
        XCTAssertNotNil(row.pair(of: b1))
    }

    func testJoinRefusesAPinAShyTabABenchTabAndAnUnknownGroup() {
        var row = TabRow(rules: on)
        let a = UUID(), pin = UUID(), shy = UUID(), bench = UUID(), loose = UUID()
        row.open(member(a), at: 0)
        let ga = row.addGroup(containing: [a])
        row.open(member(pin, pin: .square), at: 0)
        row.open(member(shy, shy: true), at: 0)
        row.open(member(bench, bench: true), at: 0)
        row.open(member(loose), at: row.ids.count)
        _ = row.takeChange()

        row.join(pin, group: ga)
        XCTAssertNil(row.takeChange())
        row.join(shy, group: ga)
        XCTAssertNil(row.takeChange())
        row.join(bench, group: ga)
        XCTAssertNil(row.takeChange())
        row.join(loose, group: UUID())
        XCTAssertNil(row.takeChange())
        XCTAssertNil(row.group(of: loose))
    }

    func testAddGroupNamesGroupNAndKeepsRowOrder() {
        var row = TabRow(rules: on)
        let pin = UUID()
        row.open(member(pin, pin: .square), at: 0)
        _ = row.takeChange()
        XCTAssertNil(row.addGroup(containing: [pin]))   // a pin can't join
        XCTAssertTrue(row.groups.isEmpty)
        XCTAssertNil(row.takeChange())

        let x = UUID(), y = UUID(), z = UUID()
        row.open(member(x), at: row.ids.count)
        row.open(member(y), at: row.ids.count)
        row.open(member(z), at: row.ids.count)
        let g = row.addGroup(containing: [z, x, y])
        XCTAssertEqual(row.groups.first { $0.id == g }?.name, "Group 1")
        XCTAssertEqual(row.tabs(in: g), [x, y, z])       // row order, not the order given
    }

    func testOpeningFromAGroupedSourceJoinsItsGroupWhileGroupsAreOn() {
        var row = TabRow(rules: on)
        let a = UUID()
        row.open(member(a), at: 0)
        let g = row.addGroup(containing: [a])

        let linked = UUID()
        row.open(member(linked), at: 1, from: a)
        XCTAssertEqual(row.group(of: linked), g)

        _ = row.takeChange()
        row.setRules(TabRow.Rules(groups: false, pairs: true))
        _ = row.takeChange()
        let loose = UUID()
        row.open(member(loose), at: 0, from: a)
        XCTAssertNil(row.group(of: loose))       // groups off: nothing new goes in

        _ = row.takeChange()
        row.setRules(on)
        _ = row.takeChange()
        let shy = UUID()
        row.open(member(shy, shy: true), at: 0, from: a)
        XCTAssertNil(row.group(of: shy))         // a shy tab keeps its own place
    }

    func testMoveGroupReordersTheGroupsAndTheirTabs() throws {
        var row = TabRow(rules: on)
        let a = UUID(), b = UUID()
        row.open(member(a), at: 0)
        let ga = try XCTUnwrap(row.addGroup(containing: [a]))
        row.open(member(b), at: row.ids.count)
        let gb = try XCTUnwrap(row.addGroup(containing: [b]))
        XCTAssertEqual(row.ids, [a, b])

        _ = row.takeChange()
        row.moveGroup(gb, to: 0)
        XCTAssertEqual(row.groups.map(\.id), [gb, ga])
        XCTAssertEqual(row.ids, [b, a])
        XCTAssertEqual(row.takeChange()?.save, .now)
    }

    func testRestorePutsGroupsMembershipAndOrderBackAndKeepsTabsOpenedSince() throws {
        var row = TabRow(rules: on)
        let a = UUID(), b = UUID(), c = UUID()
        row.open(member(a), at: 0)
        row.open(member(b), at: 1)
        row.open(member(c), at: 2)
        _ = row.takeChange()
        let snapshot = row

        let ga = try XCTUnwrap(row.addGroup(containing: [a, b]))
        row.join(c, group: ga)
        let fresh = UUID()
        row.open(member(fresh), at: row.ids.count)
        _ = row.takeChange()

        row.restore(snapshot)
        XCTAssertTrue(row.groups.isEmpty)
        XCTAssertNil(row.group(of: a))
        XCTAssertNil(row.group(of: c))
        XCTAssertEqual(row.ids, [a, b, c, fresh])   // the tab opened since stays, after the rest
        let change = row.takeChange()
        XCTAssertEqual(change?.save, .now)
        XCTAssertEqual(change?.goneGroups, [ga])    // the group Sort Tabs made went with the undo
    }

    func testRestoreDropsAGroupWhoseTabsAllClosedSince() {
        var row = TabRow(rules: on)
        let a = UUID(), b = UUID()
        row.open(member(a), at: 0)
        row.open(member(b), at: 1)
        let g = row.addGroup(containing: [a, b])
        _ = row.takeChange()
        let snapshot = row

        row.remove(a)
        row.remove(b)
        _ = row.takeChange()
        row.restore(snapshot)
        XCTAssertFalse(row.groups.contains { $0.id == g })
        XCTAssertTrue(row.ids.isEmpty)
    }

    func testReopenWithAClosedGroupBringsItBackAtItsOldIndexUnfolded() throws {
        var row = TabRow(rules: on)
        let a = UUID()
        row.open(member(a), at: 0)
        let g = try XCTUnwrap(row.addGroup(containing: [a]))
        row.setFolded(g, true)
        let at = row.groups.firstIndex { $0.id == g }
        let closed = row.groups[at ?? 0]
        row.remove(a)                      // the group goes with its last tab
        _ = row.takeChange()

        row.reopen(member(a, group: g), at: 0, closedGroup: (closed, at ?? 0))
        XCTAssertTrue(row.groups.contains { $0.id == g })
        XCTAssertEqual(row.groups.first { $0.id == g }?.collapsed, false)
        XCTAssertEqual(row.group(of: a), g)
        XCTAssertEqual(row.takeChange()?.save, .now)
    }

    func testReopenWithAClosedGroupWhileGroupsAreOffComesBackLoose() {
        var row = TabRow(rules: off)
        let group = TabGroup(id: UUID(), name: "G", collapsed: false)
        let b = UUID()
        row.reopen(member(b, group: group.id), at: 0, closedGroup: (group, 0))
        XCTAssertTrue(row.contains(b))
        XCTAssertNil(row.group(of: b))          // no group while groups are off
        XCTAssertTrue(row.groups.isEmpty)       // and none was made
        XCTAssertEqual(row.takeChange()?.save, .soon)
    }

    func testInitPutsTheRowStraightAndRecordsNoChange() {
        let keep = TabGroup(id: UUID(), name: "Keep", collapsed: false)
        let empty = TabGroup(id: UUID(), name: "Empty", collapsed: false)
        let pin = UUID(), keeper = UUID(), dangling = UUID(), a = UUID(), absent = UUID()
        let row = TabRow(
            members: [
                member(pin, pin: .square, group: keep.id),
                member(keeper, group: keep.id),
                member(dangling, group: UUID()),
                member(a),
            ],
            groups: [keep, empty],
            pairs: [TabSplit(tabs: [a, absent])],
            rules: on
        )
        XCTAssertNil(row.member(pin)?.group)                    // a pin is never in a group
        XCTAssertEqual(row.member(keeper)?.group, keep.id)
        XCTAssertEqual(row.groups.map(\.id), [keep.id])        // the empty group went
        XCTAssertTrue(row.pairs.isEmpty)                       // the pair didn't hold
        XCTAssertNil(row.change)                               // init records nothing
        XCTAssertEqual(row.ids.first, pin)                     // the pins come first
    }

    func testPinsKeepTheirOrderWithSquaresAheadOfRows() {
        var row = TabRow(rules: on)
        let s1 = UUID(), s2 = UUID(), r1 = UUID()
        row.open(member(s1, pin: .square), at: 0)
        row.open(member(s2, pin: .square), at: 0)
        row.open(member(r1, pin: .listed), at: 0)
        XCTAssertEqual(row.ids, [s1, s2, r1])

        row.setPin(s1, .listed)                 // a square made a row: head of the rows
        XCTAssertEqual(row.ids, [s2, s1, r1])
        row.setPin(s1, .square)                 // a row made a square: end of the squares
        XCTAssertEqual(row.ids, [s2, s1, r1])
        row.setPin(s1, nil)                     // unpinned: the first place after the pins
        XCTAssertEqual(row.ids, [s2, r1, s1])
    }

    func testWithPairsOffPagesComeApartUntilPairsAreOnAgain() {
        var row = TabRow(rules: TabRow.Rules(groups: true, pairs: false))
        let a = UUID(), b = UUID(), c = UUID()
        row.open(member(a), at: 0)
        row.open(member(b), at: 1)
        row.addPair(TabSplit(tabs: [a, b]), keeping: a)
        XCTAssertNil(row.pair(of: a))           // nothing acts on a pair while off

        row.open(member(c), at: 1)              // straight between the two pages
        XCTAssertEqual(row.ids, [a, c, b])      // arranging didn't keep them together

        // With groups off nothing arranges, so the pair that came apart goes
        // when pairs are turned on.
        row.setRules(TabRow.Rules(groups: false, pairs: true))
        XCTAssertTrue(row.pairs.isEmpty)
        XCTAssertNil(row.pair(of: a))
    }

    func testTurningPairsOnDropsAPairThatCameApartWithGroupsStillOn() {
        var row = TabRow(rules: TabRow.Rules(groups: true, pairs: false))
        let a = UUID(), b = UUID(), x = UUID()
        row.open(member(a), at: 0)
        row.open(member(b), at: 1)
        row.addPair(TabSplit(tabs: [a, b]), keeping: a)
        row.open(member(x), at: 1)              // between the pair's pages
        XCTAssertEqual(row.ids, [a, x, b])

        row.setRules(on)
        XCTAssertTrue(row.pairs.isEmpty)        // judged before the arrangement
        XCTAssertEqual(row.ids, [a, x, b])
    }

    func testInitDropsAPairThatIsNotNextToItself() {
        let a = UUID(), b = UUID(), x = UUID()
        let row = TabRow(members: [member(a), member(x), member(b)],
                         pairs: [TabSplit(tabs: [a, b])], rules: on)
        XCTAssertTrue(row.pairs.isEmpty)
        XCTAssertEqual(row.ids, [a, x, b])
    }

    func testRestoreMakesATabLooseAgainWhenTheSnapshotHadItLoose() throws {
        var row = TabRow(rules: on)
        let a = UUID(), b = UUID()
        row.open(member(a), at: 0)
        let g = try XCTUnwrap(row.addGroup(containing: [a]))
        row.open(member(b), at: row.ids.count)
        _ = row.takeChange()
        let snapshot = row   // g holds a; b is loose

        row.join(b, group: g)
        XCTAssertEqual(row.group(of: b), g)
        _ = row.takeChange()

        row.restore(snapshot)
        XCTAssertNil(row.group(of: b))          // loose again, as the snapshot had it
        XCTAssertEqual(row.tabs(in: g), [a])    // and g still holds only a
    }

    func testRestoreKeepsAPairWhosePagesTheArrangementBringsBackTogether() throws {
        var row = TabRow(rules: on)
        let a = UUID(), b = UUID()
        row.open(member(a), at: 0)
        row.open(member(b), at: 1)
        row.addPair(TabSplit(tabs: [a, b]), keeping: a)
        _ = row.takeChange()
        let snapshot = row

        _ = try XCTUnwrap(row.addGroup(containing: [a]))   // takes the partner along
        XCTAssertEqual(row.group(of: b), row.group(of: a))
        _ = row.takeChange()

        row.restore(snapshot)
        XCTAssertTrue(row.pairs.contains { $0.tabs == [a, b] })
        XCTAssertNil(row.group(of: a))
        XCTAssertNil(row.group(of: b))
        XCTAssertEqual(row.ids, [a, b])
    }

    func testRestoreArrangesBeforeItJudgesAPair() {
        // The snapshot was taken while pairs were off, with x between the
        // pair's pages, so a plain restore would order them apart.
        var row = TabRow(rules: TabRow.Rules(groups: true, pairs: false))
        let a = UUID(), b = UUID(), x = UUID()
        row.open(member(a), at: 0)
        row.open(member(x), at: 1)
        row.open(member(b), at: 2)
        _ = row.takeChange()
        let snapshot = row

        row.setRules(on)
        row.addPair(TabSplit(tabs: [a, b]), keeping: a)
        _ = row.takeChange()

        row.restore(snapshot)
        XCTAssertTrue(row.pairs.contains { $0.tabs == [a, b] })   // arranged back together
        XCTAssertEqual(row.ids, [a, b, x])
    }

    func testTakeChangeReturnsAndClearsAndANoOpRecordsNothing() {
        var row = TabRow(rules: on)
        let a = UUID()
        row.open(member(a), at: 0)
        let change = row.takeChange()
        XCTAssertEqual(change?.save, .soon)
        XCTAssertEqual(change?.goneGroups, [])
        XCTAssertNil(row.takeChange())          // taken once

        row.open(member(a), at: 5)              // already there
        XCTAssertNil(row.takeChange())
        row.remove(UUID())                      // unknown
        XCTAssertNil(row.takeChange())
        row.join(a, group: nil)                 // already loose
        XCTAssertNil(row.takeChange())
        row.setPin(a, nil)                      // not a pin
        XCTAssertNil(row.takeChange())
    }

    // MARK: - dragging, pairs, replacing, pins from another window

    func testDroppingBeforeATabInAnotherGroupTakesThatGroupAndTheOldOneGoesWhenEmptied() throws {
        var row = TabRow(rules: on)
        let a = UUID(), b = UUID()
        row.open(member(a), at: 0)
        let ga = try XCTUnwrap(row.addGroup(containing: [a]))
        row.open(member(b), at: row.ids.count)
        let gb = try XCTUnwrap(row.addGroup(containing: [b]))
        _ = row.takeChange()

        row.drop(a, before: b)
        XCTAssertEqual(row.ids, [a, b])
        XCTAssertEqual(row.group(of: a), gb)          // it took the group it was dropped into
        XCTAssertFalse(row.groups.contains { $0.id == ga })
        let change = row.takeChange()
        XCTAssertEqual(change?.save, .now)            // a group went
        XCTAssertEqual(change?.goneGroups, [ga])
    }

    func testDroppingBeforeAPairsPageLandsBeforeThePairAndAPageOnItsPartnerDoesNothing() {
        var row = TabRow(rules: on)
        let p1 = UUID(), p2 = UUID(), y = UUID()
        row.open(member(p1), at: 0)
        row.open(member(p2), at: 1)
        row.addPair(TabSplit(tabs: [p1, p2]), keeping: p1)
        row.open(member(y), at: row.ids.count)
        XCTAssertEqual(row.ids, [p1, p2, y])
        _ = row.takeChange()

        row.drop(y, before: p2)
        XCTAssertEqual(row.ids, [y, p1, p2])          // before the pair, not between its pages
        XCTAssertEqual(row.pair(of: p1)?.tabs, [p1, p2])

        _ = row.takeChange()
        row.drop(p1, before: p2)                     // onto its own partner
        XCTAssertNil(row.takeChange())
        XCTAssertEqual(row.ids, [y, p1, p2])
    }

    func testDropWithNoTargetPutsEachKindAtTheEndOfItsOwnAndKeepsPinsApartFromLooseTabs() {
        var row = TabRow(rules: on)
        let s1 = UUID(), s2 = UUID(), r1 = UUID(), r2 = UUID(), a = UUID(), b = UUID()
        row.open(member(a), at: 0)
        row.open(member(b), at: 1)
        row.open(member(s1, pin: .square), at: 0)
        row.open(member(s2, pin: .square), at: 0)
        row.open(member(r1, pin: .listed), at: 0)
        row.open(member(r2, pin: .listed), at: 0)
        XCTAssertEqual(row.ids, [s1, s2, r1, r2, a, b])
        _ = row.takeChange()

        row.drop(a, before: nil)                    // a loose tab goes to the end
        XCTAssertEqual(row.ids, [s1, s2, r1, r2, b, a])

        _ = row.takeChange()
        row.drop(s1, before: nil)                   // a square to the end of the squares
        XCTAssertEqual(row.ids, [s2, s1, r1, r2, b, a])

        _ = row.takeChange()
        row.drop(r1, before: nil)                   // a pinned row to the end of the pins
        XCTAssertEqual(row.ids, [s2, s1, r2, r1, b, a])

        _ = row.takeChange()
        row.drop(s1, before: b)                     // a pin can't land among loose tabs
        XCTAssertNil(row.takeChange())
        row.drop(b, before: s2)                     // nor a loose tab among pins
        XCTAssertNil(row.takeChange())
    }

    func testMoveShownMovesAPairAsOneAndLandsAfterAWholePairWhenMovingRight() {
        var row = TabRow(rules: on)
        let p1 = UUID(), p2 = UUID(), a = UUID(), q1 = UUID(), q2 = UUID()
        row.open(member(p1), at: 0)
        row.open(member(p2), at: 1)
        row.addPair(TabSplit(tabs: [p1, p2]), keeping: p1)
        row.open(member(a), at: row.ids.count)
        row.open(member(q1), at: row.ids.count)
        row.open(member(q2), at: row.ids.count)
        row.addPair(TabSplit(tabs: [q1, q2]), keeping: q1)
        XCTAssertEqual(row.ids, [p1, p2, a, q1, q2])
        XCTAssertEqual(row.shown, [p1, a, q1])
        _ = row.takeChange()

        row.moveShown(p1, to: 2)                    // onto q1's place
        XCTAssertEqual(row.ids, [a, q1, q2, p1, p2]) // as one block, after the whole pair
        XCTAssertEqual(row.pair(of: q1)?.tabs, [q1, q2])
        XCTAssertEqual(row.pair(of: p1)?.tabs, [p1, p2])
    }

    func testSetPairSizesClampsAndIgnoresTheSameSizesOrTheWrongCount() throws {
        var row = TabRow(rules: on)
        let a = UUID(), b = UUID()
        row.open(member(a), at: 0)
        row.open(member(b), at: 1)
        row.addPair(TabSplit(tabs: [a, b]), keeping: a)
        let pair = try XCTUnwrap(row.pair(of: a)?.id)
        _ = row.takeChange()

        row.setPairSizes(pair, [0.95, 0.05])
        let sizes = try XCTUnwrap(row.pair(of: a)?.sizes)
        XCTAssertEqual(sizes[0], 0.8, accuracy: 0.000_001)
        XCTAssertEqual(sizes[1], 0.2, accuracy: 0.000_001)
        XCTAssertEqual(row.takeChange()?.save, .soon)

        row.setPairSizes(pair, sizes)               // the sizes it already has
        XCTAssertNil(row.takeChange())
        row.setPairSizes(pair, [0.4])                // wrong count
        XCTAssertNil(row.takeChange())
        row.setPairSizes(UUID(), [0.4, 0.6])         // unknown pair
        XCTAssertNil(row.takeChange())
    }

    func testFocusPageSetsThePairsFocusAndRecordsNothingTheSecondTime() throws {
        var row = TabRow(rules: on)
        let a = UUID(), b = UUID()
        row.open(member(a), at: 0)
        row.open(member(b), at: 1)
        row.addPair(TabSplit(tabs: [a, b]), keeping: a)
        XCTAssertNil(row.pair(of: a)?.focused)
        _ = row.takeChange()

        row.focusPage(b)
        XCTAssertEqual(row.pair(of: a)?.focused, b)
        XCTAssertEqual(row.takeChange()?.save, .soon)

        row.focusPage(b)
        XCTAssertNil(row.takeChange())
        row.focusPage(UUID())                       // in no pair
        XCTAssertNil(row.takeChange())
    }

    func testSwapPairReversesPagesSizesAndTheRowSoThePairStillHolds() throws {
        var row = TabRow(rules: on)
        let a = UUID(), b = UUID(), c = UUID()
        row.open(member(a), at: 0)
        row.open(member(b), at: 1)
        row.addPair(TabSplit(tabs: [a, b], sizes: [0.25, 0.75]), keeping: a)
        row.open(member(c), at: row.ids.count)
        let pair = try XCTUnwrap(row.pair(of: a)?.id)
        _ = row.takeChange()

        row.swapPair(pair)
        XCTAssertEqual(row.pair(of: b)?.tabs, [b, a])
        XCTAssertEqual(row.pair(of: b)?.sizes, [0.75, 0.25])
        XCTAssertEqual(row.ids, [b, a, c])          // the pair's place, with its pages swapped
        XCTAssertEqual(row.takeChange()?.save, .soon)

        row.swapPair(UUID())                        // no such pair
        XCTAssertNil(row.takeChange())
    }

    func testReplaceWithAFreshMemberKeepsItsPlaceGroupAndPairAndMovesFocus() throws {
        var row = TabRow(rules: on)
        let a = UUID(), b = UUID(), x = UUID()
        row.open(member(a), at: 0)
        row.open(member(b), at: 1)
        row.addPair(TabSplit(tabs: [a, b]), keeping: a)
        let g = try XCTUnwrap(row.addGroup(containing: [a]))   // takes both pages
        row.focusPage(b)
        row.open(member(x), at: row.ids.count)
        _ = row.takeChange()

        let fresh = UUID()
        row.replace(b, with: member(fresh))
        XCTAssertEqual(row.ids, [a, fresh, x])      // the old page's place
        XCTAssertEqual(row.group(of: fresh), g)     // and its group
        XCTAssertEqual(row.pair(of: a)?.tabs, [a, fresh])
        XCTAssertEqual(row.pair(of: a)?.focused, fresh)   // focus moved off the old page
        XCTAssertFalse(row.contains(b))
    }

    func testReplaceWithAMemberAlreadyInTheRowFillsThePageAndItsOldGroupGoesWhenEmptied() throws {
        var row = TabRow(rules: on)
        let a = UUID(), b = UUID(), moving = UUID()
        row.open(member(a), at: 0)
        row.open(member(b), at: 1)
        row.addPair(TabSplit(tabs: [a, b]), keeping: a)
        let ga = try XCTUnwrap(row.addGroup(containing: [a]))   // a and b
        row.open(member(moving), at: row.ids.count)
        let gb = try XCTUnwrap(row.addGroup(containing: [moving]))
        _ = row.takeChange()

        row.replace(b, with: member(moving))        // the open tab fills the page
        XCTAssertEqual(row.ids, [a, moving])
        XCTAssertEqual(row.group(of: moving), ga)   // it takes the page's group
        XCTAssertEqual(row.pair(of: a)?.tabs, [a, moving])
        XCTAssertFalse(row.groups.contains { $0.id == gb })
        let change = row.takeChange()
        XCTAssertEqual(change?.save, .now)
        XCTAssertEqual(change?.goneGroups, [gb])
    }

    func testSetPinsRemovesAnUnlistedPinAddsANewOneAndMovesAChangedSquareAfterTheSquares() {
        var row = TabRow(rules: on)
        let s1 = UUID(), s2 = UUID(), r1 = UUID(), rNew = UUID(), a = UUID(), b = UUID()
        row.open(member(a), at: 0)
        row.open(member(b), at: 1)
        row.open(member(s1, pin: .square), at: 0)
        row.open(member(s2, pin: .square), at: 0)
        row.open(member(r1, pin: .listed), at: 0)
        XCTAssertEqual(row.ids, [s1, s2, r1, a, b])
        _ = row.takeChange()

        // s1 made a row, r1 left out, rNew brought in.
        row.setPins([member(s1, pin: .listed), member(s2, pin: .square), member(rNew, pin: .listed)])
        XCTAssertEqual(row.ids, [s2, s1, rNew, a, b])   // squares first, then the rows in order
        XCTAssertFalse(row.contains(r1))
        XCTAssertTrue(row.contains(rNew))

        _ = row.takeChange()
        row.setPins([member(s1, pin: .listed), member(s2, pin: .square), member(rNew, pin: .listed)])
        XCTAssertNil(row.takeChange())                 // the same list again changes nothing

        // A member with no pin, and a shy one, are ignored; unlisted pins go.
        row.setPins([member(s2, pin: .square), member(a), member(s1, pin: .square, shy: true)])
        XCTAssertEqual(row.ids, [s2, a, b])
    }

    // MARK: - every rule, after every action

    /// SplitMix64: a small deterministic generator, so a failure names a seed
    /// and a step that can be run again.
    private struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func testEveryRuleHoldsAfterEveryAction() {
        for seed in [UInt64(1), 0xDEAD_BEEF, 0x5EED_5EED] {
            var rng = SplitMix64(seed: seed)
            var row = TabRow(rules: on)
            var snapshots: [TabRow] = []
            var closedGroups: [(group: TabGroup, at: Int)] = []
            for step in 0..<1000 {
                let before = row.groups
                let action = applyRandomAction(to: &row, snapshots: &snapshots,
                                               closedGroups: &closedGroups, rng: &rng)
                // A group that just went away can be brought back by a later
                // reopen, named as it was and at the index it left.
                for (index, group) in before.enumerated()
                where !row.groups.contains(where: { $0.id == group.id }) {
                    if !closedGroups.contains(where: { $0.group.id == group.id }) {
                        closedGroups.append((group, index))
                    }
                }
                if closedGroups.count > 6 { closedGroups.removeFirst() }

                let problems = invariantProblems(row)
                XCTAssertTrue(
                    problems.isEmpty,
                    "seed \(seed), step \(step), action \(action): \(problems.joined(separator: "; "))"
                )
                if !problems.isEmpty { return }
            }
        }
    }

    @discardableResult
    private func applyRandomAction(to row: inout TabRow, snapshots: inout [TabRow],
                                   closedGroups: inout [(group: TabGroup, at: Int)],
                                   rng: inout SplitMix64) -> String {
        let ids = row.ids
        let groupIDs = row.groups.map(\.id)

        func maybeID() -> UUID? {
            if ids.isEmpty || rng.next() % 4 == 0 { return UUID() }
            return ids[Int(rng.next() % UInt64(ids.count))]
        }
        func aGroup() -> UUID? {
            guard !groupIDs.isEmpty else { return nil }
            return groupIDs[Int(rng.next() % UInt64(groupIDs.count))]
        }
        func aPin() -> TabRow.Pin? {
            switch rng.next() % 3 {
            case 0: return .square
            case 1: return .listed
            default: return nil
            }
        }
        func aSource() -> Tab.ID? {
            guard !ids.isEmpty, rng.next() % 3 != 0 else { return nil }
            return ids[Int(rng.next() % UInt64(ids.count))]
        }

        switch Int(rng.next() % 21) {
        case 0:
            let fresh = TabRow.Member(
                id: UUID(), shy: rng.next() % 6 == 0, bench: rng.next() % 8 == 0,
                pin: rng.next() % 3 == 0 ? aPin() : nil,
                group: rng.next() % 5 == 0 ? (aGroup() ?? UUID()) : nil
            )
            row.open(fresh, at: Int(rng.next() % UInt64(ids.count + 1)), from: aSource())
            return "open"

        case 1:
            var closed: (group: TabGroup, at: Int)?
            if !closedGroups.isEmpty, rng.next() % 2 == 0 {
                closed = closedGroups[Int(rng.next() % UInt64(closedGroups.count))]
            }
            let back = TabRow.Member(
                id: UUID(), shy: rng.next() % 8 == 0,
                pin: rng.next() % 4 == 0 ? aPin() : nil,
                group: closed?.group.id ?? (rng.next() % 3 == 0 ? (aGroup() ?? UUID()) : nil)
            )
            row.reopen(back, at: Int(rng.next() % UInt64(ids.count + 1)), closedGroup: closed)
            return "reopen"

        case 2:
            row.remove(maybeID() ?? UUID())
            return "remove"

        case 3:
            var chosen: [UUID] = []
            for _ in 0..<(rng.next() % 4) { chosen.append(maybeID() ?? UUID()) }
            let name = rng.next() % 2 == 0 ? nil : (rng.next() % 4 == 0 ? "  " : "G\(rng.next() % 5)")
            row.addGroup(named: name, containing: chosen)
            return "addGroup"

        case 4:
            row.join(maybeID() ?? UUID(), group: rng.next() % 4 == 0 ? (aGroup() ?? UUID()) : aGroup())
            return "join"

        case 5:
            row.renameGroup(aGroup() ?? UUID(),
                            to: ["", "  ", "New", "Other"][Int(rng.next() % 4)])
            return "renameGroup"

        case 6:
            row.setFolded(aGroup() ?? UUID(), rng.next() % 2 == 0)
            return "setFolded"

        case 7:
            row.ungroup(aGroup() ?? UUID())
            return "ungroup"

        case 8:
            row.moveGroup(aGroup() ?? UUID(), to: Int(rng.next() % UInt64(max(1, groupIDs.count))))
            return "moveGroup"

        case 9:
            if !snapshots.isEmpty, rng.next() % 2 == 0 {
                row.restore(snapshots[Int(rng.next() % UInt64(snapshots.count))])
                return "restore"
            }
            snapshots.append(row)
            if snapshots.count > 6 { snapshots.removeFirst() }
            return "snapshot"

        case 10:
            row.setPin(maybeID() ?? UUID(), aPin())
            return "setPin"

        case 11:
            var pages: [UUID] = []
            for _ in 0..<(2 + rng.next() % 2) {
                if ids.isEmpty || rng.next() % 5 == 0 { pages.append(UUID()) }
                else { pages.append(ids[Int(rng.next() % UInt64(ids.count))]) }
            }
            let anchor = pages[Int(rng.next() % UInt64(pages.count))]
            row.addPair(TabSplit(tabs: pages), keeping: anchor)
            return "addPair"

        case 12:
            row.removePair(containing: maybeID() ?? UUID())
            return "removePair"

        case 13:
            row.drop(maybeID() ?? UUID(), before: rng.next() % 3 == 0 ? nil : maybeID())
            return "drop"

        case 14:
            row.moveShown(maybeID() ?? UUID(), to: Int(rng.next() % UInt64(max(1, row.shown.count))))
            return "moveShown"

        case 15:
            let count = Int(rng.next() % 4)
            let sizes = (0..<count).map { _ in Double(rng.next() % 120) / 100 }
            row.setPairSizes(row.pairs.first?.id ?? UUID(), sizes)
            return "setPairSizes"

        case 16:
            row.focusPage(maybeID() ?? UUID())
            return "focusPage"

        case 17:
            row.swapPair(row.pairs.first?.id ?? UUID())
            return "swapPair"

        case 18:
            let old = maybeID() ?? UUID()
            let newID = (!ids.isEmpty && rng.next() % 2 == 0)
                ? ids[Int(rng.next() % UInt64(ids.count))] : UUID()
            let replacing = TabRow.Member(
                id: newID, shy: rng.next() % 8 == 0, bench: rng.next() % 10 == 0,
                pin: rng.next() % 3 == 0 ? aPin() : nil
            )
            row.replace(old, with: replacing)
            return "replace"

        case 19:
            var list: [TabRow.Member] = []
            for pin in row.members where pin.pin != nil && !pin.shy {
                if rng.next() % 3 != 0 { list.append(pin) }
            }
            if rng.next() % 2 == 0 {
                list.append(TabRow.Member(id: UUID(), pin: aPin() ?? .square))
            }
            if rng.next() % 2 == 0 { list.reverse() }
            row.setPins(list)
            return "setPins"

        default:
            row.setRules(TabRow.Rules(groups: rng.next() % 2 == 0, pairs: rng.next() % 2 == 0))
            return "setRules"
        }
    }

    /// R1–R6, and `shown` by its own definition. Empty when the row is sound.
    private func invariantProblems(_ row: TabRow) -> [String] {
        var problems: [String] = []
        let ids = row.ids

        if Set(ids).count != ids.count { problems.append("R1 an id appears twice") }

        let groupIDs = Set(row.groups.map(\.id))
        for m in row.members {
            if m.pin != nil, m.group != nil { problems.append("R2 pin \(m.id) is in a group") }
            if let g = m.group, !groupIDs.contains(g) { problems.append("R2 \(m.id) names a group that isn't here") }
        }

        for g in row.groups where !row.members.contains(where: { $0.pin == nil && $0.group == g.id }) {
            problems.append("R3 group \(g.name) has no ordinary tab")
        }

        var sawNonPin = false, sawRow = false
        for m in row.members {
            switch m.pin {
            case .square:
                if sawNonPin { problems.append("R4 a square after a non-pin") }
                if sawRow { problems.append("R4 a square after a pinned row") }
            case .listed:
                if sawNonPin { problems.append("R4 a pinned row after a non-pin") }
                sawRow = true
            case nil:
                sawNonPin = true
            }
        }

        if row.rules.pairs {
            var paired = Set<Tab.ID>()
            for pair in row.pairs {
                if !TabRow.holds(pair, in: row.members) { problems.append("R6 a pair doesn't hold") }
                for id in pair.tabs where !paired.insert(id).inserted {
                    problems.append("R6 \(id) is in two pairs")
                }
            }
        }

        if row.rules.groups, arrangedOrder(of: row) != ids {
            problems.append("R5 the row isn't arranged")
        }

        let expected = row.rules.pairs
            ? ids.filter { id in !row.pairs.contains { $0.contains(id) && $0.left != id } }
            : ids
        if row.shown != expected { problems.append("shown doesn't match its definition") }

        return problems
    }

    /// The order `arrangeGroupedTabs` should leave, worked out from the raw
    /// members and groups rather than through the row's own helpers.
    private func arrangedOrder(of row: TabRow) -> [Tab.ID] {
        let laterPages = row.rules.pairs ? Set(row.pairs.flatMap { $0.tabs.dropFirst() }) : []
        let representatives = row.members.filter { !laterPages.contains($0.id) }
        let groupIDs = Set(row.groups.map(\.id))
        let pins = representatives.filter { $0.pin != nil }.map(\.id)
        let grouped = row.groups.flatMap { group in
            representatives.filter { $0.pin == nil && $0.group == group.id }.map(\.id)
        }
        let loose = representatives.filter { m in
            guard m.pin == nil else { return false }
            guard let g = m.group else { return true }
            return !groupIDs.contains(g)
        }.map(\.id)

        var order: [Tab.ID] = []
        for id in pins + grouped + loose {
            if row.rules.pairs, let pair = row.pairs.first(where: { $0.contains(id) }), pair.left == id {
                order.append(contentsOf: pair.tabs)
            } else {
                order.append(id)
            }
        }
        return order
    }
}
