import XCTest
@testable import Search

// What Search reads out of pi's answers (Suggestions.swift, TabSort.swift):
// the shapes models really answer in — with the markers asked for, without
// them after thinking out loud (glm-5.3-flash), fenced in ```json, with
// braces inside strings — and the ones that must come to nothing.

final class PiAnswerTests: XCTestCase {

    // MARK: - tab groups

    func testGroupsBetweenMarkers() throws {
        let groups = try XCTUnwrap(TabSorter.parseGroups(#"<groups>{"groups":[{"name":"Jazz","tabs":["t1","t3"]}]}</groups>"#))
        XCTAssertEqual(groups.map(\.name), ["Jazz"])
        XCTAssertEqual(groups.first?.tabs, ["t1", "t3"])
    }

    /// The answer that broke the first sort: thinking, then the JSON, no markers.
    func testGroupsAfterThinkingWithoutMarkers() throws {
        let answer = """
        Better to split by topic: Bread and Jazz.
        Groups (tabs' language is English):
        - "Bread": Baguette, Croissant
        Output JSON.{"groups":[{"name":"Baking","tabs":["t1","t5"]},{"name":"Jazz","tabs":["t3","t7"]}]}
        """
        let groups = try XCTUnwrap(TabSorter.parseGroups(answer))
        XCTAssertEqual(groups.map(\.name), ["Baking", "Jazz"])
        XCTAssertEqual(groups.last?.tabs, ["t3", "t7"])
    }

    func testGroupsFencedAndSpaced() throws {
        let answer = "Here you go:\n```json\n{ \"groups\": [ { \"name\": \"Swift\", \"tabs\": [\"t2\", \"t6\"] } ] }\n```"
        XCTAssertEqual(try XCTUnwrap(TabSorter.parseGroups(answer)).map(\.name), ["Swift"])
    }

    func testGroupsFencedInsideMarkers() throws {
        let answer = "<groups>\n```json\n{\"groups\":[{\"name\":\"Kyoto\",\"tabs\":[\"t4\",\"t9\"]}]}\n```\n</groups>"
        XCTAssertEqual(try XCTUnwrap(TabSorter.parseGroups(answer)).map(\.name), ["Kyoto"])
    }

    /// A brace in a group's name doesn't end the JSON early.
    func testGroupsWithBracesInStrings() throws {
        let answer = #"{"groups":[{"name":"Code {Swift}","tabs":["t1","t2"]},{"name":"Say \"hi\"","tabs":["t3","t4"]}]}"#
        XCTAssertEqual(try XCTUnwrap(TabSorter.parseGroups(answer)).map(\.name), ["Code {Swift}", "Say \"hi\""])
    }

    /// An example in the thinking doesn't win over the answer after it.
    func testGroupsTakesTheLastAnswer() throws {
        let answer = #"Format is {"groups":[{"name":"…","tabs":["t1"]}]}. So: {"groups":[{"name":"Music","tabs":["t2","t3"]}]}"#
        XCTAssertEqual(try XCTUnwrap(TabSorter.parseGroups(answer)).map(\.name), ["Music"])
    }

    func testGroupsDropMalformedEntries() throws {
        let answer = #"{"groups":[{"name":"Ok","tabs":["t1","t2"]},{"name":7,"tabs":["t3"]},{"tabs":["t4"]}]}"#
        XCTAssertEqual(try XCTUnwrap(TabSorter.parseGroups(answer)).map(\.name), ["Ok"])
    }

    func testGroupsNamesCutAt40() throws {
        let long = String(repeating: "x", count: 80)
        let groups = try XCTUnwrap(TabSorter.parseGroups(#"{"groups":[{"name":"\#(long)","tabs":["t1","t2"]}]}"#))
        XCTAssertEqual(groups.first?.name.count, 40)
    }

    func testGroupsNothingToRead() {
        XCTAssertNil(TabSorter.parseGroups("I couldn't decide how to group these."))
        XCTAssertNil(TabSorter.parseGroups(#"{"groups": "#))
        XCTAssertNil(TabSorter.parseGroups(""))
    }

    /// deepseek's shape: the list of groups alone, between the markers.
    func testGroupsAsBareList() throws {
        let answer = "<groups>[\n{\"name\":\"Rezepte\",\"tabs\":[\"t1\",\"t2\"]},\n{\"name\":\"京都観光\",\"tabs\":[\"t4\",\"t5\"]}\n]</groups>"
        XCTAssertEqual(try XCTUnwrap(TabSorter.parseGroups(answer)).map(\.name), ["Rezepte", "京都観光"])
    }

    /// glm's other shape: one group a line between the markers, no list.
    func testGroupsOneALine() throws {
        let answer = "Mostly music and docs.<groups>\n{\"name\":\"Baking\",\"tabs\":[\"t1\",\"t2\"]}\n{\"name\":\"Jazz\",\"tabs\":[\"t3\",\"t4\"]}\n</groups>"
        XCTAssertEqual(try XCTUnwrap(TabSorter.parseGroups(answer)).map(\.name), ["Baking", "Jazz"])
    }

    /// Outside the markers, loose objects are the thinking's, not the answer.
    func testGroupsLooseObjectsOutsideMarkersIgnored() {
        XCTAssertNil(TabSorter.parseGroups(#"Like {"name":"Example","tabs":["t1","t2"]} perhaps."#))
    }

    /// Groups under another key are still groups: the list is read alone.
    func testGroupsUnderAnotherKey() throws {
        XCTAssertEqual(try XCTUnwrap(TabSorter.parseGroups(#"{"clusters":[{"name":"A","tabs":["t1","t2"]}]}"#)).map(\.name), ["A"])
    }

    /// A list of tab names alone isn't groups.
    func testGroupsNotAListOfNames() {
        XCTAssertNil(TabSorter.parseGroups(#"["t1","t2"]"#))
    }

    // MARK: - groups as they'd be put in place

    private let items = [
        TabSorter.Item(name: "t1", title: "John Coltrane - Wikipedia", url: nil),
        TabSorter.Item(name: "t2", title: "Miles Davis - Wikipedia", url: nil),
        TabSorter.Item(name: "t3", title: "Swift Documentation | Documentation", url: nil),
    ]

    /// gpt-oss's shape: titles, not names — whole, or cut short.
    func testResolvedTitlesToNames() {
        let groups = TabSorter.resolved([("Jazz", ["John Coltrane - Wikipedia", "miles davis - wikipedia"]), ("Swift", ["Swift Documentation"])],
                                        items: items, existing: [])
        XCTAssertEqual(groups.map(\.tabs), [["t1", "t2"], ["t3"]])
    }

    func testResolvedNumbersAndUnknowns() {
        let groups = TabSorter.resolved([("Jazz", ["1", "T2", "t9", "Nothing like it", ""])], items: items, existing: [])
        XCTAssertEqual(groups.first?.tabs, ["t1", "t2"])
    }

    /// The person's group, however the model wrote its name.
    func testResolvedExistingGroupNames() {
        let given = ["Music: Jazz - Wikipedia", "music", "Music (already holds: Jazz)", "Musicals", "Swift"]
        let groups = TabSorter.resolved(given.map { ($0, ["t1"]) }, items: items, existing: ["Music"])
        XCTAssertEqual(groups.map(\.name), ["Music", "Music", "Music", "Musicals", "Swift"])
    }

    // MARK: - page suggestions

    func testSuggestionsBetweenMarkers() {
        XCTAssertEqual(TabSorterFree.suggestions(#"<suggestions>["Open the Samuel Johnson article", "Find sources", "Compare recipes"]</suggestions>"#),
                       ["Open the Samuel Johnson article", "Find sources", "Compare recipes"])
    }

    func testSuggestionsAfterThinking() {
        let answer = #"The page is about marmalade, maybe ["a","b"] style. Final: ["Find the origins", "Open the recipe", "List the types"]"#
        XCTAssertEqual(TabSorterFree.suggestions(answer), ["Find the origins", "Open the recipe", "List the types"])
    }

    func testSuggestionsDropSummaryLongAndEmpty() {
        let long = String(repeating: "word ", count: 20)
        let answer = #"["Summarize this page", "\#(long)", " ", "Search the shop.", "\"Fill in the form\""]"#
        XCTAssertEqual(TabSorterFree.suggestions(answer), ["Search the shop", "Fill in the form"])
    }

    func testSuggestionsAtMostThree() {
        XCTAssertEqual(TabSorterFree.suggestions(#"["A b","C d","E f","G h"]"#)?.count, 3)
    }

    /// glm's shape: between the markers, one a line, not JSON.
    func testSuggestionsOneALine() {
        let answer = "Pick 3. \"Compare\" etc.<suggestions>\nCompare with Bose QuietComfort Ultra\n- Read the 3-star reviews\n3. Check Union Square pickup\n</suggestions>"
        XCTAssertEqual(TabSorterFree.suggestions(answer), ["Compare with Bose QuietComfort Ultra", "Read the 3-star reviews", "Check Union Square pickup"])
    }

    func testSuggestionsEmptyBetweenMarkers() {
        XCTAssertNil(TabSorterFree.suggestions("<suggestions>\n[]\n</suggestions>"))
    }

    func testSuggestionsNothingToRead() {
        XCTAssertNil(TabSorterFree.suggestions("Search the shop, fill in the form"))
        XCTAssertNil(TabSorterFree.suggestions("[1, 2, 3]"))
        XCTAssertNil(TabSorterFree.suggestions("[]"))
        XCTAssertNil(TabSorterFree.suggestions(#"["Summarize this page"]"#))
    }

    // MARK: - chat titles

    func testTitleBetweenMarkers() {
        XCTAssertEqual(PiOnce.parseTitle("<title>Marmalade Wikipedia Summary</title>"), "Marmalade Wikipedia Summary")
    }

    func testTitleQuotesAndFullStopOff() {
        XCTAssertEqual(PiOnce.parseTitle("<title>\"Jazz Shop Search.\"</title>"), "Jazz Shop Search")
        XCTAssertEqual(PiOnce.parseTitle("<title>**Kyoto Trip Plans**</title>"), "Kyoto Trip Plans")
    }

    func testTitleAfterThinkingWithMarkers() {
        let answer = "The user wants a title. Something like <title>X</title>? Let me pick.\n<title>Jazz Music Shop Search</title>"
        XCTAssertEqual(PiOnce.parseTitle(answer), "Jazz Music Shop Search")
    }

    /// Lost markers: the last line counts only if it is a title's length.
    func testTitleWithoutMarkers() {
        XCTAssertEqual(PiOnce.parseTitle("Thinking about it.\nJazz Shop Search"), "Jazz Shop Search")
        XCTAssertNil(PiOnce.parseTitle("The user's first message is about searching a shop for jazz in the Music department and getting the first result."))
    }

    func testTitleAtMostSixWords() {
        XCTAssertEqual(PiOnce.parseTitle("<title>one two three four five six seven eight</title>"), "one two three four five six")
    }

    func testTitleEmpty() {
        XCTAssertNil(PiOnce.parseTitle("<title>  \"\"  </title>"))
        XCTAssertNil(PiOnce.parseTitle(""))
    }
}

/// PageSuggestions is main-actor; its parser isn't.
private enum TabSorterFree {
    static func suggestions(_ answer: String) -> [String]? { PageSuggestions.parseSuggestions(answer) }
}
