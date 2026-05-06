import Foundation
import Logging
import BridgeConfig

/// Append-only JSONL writer with file rotation deferred to v2.
///
/// Writes are serialized through an actor; each `record` call emits exactly
/// one line. fsync after every write — audit log integrity is worth the cost
/// at this volume.
public actor AuditSink {
    private let url: URL
    private let logger: Logger
    private let encoder: JSONEncoder
    private let isoFormatter: ISO8601DateFormatter

    public init(url: URL = BridgePaths.auditFile, logger: Logger = Logger(label: "bridge.audit")) {
        self.url = url
        self.logger = logger
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        self.encoder = enc
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = fmt
    }

    public func record(_ event: AuditEvent) {
        do {
            try BridgePaths.ensureDirs()
            let data = try encoder.encode(event) + Data([0x0A]) // newline
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            logger.error("Audit write failed: \(error)")
        }
    }

    public func nowISO() -> String {
        isoFormatter.string(from: Date())
    }
}
