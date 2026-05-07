import Foundation
import Logging
import BridgeConfig
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
import Darwin  // fnmatch for glob search

/// Filesystem operations on the iCloud Drive root, with safety rails.
///
/// All paths run through `DrivePath.resolve(...)` so traversal is impossible.
/// Reads are size-capped. Placeholder (.icloud) files are detected and
/// surfaced rather than silently returned as empty stubs. Recursive listing
/// does NOT follow symlinks (FileManager.enumerator default), avoiding loops
/// at Desktop/Documents which are symlinks back into iCloud-synced storage.
public actor DriveAdapter {
    public enum DriveError: Error, CustomStringConvertible {
        case notFound(String)
        case isDirectory(String)
        case notDirectory(String)
        case isPlaceholder(String)
        case decodingFailed(String)
        case writeRefused(String)
        case writeOutsideSandbox(path: String, allowed: [String])
        case alreadyExists(String)
        case brctlFailed(exitCode: Int32, output: String)

        public var description: String {
            switch self {
            case .notFound(let p):       return "Path not found: \(p)"
            case .isDirectory(let p):    return "Path is a directory, not a file: \(p)"
            case .notDirectory(let p):   return "Path is not a directory: \(p)"
            case .isPlaceholder(let p):  return "File is an iCloud placeholder (not downloaded). Call drive.materialize on '\(p)' first, or set drive.auto_materialize = true in config."
            case .decodingFailed(let m): return "Decoding failed: \(m)"
            case .writeRefused(let m):   return m
            case .writeOutsideSandbox(let path, let allowed):
                return "Write to '\(path)' refused: outside [drive] write_allowed_prefixes. Allowed prefixes: \(allowed.joined(separator: ", "))"
            case .alreadyExists(let p):  return "File already exists at '\(p)'. Pass mode='overwrite' to replace."
            case .brctlFailed(let code, let out): return "brctl exited \(code): \(out)"
            }
        }
    }

    /// Per-call read cap so a 200 MiB file doesn't blow up the daemon.
    public static let defaultMaxReadBytes: Int = 1 * 1024 * 1024
    public static let absoluteMaxReadBytes: Int = 16 * 1024 * 1024
    public static let absoluteMaxWriteBytes: Int = 64 * 1024 * 1024
    public static let defaultMaxDepth: Int = 5
    public static let absoluteMaxDepth: Int = 32

    private let settings: DriveConfig
    private let logger: Logger
    private let isoFormatter: ISO8601DateFormatter

    public init(settings: DriveConfig = .init(), logger: Logger = Logger(label: "bridge.drive")) {
        self.settings = settings
        self.logger = logger
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = f
    }

    // MARK: - List

    public func list(
        path relative: String,
        includeHidden: Bool = false,
        recursive: Bool = false,
        limit: Int = 200,
        maxDepth: Int = DriveAdapter.defaultMaxDepth
    ) async throws -> [DriveItem] {
        let dp = try DrivePath.resolve(relative)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dp.url.path, isDirectory: &isDir) else {
            throw DriveError.notFound(dp.relativePath)
        }
        guard isDir.boolValue else {
            throw DriveError.notDirectory(dp.relativePath)
        }

        var out: [DriveItem] = []
        if recursive {
            let cappedDepth = max(0, min(maxDepth, Self.absoluteMaxDepth))
            let enumerator = FileManager.default.enumerator(
                at: dp.url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey],
                options: includeHidden ? [] : [.skipsHiddenFiles]
            )
            while let url = enumerator?.nextObject() as? URL {
                if out.count >= limit { break }
                // FileManager.DirectoryEnumerator.level is 0-based (root=0).
                // Skip descendants once we've hit the depth cap so we still
                // include items AT max depth but don't recurse beyond.
                if let level = enumerator?.level, level >= cappedDepth {
                    enumerator?.skipDescendants()
                }
                if let item = makeItem(from: url, parent: dp.url, includePlaceholders: true) {
                    out.append(item)
                }
            }
        } else {
            let urls = try FileManager.default.contentsOfDirectory(
                at: dp.url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey],
                options: includeHidden ? [] : [.skipsHiddenFiles]
            )
            // Sort for stable output: directories first, then by name.
            let sorted = urls.sorted { a, b in
                let aDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let bDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if aDir != bDir { return aDir }
                return a.lastPathComponent.localizedCaseInsensitiveCompare(b.lastPathComponent) == .orderedAscending
            }
            for url in sorted {
                if out.count >= limit { break }
                if let item = makeItem(from: url, parent: dp.url, includePlaceholders: true) {
                    out.append(item)
                }
            }
        }
        return out
    }

    // MARK: - Stat

    public func stat(path relative: String) async throws -> DriveStat {
        let dp = try DrivePath.resolve(relative)
        var isDir: ObjCBool = false
        let fm = FileManager.default
        let physicalExists = fm.fileExists(atPath: dp.url.path, isDirectory: &isDir)

        // Placeholder check: if `<name>.icloud` doesn't exist as a real file,
        // see whether `.<name>.icloud` exists in the parent.
        if !physicalExists, let placeholderURL = placeholderStubURL(forVisible: dp.url) {
            if fm.fileExists(atPath: placeholderURL.path) {
                let attrs = try? fm.attributesOfItem(atPath: placeholderURL.path)
                return DriveStat(
                    path: dp.relativePath,
                    name: dp.url.lastPathComponent,
                    type: "file",
                    size: (attrs?[.size] as? NSNumber)?.int64Value,
                    modified: (attrs?[.modificationDate] as? Date).map { isoFormatter.string(from: $0) },
                    created: (attrs?[.creationDate] as? Date).map { isoFormatter.string(from: $0) },
                    isPlaceholder: true,
                    utiType: nil
                )
            }
        }
        guard physicalExists else { throw DriveError.notFound(dp.relativePath) }

        let attrs = try fm.attributesOfItem(atPath: dp.url.path)
        let kind: String
        if isDir.boolValue { kind = "directory" }
        else if (attrs[.type] as? FileAttributeType) == .typeSymbolicLink { kind = "symlink" }
        else { kind = "file" }

        return DriveStat(
            path: dp.relativePath,
            name: dp.url.lastPathComponent,
            type: kind,
            size: isDir.boolValue ? nil : (attrs[.size] as? NSNumber)?.int64Value,
            modified: (attrs[.modificationDate] as? Date).map { isoFormatter.string(from: $0) },
            created: (attrs[.creationDate] as? Date).map { isoFormatter.string(from: $0) },
            isPlaceholder: false,
            utiType: utiTypeOf(url: dp.url)
        )
    }

    // MARK: - Read

    public func read(
        path relative: String,
        encoding: String = "utf-8",
        maxBytes: Int = DriveAdapter.defaultMaxReadBytes,
        autoMaterialize: Bool = false
    ) async throws -> DriveContent {
        let dp = try DrivePath.resolve(relative)
        let fm = FileManager.default
        let cap = min(max(1, maxBytes), Self.absoluteMaxReadBytes)

        // Placeholder handling
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: dp.url.path, isDirectory: &isDir),
           let stub = placeholderStubURL(forVisible: dp.url),
           fm.fileExists(atPath: stub.path)
        {
            if autoMaterialize {
                try await materialize(path: relative, waitSeconds: 60)
            } else {
                throw DriveError.isPlaceholder(dp.relativePath)
            }
        }
        guard fm.fileExists(atPath: dp.url.path, isDirectory: &isDir) else {
            throw DriveError.notFound(dp.relativePath)
        }
        if isDir.boolValue { throw DriveError.isDirectory(dp.relativePath) }

        let attrs = try fm.attributesOfItem(atPath: dp.url.path)
        let total = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let toRead = Int(min(Int64(cap), total))
        let handle = try FileHandle(forReadingFrom: dp.url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: toRead) ?? Data()

        switch encoding.lowercased() {
        case "utf-8", "utf8", "":
            guard let s = String(data: data, encoding: .utf8) else {
                throw DriveError.decodingFailed("file is not valid UTF-8; pass encoding=base64 to read as binary")
            }
            return DriveContent(
                path: dp.relativePath, encoding: "utf-8",
                content: s, truncated: Int64(toRead) < total,
                bytesRead: Int64(data.count), totalBytes: total
            )
        case "base64":
            return DriveContent(
                path: dp.relativePath, encoding: "base64",
                content: data.base64EncodedString(),
                truncated: Int64(toRead) < total,
                bytesRead: Int64(data.count), totalBytes: total
            )
        default:
            throw DriveError.decodingFailed("unsupported encoding '\(encoding)'; use 'utf-8' or 'base64'")
        }
    }

    // MARK: - Write

    public func write(
        path relative: String,
        content: String,
        encoding: String = "utf-8",
        mode: String = "create",
        createDirs: Bool = false
    ) async throws -> DriveStat {
        let dp = try DrivePath.resolve(relative)
        // Block writing to the root itself.
        guard !dp.relativePath.isEmpty else {
            throw DriveError.writeRefused("cannot write to the iCloud Drive root")
        }

        // Sandbox check: when [drive] write_allowed_prefixes is non-empty, the
        // resolved path must fall under one of them. This is the file analog
        // of the mail.send approval guard — limits the blast radius of any
        // agent with drive.write enabled.
        try checkWriteAllowed(path: dp.relativePath)

        let fm = FileManager.default
        let parent = dp.url.deletingLastPathComponent()

        if !fm.fileExists(atPath: parent.path) {
            if createDirs {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            } else {
                throw DriveError.notFound(dp.relativePath + " (parent dir missing; pass create_dirs=true to auto-create)")
            }
        }

        let payload: Data
        switch encoding.lowercased() {
        case "utf-8", "utf8", "":
            payload = Data(content.utf8)
        case "base64":
            guard let d = Data(base64Encoded: content) else {
                throw DriveError.decodingFailed("base64 input did not decode")
            }
            payload = d
        default:
            throw DriveError.decodingFailed("unsupported encoding '\(encoding)'; use 'utf-8' or 'base64'")
        }

        guard payload.count <= Self.absoluteMaxWriteBytes else {
            throw DriveError.writeRefused("write of \(payload.count) bytes exceeds limit of \(Self.absoluteMaxWriteBytes)")
        }

        let exists = fm.fileExists(atPath: dp.url.path)
        switch mode.lowercased() {
        case "create":
            if exists { throw DriveError.alreadyExists(dp.relativePath) }
            try payload.write(to: dp.url, options: .atomic)
        case "overwrite":
            try payload.write(to: dp.url, options: .atomic)
        case "append":
            if exists {
                let h = try FileHandle(forWritingTo: dp.url)
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: payload)
            } else {
                try payload.write(to: dp.url, options: .atomic)
            }
        default:
            throw DriveError.writeRefused("unknown mode '\(mode)'; use create | overwrite | append")
        }

        return try await stat(path: dp.relativePath)
    }

    // MARK: - Search

    public enum SearchMatchType: String, Sendable {
        case substring, glob
    }

    public func search(
        path relative: String,
        pattern: String,
        matchType: SearchMatchType = .substring,
        fileTypeFilter: String? = nil,    // "file" | "directory" | nil
        includeHidden: Bool = false,
        limit: Int = 100,
        maxDepth: Int = 8
    ) async throws -> [DriveItem] {
        let dp = try DrivePath.resolve(relative)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dp.url.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw DriveError.notDirectory(dp.relativePath)
        }
        let cappedDepth = max(0, min(maxDepth, Self.absoluteMaxDepth))
        let enumerator = FileManager.default.enumerator(
            at: dp.url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey],
            options: includeHidden ? [] : [.skipsHiddenFiles]
        )

        let lowerPattern = pattern.lowercased()
        var out: [DriveItem] = []
        while let url = enumerator?.nextObject() as? URL {
            if out.count >= limit { break }
            if let level = enumerator?.level, level >= cappedDepth {
                enumerator?.skipDescendants()
            }
            guard let item = makeItem(from: url, parent: dp.url, includePlaceholders: true) else { continue }
            if let filter = fileTypeFilter, item.type != filter { continue }
            let nameMatches: Bool
            switch matchType {
            case .substring:
                nameMatches = item.name.lowercased().contains(lowerPattern)
            case .glob:
                nameMatches = globMatch(pattern: pattern, name: item.name)
            }
            if nameMatches {
                out.append(item)
            }
        }
        return out
    }

    // MARK: - Usage

    public func usage() async throws -> DriveUsage {
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: DrivePath.iCloudRoot.path)
        let total = (attrs[.systemSize] as? NSNumber)?.int64Value ?? 0
        let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let used = max(0, total - free)
        return DriveUsage(totalBytes: total, availableBytes: free, usedBytes: used, scope: "local_volume")
    }

    // MARK: - Materialize

    public func materialize(path relative: String, waitSeconds: Double = 0) async throws {
        let dp = try DrivePath.resolve(relative)
        let result = run(["/usr/bin/brctl", "download", dp.url.path])
        if result.exitCode != 0 {
            throw DriveError.brctlFailed(exitCode: result.exitCode, output: result.stdout + result.stderr)
        }
        if waitSeconds > 0 {
            let deadline = Date().addingTimeInterval(waitSeconds)
            let stub = placeholderStubURL(forVisible: dp.url)
            while Date() < deadline {
                if let stub, FileManager.default.fileExists(atPath: stub.path) {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                if FileManager.default.fileExists(atPath: dp.url.path) { return }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    // MARK: - Helpers

    private func checkWriteAllowed(path: String) throws {
        let prefixes = settings.writeAllowedPrefixes
        if prefixes.isEmpty { return }
        for raw in prefixes {
            let prefix = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if prefix.isEmpty { continue }
            if path == prefix || path.hasPrefix(prefix + "/") {
                return
            }
        }
        throw DriveError.writeOutsideSandbox(path: path, allowed: prefixes)
    }

    private func globMatch(pattern: String, name: String) -> Bool {
        return pattern.withCString { p in
            name.withCString { n in
                fnmatch(p, n, 0) == 0
            }
        }
    }

    private func makeItem(from url: URL, parent: URL, includePlaceholders: Bool) -> DriveItem? {
        let name = url.lastPathComponent
        let isPlaceholder = name.hasPrefix(".") && name.hasSuffix(".icloud")
        let visibleName: String
        if isPlaceholder {
            // strip leading "." and trailing ".icloud"
            visibleName = String(name.dropFirst().dropLast(".icloud".count))
        } else {
            visibleName = name
        }

        let resourceVals = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey,
        ])
        let isDir = resourceVals?.isDirectory ?? false
        let isLink = resourceVals?.isSymbolicLink ?? false
        let kind: String
        if isPlaceholder { kind = "file" }
        else if isDir { kind = "directory" }
        else if isLink { kind = "symlink" }
        else { kind = "file" }

        let visiblePath: String
        let parentRel = parent.path.replacingOccurrences(of: DrivePath.iCloudRoot.path, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if parentRel.isEmpty {
            visiblePath = visibleName
        } else {
            visiblePath = "\(parentRel)/\(visibleName)"
        }

        return DriveItem(
            path: visiblePath,
            name: visibleName,
            type: kind,
            size: isDir ? nil : Int64(resourceVals?.fileSize ?? 0),
            modified: resourceVals?.contentModificationDate.map { isoFormatter.string(from: $0) },
            isPlaceholder: isPlaceholder
        )
    }

    /// Given a visible URL like ".../Documents/foo.txt", return the stub URL
    /// ".../Documents/.foo.txt.icloud" if it would exist for an offloaded file.
    private func placeholderStubURL(forVisible url: URL) -> URL? {
        let name = url.lastPathComponent
        guard !name.isEmpty, !name.hasPrefix(".") else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent(".\(name).icloud")
    }

    private func utiTypeOf(url: URL) -> String? {
        #if canImport(UniformTypeIdentifiers)
        if let resVals = try? url.resourceValues(forKeys: [.contentTypeKey]),
           let type = resVals.contentType {
            return type.identifier
        }
        #endif
        return nil
    }

    private struct CommandResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private func run(_ argv: [String]) -> CommandResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: argv[0])
        proc.arguments = Array(argv.dropFirst())
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
            let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            return CommandResult(
                exitCode: proc.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        } catch {
            return CommandResult(exitCode: -1, stdout: "", stderr: "\(error)")
        }
    }
}
