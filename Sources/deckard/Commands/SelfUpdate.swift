import ArgumentParser
import CryptoKit
import Foundation
import BridgeConfig
import BridgeCore

/// Compiled-in invariant: every release tarball produced by the project's
/// release.yml is signed by this Apple Developer team. A tarball whose
/// embedded codesign output reports a different TeamIdentifier is treated
/// as hostile and refused, regardless of whether its notarization ticket
/// otherwise validates — Apple notarizes every Developer ID submission,
/// so notarization alone is necessary but not sufficient.
private let expectedTeamID = "NZL3HS8AH4"

private let githubAPI = "https://api.github.com/repos/lapidakis/Deckard/releases"

struct SelfUpdate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "self-update",
        abstract: "Check for and apply daemon updates from GitHub Releases.",
        discussion: """
        By default, prints whether an update is available and exits without
        applying anything. Pass --apply to download + verify + swap the
        binary and kickstart the LaunchAgent.

        Verification chain before swap:
          1. SHA-256 of tarball matches the .sha256 sidecar
          2. codesign --verify --strict on the extracted binary
          3. TeamIdentifier matches \(expectedTeamID)
          4. spctl --assess --type execute (Gatekeeper / notarization)

        Any check fails: leaves the existing binary in place.

        --channel defaults to 'beta' when running a pre-release version
        (1.0.0-beta.1, etc.) and 'stable' otherwise — so beta users see
        beta updates and stable users don't get pre-releases unless they
        opt in explicitly.
        """
    )

    @Flag(name: .long, help: "Exit code only: 0 up-to-date, 2 update available, 3 check failed.")
    var check: Bool = false

    @Flag(name: .long, help: "Download, verify, and apply the update after a y/N prompt.")
    var apply: Bool = false

    @Flag(name: .long, help: "Apply without prompting. Implies --apply.")
    var autoApply: Bool = false

    @Option(name: .long, help: "Release channel: 'stable' or 'beta'.")
    var channel: String?

    func run() async throws {
        let current = BridgeCore.version
        let resolvedChannel = channel ?? (current.contains("-") ? "beta" : "stable")
        guard ["stable", "beta"].contains(resolvedChannel) else {
            print("error: --channel must be 'stable' or 'beta'")
            throw ExitCode(2)
        }

        // Fetch latest matching release.
        let release: ReleaseMeta
        do {
            release = try await fetchLatest(channel: resolvedChannel)
        } catch {
            FileHandle.standardError.write(Data("self-update check failed: \(error)\n".utf8))
            throw ExitCode(3)
        }

        let latest = release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag

        switch compareVersions(current: current, latest: latest) {
        case .upToDate, .ahead:
            print("Up to date (current: \(current), latest \(resolvedChannel): \(latest))")
            if check { throw ExitCode.success }
            return
        case .behind:
            print("Update available: \(current) → \(latest)")
            if !release.htmlURL.isEmpty {
                print("Release notes: \(release.htmlURL)")
            }
            if check { throw ExitCode(2) }
        }

        let shouldApply = apply || autoApply
        guard shouldApply else {
            print("")
            print("To install: deckard self-update --apply")
            return
        }

        if !autoApply {
            print("")
            print("Apply update \(current) → \(latest)? [y/N] ", terminator: "")
            guard let line = readLine(), line.lowercased().hasPrefix("y") else {
                print("Aborted.")
                throw ExitCode(1)
            }
        }

        try await applyUpdate(release: release, latest: latest)
    }
}

// MARK: - GitHub Releases API

private struct ReleaseMeta: Decodable {
    let tag: String
    let prerelease: Bool
    let htmlURL: String
    let assets: [ReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name"
        case prerelease
        case htmlURL = "html_url"
        case assets
    }
}

private struct ReleaseAsset: Decodable {
    let name: String
    let downloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
    }
}

private func fetchLatest(channel: String) async throws -> ReleaseMeta {
    // 'stable' uses /releases/latest, which Apple's docs describe as the most
    // recent non-prerelease, non-draft. 'beta' walks the full /releases page
    // and picks the newest entry — pre-releases included — so beta users
    // still see updates even when no stable has shipped between betas.
    let url: URL
    if channel == "stable" {
        url = URL(string: "\(githubAPI)/latest")!
    } else {
        url = URL(string: githubAPI)!
    }

    var req = URLRequest(url: url)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("deckard/\(BridgeCore.version)", forHTTPHeaderField: "User-Agent")

    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse else {
        throw RuntimeError("GitHub API: no HTTP response (network down?)")
    }
    switch http.statusCode {
    case 200:
        break
    case 404:
        // /releases/latest returns 404 when no non-prerelease has been
        // published. /releases returns 404 when the repo doesn't exist or
        // is private. Distinguish by URL so the user knows whether to wait
        // for a release or check their network / repo URL.
        if channel == "stable" {
            throw RuntimeError("no published 'stable' release yet. Try `--channel beta` if you're tracking pre-releases.")
        } else {
            throw RuntimeError("no releases found at \(githubAPI). The repo may be private, the URL may be wrong, or no releases have been published.")
        }
    case 403:
        throw RuntimeError("GitHub API rate-limited (HTTP 403). Wait a few minutes and retry.")
    default:
        throw RuntimeError("GitHub API returned HTTP \(http.statusCode)")
    }

    let decoder = JSONDecoder()
    if channel == "stable" {
        return try decoder.decode(ReleaseMeta.self, from: data)
    } else {
        let all = try decoder.decode([ReleaseMeta].self, from: data)
        guard let first = all.first else {
            throw RuntimeError("no releases found")
        }
        return first
    }
}

