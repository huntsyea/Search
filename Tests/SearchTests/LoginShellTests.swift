import Foundation
import XCTest
@testable import Search

/// The login shell's environment, cached until it is forgotten
/// (LoginShell.swift): a program installed since Search started is found.
@MainActor
final class LoginShellTests: XCTestCase {
    /// A shell that says what the test tells it to, whatever it is asked.
    private func fakeShell(_ folder: URL, named: String, path: String) throws -> String {
        let file = folder.appendingPathComponent(named)
        try """
        #!/bin/sh
        printf '\\0__SEARCH_ENV__\\0'
        printf 'PATH=%s\\0' "\(path)"
        """.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }

    func testForgetAsksTheShellAgain() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("login-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = try fakeShell(folder, named: "first.sh", path: "/first/bin:/usr/bin:/bin")
        let second = try fakeShell(folder, named: "second.sh", path: "/second/bin:/usr/bin:/bin")

        let old = ProcessInfo.processInfo.environment["SHELL"]
        defer {
            if let old { setenv("SHELL", old, 1) } else { unsetenv("SHELL") }
            LoginShell.forget()
        }

        setenv("SHELL", first, 1)
        LoginShell.forget()
        XCTAssertTrue(LoginShell.environment["PATH"]?.hasPrefix("/first/bin") ?? false,
                      LoginShell.environment["PATH"] ?? "")

        // Still the first shell's answer, until it is forgotten.
        setenv("SHELL", second, 1)
        XCTAssertTrue(LoginShell.environment["PATH"]?.hasPrefix("/first/bin") ?? false)

        LoginShell.forget()
        XCTAssertTrue(LoginShell.environment["PATH"]?.hasPrefix("/second/bin") ?? false,
                      LoginShell.environment["PATH"] ?? "")
    }
}
