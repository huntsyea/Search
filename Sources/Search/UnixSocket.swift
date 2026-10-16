import Darwin
import Foundation

/// Unix sockets only this user can reach: the bench's and each chat's tools'.
///
/// The file mode says who may open it; the peer check says who did. Both are
/// wanted — the mode is a promise about the folder, and the folder's own
/// permissions are somebody else's to change.
enum UnixSocket {
    /// A socket listening at `path` (any old one there removed first), mode
    /// 0600, non-blocking; nil if it can't be.
    static func listen(at path: String, backlog: Int32 = 8) -> Int32? {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        // A path too long for sun_path has nowhere to be bound.
        guard let bound = withAddress(path, { pointer, size in bind(fd, pointer, size) }) else {
            close(fd)
            unlink(path)
            return nil
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, backlog) == 0 else {
            close(fd)
            unlink(path)
            return nil
        }
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    /// A connection to `path`, blocking; nil if there's none.
    static func connect(to path: String) -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard let joined = withAddress(path, { pointer, size in Darwin.connect(fd, pointer, size) }) else {
            close(fd)
            return nil
        }
        guard joined == 0 else { close(fd); return nil }
        return fd
    }

    /// Whether the process at the other end of `fd` is this user's.
    static func peerIsMe(_ fd: Int32) -> Bool {
        var uid = uid_t(0)
        var gid = gid_t(0)
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    /// `path` as a sockaddr_un, handed to `body` with its length; nil when the
    /// path doesn't fit.
    private static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let room = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < room else { return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { sun in
            sun.withMemoryRebound(to: CChar.self, capacity: room) { bytes in
                _ = strlcpy(bytes, path, room)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, size) }
        }
    }
}
