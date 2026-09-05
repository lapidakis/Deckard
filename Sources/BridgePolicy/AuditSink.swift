import Foundation
import Logging
import BridgeConfig

/// Append-only JSONL audit log with retention sweep.
///
/// Writes are serialized through this actor; each `record` call emits exactly
/// one line, fsync'd to disk. The same actor handles `prune` so writes and
/// pruning can't race each other (atomic rewrite would otherwise drop entries
/// written during the rename window).
public actor AuditSink {
    private let url: URL
    private let enabled: Bool
    private let logger: Logger
    private let encoder: JSONEncoder
    private let isoFormatter: ISO8601DateFormatter

    public init(url: URL = BridgePaths.auditFile, enabled: Bool = true, logger: Logger = Logger(label: "bridge.audit")) {
        self.url = url
        self.enabled = enabled
        self.logger = logger
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        self.encoder = enc
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = fmt
    }

    public func record(_ event: AuditEvent) {
        guard enabled else { return }
        do {
            if url == BridgePaths.auditFile { try BridgePaths.ensureDirs() }
            else { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
            try FileLock.withExclusiveAccess(to: url.appendingPathExtension("lock")) {
                let data = try encoder.encode(event) + Data([0x0A]) // newline
                if !FileManager.default.fileExists(atPath: url.path) {
                    try PrivateFile.write(Data(), to: url)
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.synchronize()
            }
        } catch {
            logger.error("Audit write failed: \(error)")
        }
    }

    public func nowISO() -> String {
        isoFormatter.string(from: Date())
    }

    /// Drop entries older than `retentionDays` days. retentionDays <= 0 is a
    /// no-op (keep forever). Returns (kept, removed) for logging.
    ///
    /// Implementation: read the whole file, parse just the `ts` field per
    /// line, filter, write back atomically. Runs on the actor's executor so
    /// no concurrent `record` call can interleave.
    @discardableResult
    public func prune(retentionDays: Int) -> (kept: Int, removed: Int) {
        guard enabled, FileManager.default.fileExists(atPath: url.path) else { return (0, 0) }
        do {
            return try FileLock.withExclusiveAccess(to: url.appendingPathExtension("lock")) {
                pruneLocked(retentionDays: retentionDays)
            }
        } catch {
            logger.error("Audit prune lock unavailable")
            return (0, 0)
        }
    }

    private func pruneLocked(retentionDays: Int) -> (kept: Int, removed: Int) {
        guard retentionDays > 0 else { return (0, 0) }
        guard FileManager.default.fileExists(atPath: url.path) else { return (0, 0) }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        let cutoffStr = isoFormatter.string(from: cutoff)

        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            logger.error("Audit prune: read failed: \(error)")
            return (0, 0)
        }

        var keptLines: [Substring] = []
        var removed = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // Decode JSON before reading ts so escaped content cannot impersonate a field.
            if let ts = Self.extractTs(from: line), let date = isoFormatter.date(from: ts), date < cutoff {
                removed += 1
            } else {
                // Preserve malformed/unknown timestamps as forensic evidence.
                keptLines.append(line)
            }
        }

        if removed == 0 { return (keptLines.count, 0) }

        let newContent = keptLines.joined(separator: "\n") + (keptLines.isEmpty ? "" : "\n")
        do {
            try PrivateFile.write(Data(newContent.utf8), to: url)
        } catch {
            logger.error("Audit prune: write failed (no entries dropped): \(error)")
            return (keptLines.count + removed, 0)
        }
        logger.info("Audit pruned: kept=\(keptLines.count) removed=\(removed) cutoff=\(cutoffStr)")
        return (keptLines.count, removed)
    }

    private static func extractTs(from line: Substring) -> String? {
        guard let data = String(line).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["ts"] as? String
    }
}
