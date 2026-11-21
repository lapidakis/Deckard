import Testing
import Foundation
@testable import ServiceDrive

private let pathFixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

private func resolvePath(_ value: String) throws -> DrivePath {
    try DrivePath.resolve(value, root: pathFixtureRoot)
}

@Test func drivePathEmptyResolvesToRoot() throws {
    let dp = try resolvePath("")
    #expect(dp.relativePath == "")
    #expect(dp.url.path == pathFixtureRoot.standardizedFileURL.path)
}

@Test func drivePathDotResolvesToRoot() throws {
    let dp = try resolvePath(".")
    #expect(dp.relativePath == "")
}

@Test func drivePathSimpleRelative() throws {
    let dp = try resolvePath("Documents/foo.txt")
    #expect(dp.relativePath == "Documents/foo.txt")
}

@Test func drivePathRejectsAbsolute() {
    do {
        _ = try resolvePath("/etc/passwd")
        Issue.record("expected throw")
    } catch DrivePath.DrivePathError.absolutePathRejected {
        // ok
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func drivePathRejectsTraversal() {
    do {
        _ = try resolvePath("../../../etc/passwd")
        Issue.record("expected throw")
    } catch DrivePath.DrivePathError.traversal {
        // ok
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func drivePathRejectsLeadingDotDot() {
    do {
        _ = try resolvePath("../sibling")
        Issue.record("expected throw")
    } catch DrivePath.DrivePathError.traversal {
        // ok
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func drivePathInternalDotDotStaysSafe() throws {
    // "Documents/../Documents/foo" canonicalizes back into the root.
    let dp = try resolvePath("Documents/../Documents/foo.txt")
    #expect(dp.relativePath == "Documents/foo.txt")
}

@Test func drivePathTrailingDotDotResolvesToRoot() throws {
    let dp = try resolvePath("Documents/..")
    #expect(dp.relativePath == "")
}
