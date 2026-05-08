import ArgumentParser
import Foundation
import BridgeConfig

private let launchAgentLabel = BridgePaths.bundleID
private let legacyLaunchAgentLabel = BridgePaths.legacyBundleID

private var launchAgentsDir: URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
}

private var launchAgentPlistURL: URL {
    launchAgentsDir.appendingPathComponent("\(launchAgentLabel).plist")
}

private var legacyLaunchAgentPlistURL: URL {
    launchAgentsDir.appendingPathComponent("\(legacyLaunchAgentLabel).plist")
}

struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install the LaunchAgent so the bridge runs at login.",
        discussion: """
        Writes ~/Library/LaunchAgents/\(launchAgentLabel).plist pointing at the
        currently running binary, then `launchctl bootstrap`s it into the user's
        gui session. Re-run after moving or rebuilding the binary.
        """
    )

    @Option(name: .long, help: "Override path to the deckard binary.")
    var binary: String?

    @Flag(name: .long, help: "Replace an existing LaunchAgent if present.")
    var force: Bool = false

    func run() async throws {
        let binaryPath = try resolveBinaryPath(override: binary)
        try BridgePaths.ensureDirs()
        try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

        let target = "gui/\(getuid())"

        // Migrate any pre-rename install: bootout the legacy LaunchAgent and
        // remove its plist before laying down the new one. Without this the
        // old daemon stays loaded under the old label, fights the new one
        // over port 8787, and the user gets a confusing stack of audit rows
        // attributed to the old binary path. Idempotent — silent no-op when
        // there's no legacy install.
        if FileManager.default.fileExists(atPath: legacyLaunchAgentPlistURL.path) {
            print("Detected legacy LaunchAgent (\(legacyLaunchAgentLabel)); removing.")
            _ = runLaunchctl(["bootout", "\(target)/\(legacyLaunchAgentLabel)"])
            try? FileManager.default.removeItem(at: legacyLaunchAgentPlistURL)
        }

        let plistURL = launchAgentPlistURL
        if FileManager.default.fileExists(atPath: plistURL.path) && !force {
            print("LaunchAgent plist already exists at \(plistURL.path).")
            print("Use --force to overwrite.")
            throw ExitCode(1)
        }

        try renderPlist(to: plistURL, binary: binaryPath, logDir: BridgePaths.logsDir.path)
        print("Wrote \(plistURL.path)")

        // Boot out any existing instance under the new label, then bootstrap.
        _ = runLaunchctl(["bootout", "\(target)/\(launchAgentLabel)"])
        let result = runLaunchctl(["bootstrap", target, plistURL.path])
        guard result.exitCode == 0 else {
            print("launchctl bootstrap failed (exit \(result.exitCode)): \(result.output)")
            throw ExitCode(2)
        }
        print("LaunchAgent loaded as \(launchAgentLabel) in \(target).")
        print("Tail logs: tail -f \(BridgePaths.logsDir.path)/stderr.log")
    }
}

struct Uninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Stop and remove the LaunchAgent."
    )

    func run() async throws {
        let target = "gui/\(getuid())"

        // Tear down both labels — covers a partial migration where someone
        // runs `uninstall` between `deckard install`'s legacy-cleanup step
        // and a fresh install would otherwise re-bootstrap the new one.
        for label in [launchAgentLabel, legacyLaunchAgentLabel] {
            let result = runLaunchctl(["bootout", "\(target)/\(label)"])
            if result.exitCode != 0, !result.output.contains("Could not find") {
                print("launchctl bootout \(label) returned \(result.exitCode): \(result.output)")
            }
        }

        for url in [launchAgentPlistURL, legacyLaunchAgentPlistURL] {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                print("Removed \(url.path)")
            }
        }
    }
}

// MARK: - Helpers

private func resolveBinaryPath(override: String?) throws -> String {
    if let override {
        return URL(fileURLWithPath: override).standardizedFileURL.path
    }
    // Use the running executable's path so `install` always wires up the binary
    // that was just invoked. Resolve symlinks so launchd doesn't follow stale paths.
    let argv0 = CommandLine.arguments.first ?? "deckard"
    let url: URL
    if argv0.contains("/") {
        url = URL(fileURLWithPath: argv0)
    } else {
        url = URL(fileURLWithPath: ProcessInfo.processInfo.arguments.first ?? argv0)
    }
    return url.resolvingSymlinksInPath().path
}

private func renderPlist(to url: URL, binary: String, logDir: String) throws {
    // Locate the template — try alongside the binary, then the dev path.
    let templateName = "\(launchAgentLabel).plist.template"
    let candidates = [
        URL(fileURLWithPath: binary).deletingLastPathComponent().appendingPathComponent("Resources/\(templateName)"),
        URL(fileURLWithPath: binary).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/\(templateName)"),
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/\(templateName)"),
    ]
    var template: String?
    for c in candidates {
        if let t = try? String(contentsOf: c, encoding: .utf8) {
            template = t
            break
        }
    }
    let body = template ?? embeddedPlistTemplate

    let rendered = body
        .replacingOccurrences(of: "__LABEL__", with: launchAgentLabel)
        .replacingOccurrences(of: "__BINARY__", with: binary)
        .replacingOccurrences(of: "__LOG_DIR__", with: logDir)
    try rendered.write(to: url, atomically: true, encoding: .utf8)
}

/// Fallback used when the on-disk template can't be found (e.g. running the
/// binary out of Homebrew's bin where Resources/ isn't shipped).
private let embeddedPlistTemplate = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>__LABEL__</string>
    <key>ProgramArguments</key>
    <array>
        <string>__BINARY__</string>
        <string>serve</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>Crashed</key>
        <true/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>__LOG_DIR__/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>__LOG_DIR__/stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
"""

private struct LaunchctlResult {
    let exitCode: Int32
    let output: String
}

private func runLaunchctl(_ arguments: [String]) -> LaunchctlResult {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    proc.arguments = arguments
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    do {
        try proc.run()
        proc.waitUntilExit()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        let out = String(data: data, encoding: .utf8) ?? ""
        return LaunchctlResult(exitCode: proc.terminationStatus, output: out)
    } catch {
        return LaunchctlResult(exitCode: -1, output: "\(error)")
    }
}
