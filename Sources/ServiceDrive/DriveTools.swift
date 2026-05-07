import Foundation
import MCP
import BridgeCore
import BridgeConfig

/// MCP tool handlers for iCloud Drive.
///
/// Read tools: list, stat, read, search, usage, materialize.
/// Write tool (in DriveWriteTool.swift): write — gated by approval AND
/// optional `[drive] write_allowed_prefixes` sandbox in config.
public struct DriveTools: ToolProvider {
    public let handlers: [any ToolHandler]

    public init(adapter: DriveAdapter = DriveAdapter()) {
        self.handlers = [
            DriveListTool(adapter: adapter),
            DriveStatTool(adapter: adapter),
            DriveReadTool(adapter: adapter),
            DriveSearchTool(adapter: adapter),
            DriveUsageTool(adapter: adapter),
            DriveMaterializeTool(adapter: adapter),
            DriveWriteTool(adapter: adapter),
        ]
    }
}

// MARK: - drive.list

struct DriveListTool: ToolHandler {
    let name = "drive.list"
    let returnsUntrustedContent = true   // file names + content from arbitrary sources
    let spec = Tool(
        name: "drive.list",
        description: """
        List entries in an iCloud Drive directory. `path` is relative to the
        iCloud root (`~/Library/Mobile Documents/com~apple~CloudDocs`); empty
        or "." lists the root. Hidden files filtered unless include_hidden.
        Recursion is opt-in and capped by max_depth (default 5, max 32).

        .icloud placeholders surface as their visible name with
        is_placeholder=true. Symlinks return type=symlink and are NOT
        followed during recursion (avoids loops at Desktop/Documents which
        are symlinks back into iCloud-synced storage).

        Path safety: paths containing `..` segments that escape root, and
        absolute paths, are rejected with a typed error.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path":           .object(["type": .string("string"), "description": .string("Relative path. Empty / '.' = iCloud root.")]),
                "include_hidden": .object(["type": .string("boolean")]),
                "recursive":      .object(["type": .string("boolean")]),
                "max_depth":      .object(["type": .string("integer"), "description": .string("Recursion cap (0..32). Defaults to 5. Ignored when recursive=false.")]),
                "limit":          .object(["type": .string("integer"), "description": .string("Max entries (1-1000). Defaults to 200.")]),
            ]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: DriveAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        let path = arguments?["path"]?.stringValue ?? ""
        let hidden = arguments?["include_hidden"]?.boolValue ?? false
        let recursive = arguments?["recursive"]?.boolValue ?? false
        let maxDepth = arguments?["max_depth"]?.intValue ?? DriveAdapter.defaultMaxDepth
        let limit = max(1, min(1000, arguments?["limit"]?.intValue ?? 200))
        let items = try await adapter.list(
            path: path, includeHidden: hidden, recursive: recursive,
            limit: limit, maxDepth: maxDepth
        )
        return driveJSON(items)
    }
}

// MARK: - drive.stat

struct DriveStatTool: ToolHandler {
    let name = "drive.stat"
    let returnsUntrustedContent = true
    let spec = Tool(
        name: "drive.stat",
        description: "Metadata for one path: size, modified, created, type, is_placeholder, uti_type. Lighter than list when you only need one entry. Path-safety rules same as drive.list.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("path")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: DriveAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let path = arguments?["path"]?.stringValue else {
            return driveErrorResult("path is required")
        }
        let stat = try await adapter.stat(path: path)
        return driveJSON(stat)
    }
}

// MARK: - drive.read

struct DriveReadTool: ToolHandler {
    let name = "drive.read"
    let returnsUntrustedContent = true
    let spec = Tool(
        name: "drive.read",
        description: """
        Read a file. Default encoding is utf-8 (text). Pass encoding=base64 for
        binary. Reads cap at 1 MiB by default, max 16 MiB; if total_bytes >
        bytes_read, the response carries truncated=true and the agent can
        re-read with a higher max_bytes if needed.

        If the file is an iCloud placeholder (.icloud stub), the call errors
        unless auto_materialize=true (which triggers brctl download and waits
        up to 60s for it to complete).
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path":             .object(["type": .string("string")]),
                "encoding":         .object(["type": .string("string"), "enum": .array([.string("utf-8"), .string("base64")])]),
                "max_bytes":        .object(["type": .string("integer"), "description": .string("Cap on bytes read (1..16777216). Default 1048576.")]),
                "auto_materialize": .object(["type": .string("boolean"), "description": .string("If true and file is a placeholder, run brctl download and wait.")]),
            ]),
            "required": .array([.string("path")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: DriveAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let path = arguments?["path"]?.stringValue else {
            return driveErrorResult("path is required")
        }
        let encoding = arguments?["encoding"]?.stringValue ?? "utf-8"
        let maxBytes = arguments?["max_bytes"]?.intValue ?? DriveAdapter.defaultMaxReadBytes
        let auto = arguments?["auto_materialize"]?.boolValue ?? false
        let content = try await adapter.read(
            path: path, encoding: encoding, maxBytes: maxBytes, autoMaterialize: auto
        )
        return driveJSON(content)
    }
}

