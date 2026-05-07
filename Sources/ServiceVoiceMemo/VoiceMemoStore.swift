import Foundation
import SQLite3
import Logging

/// Read-only SQLite access to Voice Memos' CloudRecordings.db.
///
/// Schema notes (discovered empirically on macOS 26):
///   - Table:           ZCLOUDRECORDING
///   - Stable id:       ZUNIQUEID (UUID; preserved across iCloud sync)
///   - Date:            ZDATE — seconds since Core Data epoch (2001-01-01 UTC)
///   - Duration:        ZDURATION — seconds (float)
///   - Filename:        ZPATH — relative to the Recordings dir
///   - Title:           ZENCRYPTEDTITLE — DESPITE the name, this is plaintext
///                      on macOS. Empty when the user hasn't renamed.
///   - Auto label:      ZCUSTOMLABEL — date-shaped fallback when title is empty
///   - Folder ref:      ZFOLDER — int FK to ZFOLDER table
///
/// Transcripts are NOT stored in this database. Voice Memos.app computes them
/// at view time via Speech framework. Agents that want transcripts should pull
/// the audio (`voice_memo.read_audio`) and run their own STT.
public actor VoiceMemoStore {

    public enum StoreError: Error, CustomStringConvertible {
        case databaseMissing(String)
        case open(String)
        case query(String)
        case notFound(String)

        public var description: String {
            switch self {
            case .databaseMissing(let p):
                return "Voice Memos database not found at \(p). Enable iCloud Voice Memos sync (Settings → Apple ID → iCloud → Voice Memos) and wait for at least one recording to sync."
            case .open(let m):     return "Failed to open Voice Memos database: \(m)"
            case .query(let m):    return "Voice Memos query failed: \(m)"
            case .notFound(let id): return "No recording with id '\(id)'"
            }
        }
    }

    /// Default location of the Voice Memos shared Group Container database.
    public static var defaultDatabasePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db"
    }

    /// Default location of the audio files (siblings of the db).
    public static var defaultRecordingsDir: URL {
        URL(fileURLWithPath: defaultDatabasePath).deletingLastPathComponent()
    }

    /// Core Data epoch in unix seconds: 2001-01-01T00:00:00Z.
    private static let coreDataEpochOffset: Double = 978_307_200

    private let dbPath: String
    private let recordingsDir: URL
    private let logger: Logger

    public init(
        dbPath: String = VoiceMemoStore.defaultDatabasePath,
        recordingsDir: URL = VoiceMemoStore.defaultRecordingsDir,
        logger: Logger = Logger(label: "bridge.voicememo")
    ) {
        self.dbPath = dbPath
        self.recordingsDir = recordingsDir
        self.logger = logger
    }

    public func listRecordings(
        sinceISO: String? = nil,
        beforeISO: String? = nil,
        limit: Int = 50
    ) throws -> [VoiceMemoSummary] {
        let db = try openReadOnly()
        defer { sqlite3_close(db) }

        var sql = """
            SELECT ZUNIQUEID, ZDATE, ZDURATION, ZPATH,
                   COALESCE(ZENCRYPTEDTITLE, ''), COALESCE(ZCUSTOMLABEL, '')
            FROM ZCLOUDRECORDING
            WHERE 1=1
            """
        if let s = sinceISO, let parsed = parseISO(s) {
            sql += " AND ZDATE >= \(parsed - Self.coreDataEpochOffset)"
        }
        if let b = beforeISO, let parsed = parseISO(b) {
            sql += " AND ZDATE < \(parsed - Self.coreDataEpochOffset)"
        }
        sql += " ORDER BY ZDATE DESC LIMIT \(max(1, min(500, limit)))"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.query("prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }

        var out: [VoiceMemoSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let uniqueID = readText(stmt, 0)
            let date = sqlite3_column_double(stmt, 1)
            let duration = sqlite3_column_double(stmt, 2)
            let path = readText(stmt, 3)
            let title = readText(stmt, 4)
            let label = readText(stmt, 5)
            let displayTitle = title.isEmpty ? label : title

            let absURL = recordingsDir.appendingPathComponent(path)
            let (exists, size, isPlaceholder) = fileFacts(visible: absURL)
            out.append(VoiceMemoSummary(
                id: uniqueID,
                title: displayTitle,
                recordedAt: formatISO(date + Self.coreDataEpochOffset),
                durationSeconds: duration,
                filename: path,
                hasLocalFile: exists && !isPlaceholder,
                fileSizeBytes: size
            ))
        }
        return out
    }

    public func getRecording(id: String) throws -> VoiceMemoDetail {
        let db = try openReadOnly()
        defer { sqlite3_close(db) }

        let sql = """
            SELECT ZUNIQUEID, ZDATE, ZDURATION, ZPATH,
                   COALESCE(ZENCRYPTEDTITLE, ''), COALESCE(ZCUSTOMLABEL, ''),
                   (SELECT ZUUID FROM ZFOLDER WHERE Z_PK = ZCLOUDRECORDING.ZFOLDER)
            FROM ZCLOUDRECORDING
            WHERE ZUNIQUEID = ?1
            LIMIT 1
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.query("prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, sqliteTransient)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw StoreError.notFound(id)
        }
        let uniqueID = readText(stmt, 0)
        let date = sqlite3_column_double(stmt, 1)
        let duration = sqlite3_column_double(stmt, 2)
        let path = readText(stmt, 3)
        let title = readText(stmt, 4)
        let label = readText(stmt, 5)
        let folder: String? = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : readText(stmt, 6)
        let displayTitle = title.isEmpty ? label : title

        let absURL = recordingsDir.appendingPathComponent(path)
        let (exists, size, isPlaceholder) = fileFacts(visible: absURL)
        return VoiceMemoDetail(
            id: uniqueID,
            title: displayTitle,
            recordedAt: formatISO(date + Self.coreDataEpochOffset),
            durationSeconds: duration,
            filename: path,
            absolutePath: absURL.path,
            hasLocalFile: exists && !isPlaceholder,
            fileSizeBytes: size,
            folderUUID: folder,
            autoGeneratedLabel: label
        )
    }

    /// Resolve the audio file URL for a recording, validating that it lives
    /// under the Recordings directory (defense in depth against ZPATH being
    /// modified by a hostile DB write).
    public func audioURL(forRecordingID id: String) throws -> URL {
        let detail = try getRecording(id: id)
        let url = recordingsDir.appendingPathComponent(detail.filename).standardizedFileURL
        let recordingsRoot = recordingsDir.standardizedFileURL.path
        guard url.path.hasPrefix(recordingsRoot + "/") else {
            throw StoreError.query("recording path '\(detail.filename)' resolves outside Recordings dir")
        }
        return url
    }

    // MARK: - Helpers

    private func openReadOnly() throws -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw StoreError.databaseMissing(dbPath)
        }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(dbPath, &db, flags, nil) != SQLITE_OK {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw StoreError.open(msg)
        }
        return db
    }

    private func readText(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        guard let cstr = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: cstr)
    }

    private func parseISO(_ s: String) -> Double? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d.timeIntervalSince1970 }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: s) { return d.timeIntervalSince1970 }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.timeZone = TimeZone(identifier: "UTC")
        if let d = day.date(from: s) { return d.timeIntervalSince1970 }
        return nil
    }

    private func formatISO(_ unix: Double) -> String {
        let date = Date(timeIntervalSince1970: unix)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// Looks for both the visible file and a `.<basename>.icloud` placeholder
    /// stub. Returns (file_exists_at_visible_path, size_bytes, is_placeholder).
    private func fileFacts(visible: URL) -> (Bool, Int64?, Bool) {
        let fm = FileManager.default
        if fm.fileExists(atPath: visible.path) {
            let attrs = try? fm.attributesOfItem(atPath: visible.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value
            return (true, size, false)
        }
        let stub = visible.deletingLastPathComponent()
            .appendingPathComponent(".\(visible.lastPathComponent).icloud")
        if fm.fileExists(atPath: stub.path) {
            let attrs = try? fm.attributesOfItem(atPath: stub.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value
            return (false, size, true)
        }
        return (false, nil, false)
    }
}

/// SQLITE_TRANSIENT helper — instructs SQLite to copy the bound text rather
/// than borrow our pointer (the Swift String backing store may be freed).
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum CoreDataEpoch {
    public static let unixOffset: Double = 978_307_200   // 2001-01-01 UTC
    public static func toUnix(_ coreDataSeconds: Double) -> Double { coreDataSeconds + unixOffset }
    public static func fromUnix(_ unixSeconds: Double) -> Double { unixSeconds - unixOffset }
}