// MARK: - Version comparison

private enum VersionComparison { case upToDate, ahead, behind }

private func compareVersions(current: String, latest: String) -> VersionComparison {
    if current == latest { return .upToDate }
    let currentParts = parseVersion(current)
    let latestParts = parseVersion(latest)

    // Compare numeric prefix first (major.minor.patch).
    for (a, b) in zip(currentParts.numbers, latestParts.numbers) {
        if a != b { return a < b ? .behind : .ahead }
    }
    if currentParts.numbers.count != latestParts.numbers.count {
        return currentParts.numbers.count < latestParts.numbers.count ? .behind : .ahead
    }

    // Same numeric prefix: pre-release identifiers come BEFORE the final
    // release per semver §11. So "1.0.0" > "1.0.0-beta.1".
    switch (currentParts.prerelease, latestParts.prerelease) {
    case (nil, nil): return .upToDate
    case (nil, _?):  return .ahead   // current is final, latest is pre — we're ahead
    case (_?, nil):  return .behind  // current is pre, latest is final — behind
    case let (a?, b?):
        if a == b { return .upToDate }
        return a < b ? .behind : .ahead
    }
}

private func parseVersion(_ v: String) -> (numbers: [Int], prerelease: String?) {
    let split = v.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    let numericPart = String(split[0])
    let pre = split.count > 1 ? String(split[1]) : nil
    let numbers = numericPart.split(separator: ".").compactMap { Int($0) }
    return (numbers, pre)
}

// MARK: - Apply

private func applyUpdate(release: ReleaseMeta, latest: String) async throws {
    let arch = currentArch()
    guard let tarballAsset = release.assets.first(where: { $0.name.hasSuffix("-\(arch).tar.gz") }) else {
        FileHandle.standardError.write(Data("error: release \(release.tag) has no \(arch) tarball asset\n".utf8))
        throw ExitCode(3)
    }
    guard let shaAsset = release.assets.first(where: { $0.name == "\(tarballAsset.name).sha256" }) else {
        FileHandle.standardError.write(Data("error: release \(release.tag) has no SHA-256 sidecar for \(tarballAsset.name)\n".utf8))
        throw ExitCode(3)
    }

    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("deckard-update-\(latest)-\(getpid())")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    // Best-effort cleanup; if a verification step throws, leaving the temp
    // dir behind is fine — the system will reap /tmp on reboot.
    defer { try? FileManager.default.removeItem(at: tmp) }

    print("Downloading \(tarballAsset.name)…")
    let tarball = tmp.appendingPathComponent(tarballAsset.name)
    try await download(url: tarballAsset.downloadURL, to: tarball)

    let shaFile = tmp.appendingPathComponent(shaAsset.name)
    try await download(url: shaAsset.downloadURL, to: shaFile)

    print("Verifying SHA-256…")
    try verifySHA(tarball: tarball, sidecar: shaFile)

    print("Extracting…")
    let extracted = tmp.appendingPathComponent("extracted")
    try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
    try runExternal(["/usr/bin/tar", "-xzf", tarball.path, "-C", extracted.path])

    let newBinary = extracted.appendingPathComponent("deckard")
    guard FileManager.default.fileExists(atPath: newBinary.path) else {
        throw RuntimeError("extracted tarball is missing 'deckard'")
    }

    print("Verifying codesign…")
    try verifyCodesign(binary: newBinary)

    print("Verifying notarization…")
    try verifyNotarization(binary: newBinary)

    let currentBinary = try resolveCurrentBinary()
    if currentBinary.path.contains("/.build/") {
        // Refuse to overwrite a build-tree binary. Almost certainly a
        // developer testing self-update against a debug build — silently
        // replacing the SwiftPM artifact would surprise them.
        throw RuntimeError("refusing to swap binary inside .build/ (\(currentBinary.path)). Run from an installed location.")
    }

    print("Swapping \(currentBinary.path)…")
    try atomicSwap(new: newBinary, target: currentBinary)

    print("Kickstarting LaunchAgent…")
    kickstartDaemon()

    print("Updated to \(latest).")
}

// MARK: - Helpers

private func currentArch() -> String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
}

private func download(url urlString: String, to destination: URL) async throws {
    guard let url = URL(string: urlString) else {
        throw RuntimeError("invalid asset URL: \(urlString)")
    }
    var req = URLRequest(url: url)
    req.setValue("deckard/\(BridgeCore.version)", forHTTPHeaderField: "User-Agent")
    let (tmpFile, response) = try await URLSession.shared.download(for: req)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw RuntimeError("download returned non-200 (\(((response as? HTTPURLResponse)?.statusCode).map(String.init) ?? "?")) for \(urlString)")
    }
    if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: tmpFile, to: destination)
}

