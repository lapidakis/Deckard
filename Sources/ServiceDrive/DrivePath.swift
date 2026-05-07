import Foundation

/// Path resolution + traversal guard for the iCloud Drive surface.
///
/// Any caller-supplied relative path is anchored at the iCloud Drive root and
/// canonicalized; the result is rejected if it escapes the root via `..`,
/// absolute paths, or symlink resolution. Every adapter call MUST pass through
/// `DrivePath.resolve(...)` — never construct file URLs directly from caller input.
public struct DrivePath: Sendable, Equatable {
    /// Absolute file URL safe to read/write.
    public let url: URL
    /// Pretty path for display, e.g. `"Documents/foo.txt"`. Always
    /// forward-slashed and with no leading slash.
    public let relativePath: String

    /// Root: `~/Library/Mobile Documents/com~apple~CloudDocs`
    public static var iCloudRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    public enum DrivePathError: Error, CustomStringConvertible {
        case rootNotFound
        case absolutePathRejected
        case traversal(String)
        case empty

        public var description: String {
            switch self {
            case .rootNotFound:
                return "iCloud Drive root not found at \(DrivePath.iCloudRoot.path). Sign in to iCloud and ensure Drive is enabled."
            case .absolutePathRejected:
                return "Absolute paths are not allowed. Use a path relative to the iCloud Drive root."
            case .traversal(let p):
                return "Path '\(p)' resolves outside the iCloud Drive root and was rejected."
            case .empty:
                return "Path cannot be empty."
            }
        }
    }

    /// Resolve a caller-supplied relative path. Empty / "." / "/" all map to the root itself.
    public static func resolve(_ relative: String) throws -> DrivePath {
        let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned: String
        if trimmed.isEmpty || trimmed == "." || trimmed == "/" {
            cleaned = ""
        } else if trimmed.hasPrefix("/") {
            throw DrivePathError.absolutePathRejected
        } else {
            cleaned = trimmed
        }

        // Component-walk canonicalization. Explicit and version-safe; we don't
        // rely on NSString.standardizingPath or URL.standardizedFileURL behavior
        // (both have edge cases that vary across macOS releases).
        var stack: [String] = []
        for raw in cleaned.split(separator: "/", omittingEmptySubsequences: true) {
            let comp = String(raw)
            if comp == "." { continue }
            if comp == ".." {
                guard !stack.isEmpty else {
                    throw DrivePathError.traversal(relative)
                }
                stack.removeLast()
                continue
            }
            stack.append(comp)
        }
        let canonicalRel = stack.joined(separator: "/")

        let root = iCloudRoot
        let rootPath = root.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: rootPath) else {
            throw DrivePathError.rootNotFound
        }

        let targetPath: String
        let targetURL: URL
        if canonicalRel.isEmpty {
            targetPath = rootPath
            targetURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        } else {
            targetPath = rootPath + "/" + canonicalRel
            targetURL = URL(fileURLWithPath: targetPath)
        }

        // Symlink defense: if the target exists, verify the link-resolved path
        // is also under root. Non-existent targets (fresh writes) skip this —
        // the parent dir will be checked at write time.
        if FileManager.default.fileExists(atPath: targetPath) {
            let canonicalRoot = (rootPath as NSString).resolvingSymlinksInPath
            let canonicalTarget = (targetPath as NSString).resolvingSymlinksInPath
            guard canonicalTarget == canonicalRoot
                || canonicalTarget.hasPrefix(canonicalRoot + "/")
            else {
                throw DrivePathError.traversal(relative)
            }
        }

        return DrivePath(url: targetURL, relativePath: canonicalRel)
    }
}
