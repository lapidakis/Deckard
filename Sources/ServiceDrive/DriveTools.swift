import Foundation
import MCP
import BridgeCore

/// MCP tool handlers for iCloud Drive.
///
/// Read tools: list, stat, read, materialize.
/// Write tool (in DriveWriteTool.swift): write — gated by approval.
public struct DriveTools: ToolProvider {
    public let handlers: [any ToolHandler]

    public init(adapter: DriveAdapter = DriveAdapter()) {
        self.handlers = [
            DriveListTool(adapter: adapter),
            DriveStatTool(adapter: adapter),
            DriveReadTool(adapter: adapter),
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
        or "." lists the root. Hidden files filtered unless include_hidden is
        true. Recursion is opt-in. .icloud placeholders surface as their visible
        name with is_placeholder=true.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path":           .object(["type": .string("string"), "description": .string("Relative path. Empty / '.' = iCloud root.")]),
                "include_hidden": .object(["type": .string("boolean")]),
                "recursive":      .object(["type": .string("boolean")]),
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
        let limit = max(1, min(1000, arguments?["limit"]?.intValue ?? 200))
        let items = try await adapter.list(
            path: path, includeHidden: hidden, recursive: recursive, limit: limit
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
        description: "Metadata for one path: size, modified, created, type, is_placeholder, uti_type. Lighter than list when you only need one entry.",
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
