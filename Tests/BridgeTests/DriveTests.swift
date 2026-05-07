import Testing
import Foundation
@testable import ServiceDrive

@Test func drivePathEmptyResolvesToRoot() throws {
    let dp = try DrivePath.resolve("")
    #expect(dp.relativePath == "")
    #expect(dp.url.path == DrivePath.iCloudRoot.standardizedFileURL.path)
}

@Test func drivePathDotResolvesToRoot() throws {
    let dp = try DrivePath.resolve(".")
    #expect(dp.relativePath == "")
}

@Test func drivePathSimpleRelative() throws {
    let dp = try DrivePath.resolve("Documents/foo.txt")
    #expect(dp.relativePath == "Documents/foo.txt")
}

@Test func drivePathRejectsAbsolute() {
    do {
        _ = try DrivePath.resolve("/etc/passwd")
        Issue.record("expected throw")
    } catch DrivePath.DrivePathError.absolutePathRejected {
        // ok
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func drivePathRejectsTraversal() {
    do {
        _ = try DrivePath.resolve("../../../etc/passwd")
        Issue.record("expected throw")
    } catch DrivePath.DrivePathError.traversal {
        // ok
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func drivePathRejectsLeadingDotDot() {
    do {
        _ = try DrivePath.resolve("../sibling")
        Issue.record("expected throw")
    } catch DrivePath.DrivePathError.traversal {
        // ok
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func drivePathInternalDotDotStaysSafe() throws {
    // "Documents/../Documents/foo" canonicalizes back into the root.
    let dp = try DrivePath.resolve("Documents/../Documents/foo.txt")
    #expect(dp.relativePath == "Documents/foo.txt")
}

@Test func drivePathTrailingDotDotResolvesToRoot() throws {
    let dp = try DrivePath.resolve("Documents/..")
    #expect(dp.relativePath == "")
}

// Note: full DriveAdapter tests would require an iCloud root + sandbox
// fixtures we don't have in CI. The sandbox check is structurally a string
// prefix match, so we exercise it via the same prefix logic without writing
// to disk. Anything beyond prefix matching is verified live during phase
// rollout (audit log + manual repro).

@Test func driveSandboxAllowsWhenEmpty() {
    // No prefixes configured → any path is allowed.
    let prefixes: [String] = []
    #expect(isUnderAllowedPrefix(path: "Documents/foo.txt", prefixes: prefixes))
    #expect(isUnderAllowedPrefix(path: "agent-drafts/bar", prefixes: prefixes))
}

@Test func driveSandboxAllowsExactAndChildren() {
    let prefixes = ["agent-drafts"]
    #expect(isUnderAllowedPrefix(path: "agent-drafts", prefixes: prefixes))
    #expect(isUnderAllowedPrefix(path: "agent-drafts/foo.txt", prefixes: prefixes))
    #expect(isUnderAllowedPrefix(path: "agent-drafts/sub/dir/bar", prefixes: prefixes))
}

@Test func driveSandboxRejectsOutside() {
    let prefixes = ["agent-drafts"]
    #expect(!isUnderAllowedPrefix(path: "Documents/foo.txt", prefixes: prefixes))
    #expect(!isUnderAllowedPrefix(path: "agent-draftsX/foo.txt", prefixes: prefixes))   // no false-prefix match
    #expect(!isUnderAllowedPrefix(path: "X-agent-drafts/foo", prefixes: prefixes))
}

@Test func driveSandboxIgnoresTrailingSlash() {
    let prefixes = ["agent-drafts/"]
    #expect(isUnderAllowedPrefix(path: "agent-drafts/foo.txt", prefixes: prefixes))
    #expect(isUnderAllowedPrefix(path: "agent-drafts", prefixes: prefixes))
}

/// Mirror of DriveAdapter's check, callable in tests without instantiating
/// the actor or touching the filesystem.
private func isUnderAllowedPrefix(path: String, prefixes: [String]) -> Bool {
    if prefixes.isEmpty { return true }
    for raw in prefixes {
        let prefix = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if prefix.isEmpty { continue }
        if path == prefix || path.hasPrefix(prefix + "/") { return true }
    }
    return false
}
