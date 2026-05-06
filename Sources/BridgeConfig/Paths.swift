import Foundation

public enum BridgePaths {
    public static let bundleID = "com.lapidakis.icloud-bridge"

    public static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("iCloud-Bridge", isDirectory: true)
    }

    public static var logsDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Logs/iCloud-Bridge", isDirectory: true)
    }

    public static var configFile: URL { supportDir.appendingPathComponent("config.toml") }
    public static var tokenFile: URL { supportDir.appendingPathComponent("token") }
    public static var auditFile: URL { logsDir.appendingPathComponent("audit.jsonl") }

    public static func ensureDirs() throws {
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    }
}