private func verifySHA(tarball: URL, sidecar: URL) throws {
    // Sidecar format: "<hex>  <filename>\n" (shasum -a 256).
    let sidecarContents = try String(contentsOf: sidecar, encoding: .utf8)
    let expectedHex = sidecarContents
        .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        .first
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard let expected = expectedHex, expected.count == 64 else {
        throw RuntimeError("malformed SHA-256 sidecar: \(sidecarContents)")
    }
    let data = try Data(contentsOf: tarball)
    let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard actual.lowercased() == expected.lowercased() else {
        throw RuntimeError("SHA-256 mismatch (expected \(expected), got \(actual))")
    }
}

private func verifyCodesign(binary: URL) throws {
    let strict = runExternalCapturing(["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", binary.path])
    guard strict.exitCode == 0 else {
        throw RuntimeError("codesign --verify failed (\(strict.exitCode)): \(strict.combined)")
    }
    let info = runExternalCapturing(["/usr/bin/codesign", "-dv", binary.path])
    guard info.combined.contains("TeamIdentifier=\(expectedTeamID)") else {
        throw RuntimeError("TeamIdentifier mismatch (expected \(expectedTeamID)). codesign output: \(info.combined)")
    }
}

private func verifyNotarization(binary: URL) throws {
    let result = runExternalCapturing(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", binary.path])
    guard result.exitCode == 0 else {
        throw RuntimeError("spctl --assess failed (\(result.exitCode)): \(result.combined). Binary is not notarized; refusing to apply.")
    }
}

private func resolveCurrentBinary() throws -> URL {
    if let path = Bundle.main.executablePath {
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }
    // Fallback: argv0 resolution, mirroring what `deckard install` does.
    let argv0 = CommandLine.arguments.first ?? "deckard"
    return URL(fileURLWithPath: argv0).resolvingSymlinksInPath()
}

private func atomicSwap(new: URL, target: URL) throws {
    // POSIX rename(2) is atomic within a single filesystem. Both temp paths
    // must be siblings of `target` so we don't accidentally cross a mount
    // boundary (e.g. /tmp on a separate volume than /usr/local/bin).
    let dir = target.deletingLastPathComponent()
    let staged = dir.appendingPathComponent(".\(target.lastPathComponent).new")
    let backup = dir.appendingPathComponent(".\(target.lastPathComponent).old")

    if FileManager.default.fileExists(atPath: staged.path) {
        try FileManager.default.removeItem(at: staged)
    }
    if FileManager.default.fileExists(atPath: backup.path) {
        try FileManager.default.removeItem(at: backup)
    }

    try FileManager.default.copyItem(at: new, to: staged)
    // Preserve executable bit explicitly — the in-tree binary may have had
    // attributes that copyItem didn't propagate on every macOS version.
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)

    if FileManager.default.fileExists(atPath: target.path) {
        try FileManager.default.moveItem(at: target, to: backup)
    }
    do {
        try FileManager.default.moveItem(at: staged, to: target)
    } catch {
        // Restore on failure so we don't leave the user binary-less.
        try? FileManager.default.moveItem(at: backup, to: target)
        throw error
    }
    try? FileManager.default.removeItem(at: backup)
}

private func kickstartDaemon() {
    let label = BridgePaths.bundleID
    let target = "gui/\(getuid())/\(label)"
    // `kickstart -k` SIGTERMs the running daemon and respawns it from the
    // (now updated) binary path. If the LaunchAgent isn't loaded, this
    // fails with "Could not find specified service" — non-fatal; the user
    // probably just runs `deckard install` after first install.
    let result = runExternalCapturing(["/bin/launchctl", "kickstart", "-k", target])
    if result.exitCode != 0 {
        FileHandle.standardError.write(Data("warning: launchctl kickstart \(target) returned \(result.exitCode): \(result.combined)\n".utf8))
        FileHandle.standardError.write(Data("(if the daemon isn't installed yet, run: deckard install)\n".utf8))
    }
}

private struct ExternalResult {
    let exitCode: Int32
    let combined: String
}

private func runExternal(_ argv: [String]) throws {
    let r = runExternalCapturing(argv)
    guard r.exitCode == 0 else {
        throw RuntimeError("\(argv.joined(separator: " ")) exited \(r.exitCode): \(r.combined)")
    }
}

private func runExternalCapturing(_ argv: [String]) -> ExternalResult {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: argv[0])
    proc.arguments = Array(argv.dropFirst())
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    do {
        try proc.run()
        proc.waitUntilExit()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        let out = String(data: data, encoding: .utf8) ?? ""
        return ExternalResult(exitCode: proc.terminationStatus, combined: out.trimmingCharacters(in: .whitespacesAndNewlines))
    } catch {
        return ExternalResult(exitCode: -1, combined: "\(error)")
    }
}

private struct RuntimeError: Error, CustomStringConvertible {
    let description: String
    init(_ msg: String) { self.description = msg }
}
