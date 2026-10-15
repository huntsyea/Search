import Foundation
import Darwin
import WebKit

/// Replaces an extension's folder without removing the installed copy
/// first, and makes WebKit serve the new files.
enum ExtensionFiles {
    /// New files for an extension in place of its old ones, as WebKit will
    /// serve them. WebKit's pages keep in memory what they loaded, by
    /// address, and an extension's addresses stay the same from one copy of
    /// its files to the next — so after a Reload, an update or installing it
    /// again, its worker and pages ran the old scripts until Search was quit.
    /// That memory goes with the old files: every site's, as WebKit keeps it
    /// for all of them at once. Nothing on disk is touched; pages read again
    /// what they need.
    /// On success, an existing target is atomically swapped onto `staged`;
    /// callers own cleaning up that old folder after releasing its consumers.
    static func replace(_ staged: URL, at target: URL, in store: WKWebsiteDataStore) async throws {
        try swap(staged, at: target)
        await store.removeData(ofTypes: [WKWebsiteDataTypeMemoryCache], modifiedSince: .distantPast)
    }

    /// The folder swapped in alone, for this file's own tests
    /// (Tests/ExtensionFilesTests.swift); everything else calls replace, so
    /// that WebKit serves the new files.
    /// On success, an existing target is atomically swapped onto `staged`;
    /// callers own cleaning up that old folder after releasing its consumers.
    static func swap(_ staged: URL, at target: URL) throws {
        if let error = renameError(staged, target, flags: RENAME_EXCL) {
            guard error == EEXIST else { throw replacementError(error, staged: staged, target: target) }
            if let error = renameError(staged, target, flags: RENAME_SWAP) {
                throw replacementError(error, staged: staged, target: target)
            }
        }
    }

    /// A nil result means the rename worked. On failure, errno is read before
    /// doing anything else so the error describes the syscall that failed.
    private static func renameError(_ staged: URL, _ target: URL, flags: Int32) -> Int32? {
        staged.withUnsafeFileSystemRepresentation { source in
            target.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else { return EINVAL }
                guard renamex_np(source, destination, UInt32(flags)) != 0 else { return nil }
                let error = errno
                return error
            }
        }
    }

    private static func replacementError(_ code: Int32, staged: URL, target: URL) -> NSError {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: "Couldn't replace extension at \(target.path): \(posix.localizedDescription)",
                NSFilePathErrorKey: target.path,
                "ExtensionStagedPath": staged.path,
            ]
        )
    }
}
