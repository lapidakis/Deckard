import Foundation
import Darwin

/// Whether this process has macOS Full Disk Access.
///
/// macOS has no API for this. The test is to open a location that only Full
/// Disk Access unlocks and look at the error: "Operation not permitted" means
/// the privacy system refused, success means it is granted, and "No such
/// file" says nothing (the user may not use that app), so the next location
/// is tried. Nothing is read.
///
/// Do not rely on the per-user TCC database alone: on macOS 27 it is not at
/// `~/Library/Application Support/com.apple.TCC/TCC.db`, so that check
/// reported "not granted" for a daemon that could read Mail.
public enum FullDiskAccess {
    /// Protected locations, most relevant first. (path under home, is directory)
    static let probes: [(String, Bool)] = [
        ("Library/Mail", true),
        ("Library/Safari", true),
        ("Library/Messages", true),
        ("Library/Application Support/com.apple.TCC/TCC.db", false),
    ]

    public static func isGranted(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        diagnose(home: home).granted
    }

    /// The same check with the reason attached, for the startup log.
    public static func diagnose(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (granted: Bool, detail: String) {
        var notes: [String] = []
        for (relative, isDirectory) in probes {
            let path = home.appendingPathComponent(relative).path
            let fd = open(path, isDirectory ? (O_RDONLY | O_DIRECTORY) : O_RDONLY)
            if fd >= 0 {
                close(fd)
                return (true, "\(relative)=ok")
            }
            let code = errno
            notes.append("\(relative)=\(String(cString: strerror(code)))")
            // Refused by the privacy system: definitely not granted.
            if code == EPERM || code == EACCES { return (false, notes.joined(separator: " ")) }
        }
        // Nothing protected exists to test against; assume not granted.
        return (false, notes.joined(separator: " "))
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
    /// What the user asked for in `[search] fast_search`.
    public var fastSearchRequested: Bool
    /// The mail search path actually in effect.
    public var mailSearchBackend: String

    public init(pid: Int32, startedAt: Date, fullDiskAccess: Bool, fastSearchRequested: Bool, mailSearchBackend: String) {
        self.pid = pid
        self.startedAt = startedAt
        self.fullDiskAccess = fullDiskAccess
        self.fastSearchRequested = fastSearchRequested
        self.mailSearchBackend = mailSearchBackend
    }

    enum CodingKeys: String, CodingKey {
        case pid
        case startedAt = "started_at"
        case fullDiskAccess = "full_disk_access"
        case fastSearchRequested = "fast_search_requested"
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
