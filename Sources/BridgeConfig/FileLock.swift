import Foundation
import Darwin

/// Advisory lock shared by daemon, UI and CLI processes. Keep the lock file
/// separate from data files that are atomically replaced, and never unlink it.
public enum FileLock {
    public static func withExclusiveAccess<T>(to url: URL, _ body: () throws -> T) throws -> T {
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
