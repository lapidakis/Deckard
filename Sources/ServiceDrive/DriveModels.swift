import Foundation

public struct DriveItem: Codable, Sendable, Hashable {
    public let path: String          // relative to iCloud root
    public let name: String
    public let type: String          // "file" | "directory" | "symlink" | "other"
    public let size: Int64?          // bytes; nil for directories
    public let modified: String?     // ISO 8601
    public let isPlaceholder: Bool   // .icloud stub awaiting download

    public init(
        path: String, name: String, type: String,
        size: Int64?, modified: String?, isPlaceholder: Bool
    ) {
        self.path = path
        self.name = name
        self.type = type
        self.size = size
        self.modified = modified
        self.isPlaceholder = isPlaceholder
    }

    enum CodingKeys: String, CodingKey {
        case path, name, type, size, modified
        case isPlaceholder = "is_placeholder"
    }
}

public struct DriveStat: Codable, Sendable {
    public let path: String
    public let name: String
    public let type: String
    public let size: Int64?
    public let modified: String?
    public let created: String?
    public let isPlaceholder: Bool
    public let utiType: String?      // "public.text", "com.adobe.pdf", etc.

    public init(
        path: String, name: String, type: String,
        size: Int64?, modified: String?, created: String?,
        isPlaceholder: Bool, utiType: String?
    ) {
        self.path = path
        self.name = name
        self.type = type
        self.size = size
        self.modified = modified
        self.created = created
        self.isPlaceholder = isPlaceholder
        self.utiType = utiType
    }

    enum CodingKeys: String, CodingKey {
        case path, name, type, size, modified, created
        case isPlaceholder = "is_placeholder"
        case utiType = "uti_type"
    }
}

public struct DriveContent: Codable, Sendable {
    public let path: String
    public let encoding: String      // "utf-8" | "base64"
    public let content: String
    public let truncated: Bool       // true if `total_bytes` > what was returned
    public let bytesRead: Int64
    public let totalBytes: Int64

    public init(
        path: String, encoding: String, content: String,
        truncated: Bool, bytesRead: Int64, totalBytes: Int64
    ) {
        self.path = path
        self.encoding = encoding
        self.content = content
        self.truncated = truncated
        self.bytesRead = bytesRead
        self.totalBytes = totalBytes
    }

    enum CodingKeys: String, CodingKey {
        case path, encoding, content, truncated
        case bytesRead = "bytes_read"
        case totalBytes = "total_bytes"
    }
}

/// Disk usage for the volume backing iCloud Drive. Note: this is the local
/// macOS filesystem's free/used space, not the user's iCloud account quota
/// (which is exposed via separate Apple APIs we haven't wired up). Usable as
/// a "is the agent about to fill the disk before writing" sanity check.
public struct DriveUsage: Codable, Sendable {
    public let totalBytes: Int64
    public let availableBytes: Int64
    public let usedBytes: Int64
    /// What the numbers describe — set to "local_volume" to make the caveat
    /// explicit in the response itself.
    public let scope: String

    public init(totalBytes: Int64, availableBytes: Int64, usedBytes: Int64, scope: String = "local_volume") {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.usedBytes = usedBytes
        self.scope = scope
    }

    enum CodingKeys: String, CodingKey {
        case totalBytes = "total_bytes"
        case availableBytes = "available_bytes"
        case usedBytes = "used_bytes"
        case scope
    }
}
