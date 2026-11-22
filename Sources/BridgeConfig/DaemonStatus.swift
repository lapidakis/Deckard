import Foundation
import Darwin

/// Whether this process has macOS Full Disk Access.
///
/// macOS has no API for this. The reliable test is to open a file that only
/// Full Disk Access unlocks: the user's TCC database exists on every account
/// and is unreadable without it. The file is opened and closed, never read.
public enum FullDiskAccess {
    public static func isGranted(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }
}

/// Facts only the daemon can know about itself, written at startup for the
/// menubar app and CLI to read.
///
/// Why a file: privacy grants belong to the process that uses them. The app
/// and a `deckard` run from Terminal have their own (different) grants, so
/// neither can answer "does the daemon have Full Disk Access?" by checking
/// itself. The daemon checks and reports.
public struct DaemonStatus: Codable, Sendable, Equatable {
    public var pid: Int32
    public var startedAt: Date
    public var fullDiskAccess: Bool
    /// What the user asked for in `[search] use_spotlight`.
    public var spotlightRequested: Bool
    /// The mail search path actually in effect.
    public var mailSearchBackend: String

    public init(pid: Int32, startedAt: Date, fullDiskAccess: Bool, spotlightRequested: Bool, mailSearchBackend: String) {
        self.pid = pid
        self.startedAt = startedAt
        self.fullDiskAccess = fullDiskAccess
        self.spotlightRequested = spotlightRequested
        self.mailSearchBackend = mailSearchBackend
    }

    enum CodingKeys: String, CodingKey {
        case pid
        case startedAt = "started_at"
        case fullDiskAccess = "full_disk_access"
        case spotlightRequested = "spotlight_requested"
        case mailSearchBackend = "mail_search_backend"
    }

    public static var fileURL: URL { BridgePaths.supportDir.appendingPathComponent("daemon-status.json") }

    public func write(to url: URL = DaemonStatus.fileURL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try PrivateFile.write(try encoder.encode(self), to: url)
    }

    /// The last status a daemon wrote, or nil. Callers should compare `pid`
    /// with the running daemon: a stale file describes a previous launch.
    public static func read(from url: URL = DaemonStatus.fileURL) -> DaemonStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DaemonStatus.self, from: data)
    }
}