// MARK: - drive.search

struct DriveSearchTool: ToolHandler {
    let name = "drive.search"
    let returnsUntrustedContent = true
    let spec = Tool(
        name: "drive.search",
        description: """
        Find entries by name pattern under `path`. Match types:
          - "substring": case-insensitive substring match (default; safe shape)
          - "glob":      POSIX fnmatch (e.g. "*.pdf", "Invoice-2026-*.csv")

        Bounded by limit (default 100, max 1000) and max_depth (default 8,
        max 32). Optional file_type filter ("file" | "directory") narrows
        results. Symlinks not followed; placeholders included with
        is_placeholder=true.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path":           .object(["type": .string("string"), "description": .string("Start dir. Empty = iCloud root.")]),
                "pattern":        .object(["type": .string("string")]),
                "match_type":     .object(["type": .string("string"), "enum": .array([.string("substring"), .string("glob")])]),
                "file_type":      .object(["type": .string("string"), "enum": .array([.string("file"), .string("directory")])]),
                "include_hidden": .object(["type": .string("boolean")]),
                "max_depth":      .object(["type": .string("integer")]),
                "limit":          .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("pattern")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: DriveAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let pattern = arguments?["pattern"]?.stringValue, !pattern.isEmpty else {
            return driveErrorResult("pattern is required")
        }
        let path = arguments?["path"]?.stringValue ?? ""
        let matchTypeRaw = arguments?["match_type"]?.stringValue ?? "substring"
        let matchType = DriveAdapter.SearchMatchType(rawValue: matchTypeRaw) ?? .substring
        let fileType = arguments?["file_type"]?.stringValue
        let hidden = arguments?["include_hidden"]?.boolValue ?? false
        let maxDepth = arguments?["max_depth"]?.intValue ?? 8
        let limit = max(1, min(1000, arguments?["limit"]?.intValue ?? 100))
        let items = try await adapter.search(
            path: path, pattern: pattern, matchType: matchType,
            fileTypeFilter: fileType, includeHidden: hidden,
            limit: limit, maxDepth: maxDepth
        )
        return driveJSON(items)
    }
}

// MARK: - drive.usage

struct DriveUsageTool: ToolHandler {
    let name = "drive.usage"
    let spec = Tool(
        name: "drive.usage",
        description: """
        Free / used / total bytes on the local volume backing iCloud Drive.

        IMPORTANT: this is the local Mac filesystem's space, NOT the user's
        iCloud account quota (which lives in a separate Apple API surface
        we haven't wired up). Useful for "is the disk about to be full
        before this write?" sanity checks; not for "how much iCloud space
        is left in my plan?"
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: DriveAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        let usage = try await adapter.usage()
        return driveJSON(usage)
    }
}

// MARK: - drive.materialize

struct DriveMaterializeTool: ToolHandler {
    let name = "drive.materialize"
    let spec = Tool(
        name: "drive.materialize",
        description: """
        Trigger a download of an offloaded iCloud file. Equivalent to clicking
        the cloud icon in Finder. If wait_seconds > 0, blocks until the file
        materializes or the timeout elapses (returns regardless).
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path":         .object(["type": .string("string")]),
                "wait_seconds": .object(["type": .string("integer"), "description": .string("0 = fire and return immediately; >0 = block up to N seconds (max 300).")]),
            ]),
            "required": .array([.string("path")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: DriveAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let path = arguments?["path"]?.stringValue else {
            return driveErrorResult("path is required")
        }
        let wait = max(0, min(300, arguments?["wait_seconds"]?.intValue ?? 0))
        try await adapter.materialize(path: path, waitSeconds: Double(wait))
        return CallTool.Result(
            content: [.text(text: #"{"materialized":true}"#, annotations: nil, _meta: nil)],
            isError: false
        )
    }
}

// MARK: - JSON helpers (file-scope so write tool can reuse)

func driveJSON<T: Encodable>(_ value: T) -> CallTool.Result {
    do {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let data = try enc.encode(value)
        let s = String(data: data, encoding: .utf8) ?? "{}"
        return CallTool.Result(content: [.text(text: s, annotations: nil, _meta: nil)], isError: false)
    } catch {
        return driveErrorResult("encode failed: \(error)")
    }
}

func driveErrorResult(_ message: String) -> CallTool.Result {
    CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
}
