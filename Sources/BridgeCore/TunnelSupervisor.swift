import Foundation
import Darwin
import Logging
import BridgeConfig

/// Keeps a Cloudflare Tunnel connector (`cloudflared`) running as a child of
/// the daemon for as long as the daemon runs.
///
/// Why a child rather than a second LaunchAgent: the public hostname is only
/// useful while the bridge is up, launchd tears the child down with the job,
/// and there is one thing to install, restart and read logs for.
///
/// A missing binary or config never stops the bridge: the supervisor logs why
/// and returns, and loopback/tailnet access keep working.
public struct TunnelSupervisor: Sendable {
    private let config: CloudflareTunnelConfig
    private let logURL: URL
    private let pidURL: URL
    private let logger: Logger

    public init(config: CloudflareTunnelConfig,
                logURL: URL = BridgePaths.logsDir.appendingPathComponent("cloudflared.log"),
                pidURL: URL = BridgePaths.supportDir.appendingPathComponent("cloudflared.pid"),
                logger: Logger = Logger(label: "bridge.tunnel")) {
        self.config = config
        self.logURL = logURL
        self.pidURL = pidURL
        self.logger = logger
    }

    /// `launchctl kickstart -k` (and a crash) kills the daemon without giving
    /// it a chance to stop its child, and launchd does not reap it, so the old
    /// connector would keep running beside the new one. The connector's pid
    /// is recorded on start; at the next start a survivor is stopped first.
    ///
    /// The pid is only signalled if that process is still running the same
    /// cloudflared binary, so a recycled pid belonging to something else is
    /// never touched.
    func stopLeftoverConnector(binary: String) {
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        defer { try? FileManager.default.removeItem(at: pidURL) }
        guard Self.executablePath(of: pid) == Self.resolved(binary) else { return }
        logger.info("Stopping Cloudflare tunnel connector left by a previous daemon (pid \(pid))")
        kill(pid, SIGTERM)
        for _ in 0..<30 where kill(pid, 0) == 0 { usleep(100_000) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return resolved(String(cString: buffer))
    }

    /// Homebrew's bin entry is a symlink into the Cellar; compare real paths.
    static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Delay before restarting after the connector exits. Doubles from 2s to
    /// a 60s ceiling; a run that lasted over a minute resets it, so a healthy
    /// tunnel that drops once reconnects quickly while a broken config does
    /// not spin.
    static func nextBackoff(after previous: Duration, ranFor: Duration) -> Duration {
        if ranFor > .seconds(60) { return .seconds(2) }
        return min(previous * 2, .seconds(60))
    }

    public func run() async {
        guard let binary = CloudflareSetup.findBinary(override: config.binary) else {
            logger.error("Cloudflare tunnel enabled but cloudflared was not found; install it (`brew install cloudflared`) or set [cloudflare_tunnel] binary. Tunnel not started.")
            return
        }
        let configPath = CloudflareSetup.expand(config.configFile)
        guard FileManager.default.fileExists(atPath: configPath) else {
            logger.error("Cloudflare tunnel enabled but \(configPath) does not exist; run `deckard cloudflare setup`. Tunnel not started.")
            return
        }

        stopLeftoverConnector(binary: binary)
        var backoff: Duration = .seconds(2)
        while !Task.isCancelled {
            let started = ContinuousClock.now
            logger.info("Starting Cloudflare tunnel: \(binary) (log: \(logURL.path))")
            let status = await runOnce(binary: binary, configPath: configPath)
            if Task.isCancelled { break }
            let ranFor = ContinuousClock.now - started
            backoff = Self.nextBackoff(after: backoff, ranFor: ranFor)
            logger.warning("Cloudflare tunnel exited (status \(status)); restarting in \(backoff.components.seconds)s")
            try? await Task.sleep(for: backoff)
        }
    }

    /// Runs cloudflared until it exits or this task is cancelled.
    private func runOnce(binary: String, configPath: String) async -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        // --no-autoupdate: the connector must not replace its own binary
        // underneath a supervisor; updates come from the package manager.
        proc.arguments = ["tunnel", "--config", configPath, "--no-autoupdate", "run"]
        proc.standardInput = FileHandle.nullDevice
        let log = openLog()
        proc.standardOutput = log ?? FileHandle.nullDevice
        proc.standardError = log ?? FileHandle.nullDevice
        defer { try? log?.close() }

        let box = ProcessBox(proc)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
                proc.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
                do {
                    try proc.run()
                    try? PrivateFile.write(Data("\(proc.processIdentifier)\n".utf8), to: pidURL)
                } catch {
                    proc.terminationHandler = nil
                    logger.error("Could not start cloudflared: \(error.localizedDescription)")
                    continuation.resume(returning: -1)
                }
            }
        } onCancel: {
            box.terminate()
        }
    }

    /// Appends to the log, starting it fresh once it passes 5 MB so a
    /// long-lived tunnel cannot fill the disk.
    private func openLog() -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? fm.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber)?.intValue ?? 0
        if size > 5 * 1024 * 1024 || !fm.fileExists(atPath: logURL.path) {
            try? PrivateFile.write(Data(), to: logURL)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }
}

/// `Process` is not Sendable; the cancellation handler only ever calls
/// `terminate()`, which is safe from any thread.
private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() { if process.isRunning { process.terminate() } }
}
