import Foundation
import MCP
import BridgeCore

/// Write a file to iCloud Drive. WRITE — destructive in `overwrite` mode.
/// Recommended ACL is `approve` so every write pops a confirmation dialog
/// showing path, mode, and size.
struct DriveWriteTool: ToolHandler, ApprovalSummarizing {
    let name = "drive.write"
    let spec = Tool(
        name: "drive.write",
        description: """
        Write a file at `path`. Modes: create (fail if exists), overwrite,
        append. Encoding: utf-8 or base64. Pass create_dirs=true to auto-make
        missing parent directories. Returns drive.stat-shaped metadata.

        Capped at 64 MiB per call. The write goes straight into iCloud Drive
        and syncs to all the user's devices.

        Sandbox: when `[drive] write_allowed_prefixes` is set in config, the
        target path must fall under one of those prefixes; otherwise the
        write is refused. With no prefixes set, writes are allowed anywhere
        under the iCloud root. Path-safety rules (no `..` escape, no
        absolute paths) always apply.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path":        .object(["type": .string("string")]),
                "content":     .object(["type": .string("string")]),
                "encoding":    .object(["type": .string("string"), "enum": .array([.string("utf-8"), .string("base64")])]),
                "mode":        .object(["type": .string("string"), "enum": .array([.string("create"), .string("overwrite"), .string("append")])]),
                "create_dirs": .object(["type": .string("boolean")]),
            ]),
            "required": .array([.string("path"), .string("content")]),
            "additionalProperties": .bool(false),
        ])
    )

    let adapter: DriveAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard
            let path = arguments?["path"]?.stringValue,
            let content = arguments?["content"]?.stringValue
        else {
            return driveErrorResult("path and content are required")
        }
        let encoding = arguments?["encoding"]?.stringValue ?? "utf-8"
        let mode = arguments?["mode"]?.stringValue ?? "create"
        let createDirs = arguments?["create_dirs"]?.boolValue ?? false

        let stat = try await adapter.write(
            path: path, content: content,
            encoding: encoding, mode: mode, createDirs: createDirs
        )
        return driveJSON(stat)
    }

    func approvalSummary(for arguments: [String: Value]?) -> [String] {
        let path = arguments?["path"]?.stringValue ?? "(no path)"
        let mode = arguments?["mode"]?.stringValue ?? "create"
        let encoding = arguments?["encoding"]?.stringValue ?? "utf-8"
        let content = arguments?["content"]?.stringValue ?? ""
        let createDirs = arguments?["create_dirs"]?.boolValue ?? false

        var lines: [String] = ["Write to iCloud Drive (syncs to all devices)"]
        lines.append("Path: \(path)")
        lines.append("Mode: \(mode)\(mode == "overwrite" ? "  (replaces existing file)" : "")")
        lines.append("Encoding: \(encoding)")
        if createDirs { lines.append("Create dirs: yes") }
        lines.append("Bytes: \(content.utf8.count)\(encoding == "base64" ? " (base64-encoded)" : "")")

        if encoding == "utf-8" && !content.isEmpty {
            lines.append("")
            lines.append("Preview:")
            lines.append(String(content.prefix(400)))
        }
        return lines
    }
}
