import Foundation
import Logging

public enum BridgePaths {
    public static let bundleID = "com.lapidakis.deckard"
    public static let appName = "Deckard"

    /// Reverse-DNS of the prior project name. Carried so the in-code
    /// migrator can detect a pre-rename install and move state to the
    /// new locations without losing tokens or audit history.
    public static let legacyBundleID = "com.lapidakis.icloud-bridge"
    public static let legacyAppName = "iCloud-Bridge"

    public static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    public static var logsDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Logs/\(appName)", isDirectory: true)
    }

    public static var configFile: URL { supportDir.appendingPathComponent("config.toml") }
    public static var tokenFile: URL { supportDir.appendingPathComponent("token") }       // legacy v0.7 single-token
    public static var tokensFile: URL { supportDir.appendingPathComponent("tokens.toml") } // v0.8+ multi-token
    public static var auditFile: URL { logsDir.appendingPathComponent("audit.jsonl") }

    /// Pre-rename equivalents. Used by the one-shot migrator below.
    public static var legacySupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(legacyAppName, isDirectory: true)
    }

    public static var legacyLogsDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Logs/\(legacyAppName)", isDirectory: true)
    }

    public static func ensureDirs() throws {
        // Migrate pre-rename state (iCloud-Bridge → Deckard) before creating
        // empty new dirs. If we created `Application Support/Deckard` first,
        // the move below would refuse and the user's tokens.toml would be
        // orphaned at the legacy path.
        migrateLegacyStateIfNeeded()
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    }

    /// Moves pre-rename state directories into place if the legacy paths
    /// exist and the new ones don't. Idempotent: a second call is a no-op
    /// because the new dirs now exist (so the `legacy exists && new doesn't`
    /// guard is false). Safe to call from both daemon startup and the
    /// `install` CLI command.
    ///
    /// We deliberately use `moveItem` rather than copy-then-delete so the
    /// 0600 mode on `tokens.toml` is preserved without a second `chmod`.
    public static func migrateLegacyStateIfNeeded(
        logger: Logger = Logger(label: "bridge.paths.migrator")
    ) {
        let fm = FileManager.default

        if fm.fileExists(atPath: legacySupportDir.path),
           !fm.fileExists(atPath: supportDir.path) {
            do {
                try fm.moveItem(at: legacySupportDir, to: supportDir)
                logger.info("Migrated state: \(legacySupportDir.path) → \(supportDir.path)")
            } catch {
                logger.error("Failed to migrate \(legacySupportDir.path): \(error)")
            }
        }

        if fm.fileExists(atPath: legacyLogsDir.path),
           !fm.fileExists(atPath: logsDir.path) {
            do {
                try fm.moveItem(at: legacyLogsDir, to: logsDir)
                logger.info("Migrated logs: \(legacyLogsDir.path) → \(logsDir.path)")
            } catch {
                logger.error("Failed to migrate \(legacyLogsDir.path): \(error)")
            }
        }
    }
}
