import Foundation
import MCP
import BridgeCore

/// MCP tool handlers for Voice Memos.app — read-only.
///
/// Voice Memos doesn't persist transcripts in its SQLite store; agents that
/// want transcripts should pull the audio via `voice_memo.read_audio` and
/// run their own STT (Whisper, Apple Speech via a separate tool, etc.).
public struct VoiceMemoTools: ToolProvider {
    public let handlers: [any ToolHandler]

    public init(store: VoiceMemoStore = VoiceMemoStore()) {
        self.handlers = [
            VoiceMemoListTool(store: store),
            VoiceMemoGetTool(store: store),
            VoiceMemoReadAudioTool(store: store),
        ]
    }
}

// MARK: - voice_memo.list_recordings

struct VoiceMemoListTool: ToolHandler {
    let name = "voice_memo.list_recordings"
    let returnsUntrustedContent = true   // titles are user-supplied; treat as data
    let spec = Tool(
        name: "voice_memo.list_recordings",
        description: """
        List Voice Memos recordings, most recent first. Returns id, title,
        recorded_at (ISO 8601 UTC), duration_seconds, filename,
        has_local_file, file_size_bytes.

        `since` / `before` filter by recording date (ISO 8601 or yyyy-MM-dd).
        `limit` defaults to 50, max 500.

        Voice Memos transcription is NOT persisted; this tool only returns
        metadata. Use voice_memo.read_audio to pull the .m4a bytes for
        agent-side transcription.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "since":  .object(["type": .string("string")]),
                "before": .object(["type": .string("string")]),
                "limit":  .object(["type": .string("integer")]),
            ]),
            "additionalProperties": .bool(false),
        ])
    )
    let store: VoiceMemoStore

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        let since = arguments?["since"]?.stringValue
        let before = arguments?["before"]?.stringValue
        let limit = max(1, min(500, arguments?["limit"]?.intValue ?? 50))
        let result = try await store.listRecordings(sinceISO: since, beforeISO: before, limit: limit)
        return voiceMemoJSON(result)
    }
}

// MARK: - voice_memo.get_recording

struct VoiceMemoGetTool: ToolHandler {
    let name = "voice_memo.get_recording"
    let returnsUntrustedContent = true
    let spec = Tool(
        name: "voice_memo.get_recording",
        description: """
        Fetch full metadata for one recording by id (ZUNIQUEID UUID from
        list_recordings). Returns same fields as list, plus absolute_path,
        folder_uuid, and the auto-generated label.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
            "additionalProperties": .bool(false),
        ])
    )
    let store: VoiceMemoStore

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let id = arguments?["id"]?.stringValue else {
            return voiceMemoErrorResult("id is required")
        }
        let detail = try await store.getRecording(id: id)
        return voiceMemoJSON(detail)
    }
}

// MARK: - voice_memo.read_audio

struct VoiceMemoReadAudioTool: ToolHandler {
    let name = "voice_memo.read_audio"
    let spec = Tool(
        name: "voice_memo.read_audio",
        description: """
        Read a recording's .m4a audio as base64. Default cap 5 MiB, hard max
        25 MiB; if total_bytes > bytes_read, the response carries
        truncated=true and you can re-call with a larger max_bytes.

        Will fail with a clear error if the file is an iCloud placeholder
        (not yet downloaded). To trigger download, ask the user to open
        the recording in Voice Memos.app once, or hit it via drive.materialize
        if you have its absolute path.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id":        .object(["type": .string("string")]),
                "max_bytes": .object(["type": .string("integer"), "description": .string("1..26214400. Defaults to 5 MiB.")]),
            ]),
            "required": .array([.string("id")]),
            "additionalProperties": .bool(false),
        ])
    )
    let store: VoiceMemoStore

    static let defaultMaxBytes: Int = 5 * 1024 * 1024
    static let absoluteMaxBytes: Int = 25 * 1024 * 1024

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let id = arguments?["id"]?.stringValue else {
            return voiceMemoErrorResult("id is required")
        }
        let maxBytes = max(1, min(Self.absoluteMaxBytes, arguments?["max_bytes"]?.intValue ?? Self.defaultMaxBytes))

        let detail = try await store.getRecording(id: id)
        guard detail.hasLocalFile else {
            return voiceMemoErrorResult("Audio file not local for recording '\(id)'. It may be an iCloud placeholder; open the recording in Voice Memos.app to trigger download.")
        }
        let url = try await store.audioURL(forRecordingID: id)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let total = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let toRead = Int(min(Int64(maxBytes), total))

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: toRead) ?? Data()

        return voiceMemoJSON(VoiceMemoAudio(
            id: id,
            filename: detail.filename,
            mime: "audio/mp4",
            encoding: "base64",
            bytesRead: Int64(data.count),
            totalBytes: total,
            truncated: Int64(toRead) < total,
            content: data.base64EncodedString()
        ))
    }
}

// MARK: - JSON helpers

func voiceMemoJSON<T: Encodable>(_ value: T) -> CallTool.Result {
    do {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let data = try enc.encode(value)
        let s = String(data: data, encoding: .utf8) ?? "{}"
        return CallTool.Result(content: [.text(text: s, annotations: nil, _meta: nil)], isError: false)
    } catch {
        return voiceMemoErrorResult("encode failed: \(error)")
    }
}

func voiceMemoErrorResult(_ message: String) -> CallTool.Result {
    CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
}
