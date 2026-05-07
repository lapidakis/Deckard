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
