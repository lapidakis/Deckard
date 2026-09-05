import Foundation
import Darwin

/// Publish private state atomically without a write-then-chmod exposure window.
public enum PrivateFile {
    public static func write(_ data: Data, to url: URL) throws {
        var template = Array(url.deletingLastPathComponent()
            .appendingPathComponent(".deckard-XXXXXX").path.utf8CString)
        let fd = mkstemp(&template) // O_EXCL and 0600 before any secret is written.
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let temporary = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer {
            try? handle.close()
            unlink(temporary)
        }
        guard fchmod(fd, 0o600) == 0 else { throw POSIXError(.EACCES) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporary, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
