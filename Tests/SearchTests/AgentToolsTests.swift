import Foundation
import XCTest
@testable import Search

/// The browser tools pi is given, as the catalogue declares them: the twelve
/// in order, each with a schema, its hints, and the step the chat shows.
@MainActor
final class AgentToolsTests: XCTestCase {

    private let twelve = ["browser_tabs", "browser_read", "browser_screenshot", "browser_find", "browser_open",
                          "browser_navigate", "browser_select", "browser_close", "browser_click", "browser_type",
                          "browser_press", "browser_scroll"]

    func testTheToolsAreTheTwelveInOrder() {
        XCTAssertEqual(AgentTools.names, twelve)
    }

    func testEachToolHasItsKind() {
        let reads: Set<String> = ["browser_tabs", "browser_read", "browser_screenshot", "browser_find"]
        let shows: Set<String> = ["browser_select", "browser_scroll"]
        let acts: Set<String> = ["browser_open", "browser_navigate", "browser_close", "browser_click", "browser_type", "browser_press"]
        for tool in AgentTools.tools {
            switch tool.kind {
            case .reads: XCTAssertTrue(reads.contains(tool.name), tool.name)
            case .shows: XCTAssertTrue(shows.contains(tool.name), tool.name)
            case .acts: XCTAssertTrue(acts.contains(tool.name), tool.name)
            }
            XCTAssertEqual(tool.destructive, tool.name == "browser_close", tool.name)
        }
        XCTAssertEqual(Set(AgentTools.tools.map(\.name)), reads.union(shows).union(acts))
    }

    func testTheExtensionRegistersExactlyTheDeclaredTools() throws {
        let source = AgentTools.extensionSource
        XCTAssertTrue(source.contains("const tools = " + AgentTools.toolsJSON + ";"))
        XCTAssertTrue(source.contains("pi.registerTool("))
        XCTAssertFalse(source.contains("typebox"))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(AgentTools.toolsJSON.utf8)) as? [[String: Any]])
        XCTAssertEqual(parsed.compactMap { $0["name"] as? String }, AgentTools.names)
    }

    func testEveryToolHasASchemaAndWords() throws {
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(AgentTools.toolsJSON.utf8)) as? [[String: Any]])
        for registration in parsed {
            let name = registration["name"] as? String ?? ""
            XCTAssertFalse((registration["label"] as? String ?? "").isEmpty, name)
            XCTAssertFalse((registration["description"] as? String ?? "").isEmpty, name)
            let parameters = try XCTUnwrap(registration["parameters"] as? [String: Any], name)
            XCTAssertEqual(parameters["type"] as? String, "object", name)
            let properties = parameters["properties"] as? [String: Any] ?? [:]
            for (property, value) in properties {
                let schema = try XCTUnwrap(value as? [String: Any], property)
                XCTAssertTrue(["string", "boolean"].contains(schema["type"] as? String ?? ""), property)
                XCTAssertFalse((schema["description"] as? String ?? "").isEmpty, property)
            }
            let required = parameters["required"] as? [String] ?? []
            for word in required { XCTAssertNotNil(properties[word], word) }
            if name == "browser_type" { XCTAssertEqual(required, ["ref", "text"]) }
            if name == "browser_tabs" {
                XCTAssertTrue(properties.isEmpty)
                XCTAssertNil(parameters["required"])
            }
            if name == "browser_scroll" { XCTAssertNil(parameters["required"]) }
        }
    }

    func testHintsFollowTheKind() throws {
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(AgentTools.toolsJSON.utf8)) as? [[String: Any]])
        let acting: Set<String> = ["browser_open", "browser_navigate", "browser_close", "browser_click", "browser_type", "browser_press"]
        for registration in parsed {
            let name = registration["name"] as? String ?? ""
            let annotations = try XCTUnwrap(registration["annotations"] as? [String: Any], name)
            if acting.contains(name) {
                XCTAssertEqual(annotations.count, 3, name)
                XCTAssertEqual(annotations["readOnlyHint"] as? Bool, false, name)
                XCTAssertEqual(annotations["openWorldHint"] as? Bool, true, name)
                XCTAssertEqual(annotations["destructiveHint"] as? Bool, name == "browser_close", name)
            } else {
                XCTAssertEqual(annotations.count, 1, name)
                XCTAssertEqual(annotations["readOnlyHint"] as? Bool, true, name)
            }
        }
    }

    func testStepsReadAsBefore() {
        let cases: [(String, [String: Any], String)] = [
            ("browser_tabs", [:], "Looking at your tabs"),
            ("browser_read", [:], "Reading the page"),
            ("browser_screenshot", [:], "Taking a picture of the page"),
            ("browser_find", [:], "Looking over the page"),
            ("browser_open", ["url": "example.com"], "Opening example.com"),
            ("browser_open", [:], "Opening a page"),
            ("browser_navigate", ["action": "back"], "Going back"),
            ("browser_navigate", ["url": "example.com"], "Going to example.com"),
            ("browser_navigate", ["action": ""], "Going to a page"),
            ("browser_select", [:], "Bringing a tab forward"),
            ("browser_close", [:], "Closing a tab"),
            ("browser_click", [:], "Clicking"),
            ("browser_type", [:], "Typing"),
            ("browser_press", ["key": "Enter"], "Pressing Enter"),
            ("browser_press", [:], "Pressing a key"),
            ("browser_scroll", [:], "Scrolling"),
            ("browser_fly", [:], "browser_fly"),
        ]
        for (tool, args, expected) in cases {
            XCTAssertEqual(Chat.label(tool, args), expected, tool)
        }
    }

    func testTheSystemPromptNamesExactlyTheDeclaredTools() throws {
        let regex = try NSRegularExpression(pattern: "browser_[a-z]+")
        let prompt = AgentTools.systemPrompt
        let range = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
        let found = Set(regex.matches(in: prompt, range: range).compactMap { match -> String? in
            Range(match.range, in: prompt).map { String(prompt[$0]) }
        })
        XCTAssertEqual(found, Set(AgentTools.names))
    }

    func testTheExtensionIsValidJavaScript() throws {
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["node"]
        let found = Pipe()
        which.standardOutput = found
        which.standardError = Pipe()
        try which.run()
        which.waitUntilExit()
        guard which.terminationStatus == 0 else { throw XCTSkip("node isn't installed") }
        let node = String(data: found.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !node.isEmpty else { throw XCTSkip("node isn't installed") }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-tools-\(ProcessInfo.processInfo.processIdentifier).mjs")
        try AgentTools.extensionSource.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let check = Process()
        check.executableURL = URL(fileURLWithPath: node)
        check.arguments = ["--check", file.path]
        check.standardOutput = Pipe()
        check.standardError = Pipe()
        try check.run()
        check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0)
    }
}
