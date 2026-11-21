import Foundation
import Darwin

/// Bounded subprocess capture. Private files avoid pipe-capacity deadlocks:
/// waiting for a child to exit before draining its stdout can otherwise stall
/// forever. Files are removed on success, error, timeout and cancellation.
public enum Subprocess {
    public struct Output: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
    }
    public enum Failure: Error { case timeout, outputLimit }

    public static func run(_ executable: String, arguments: [String] = [], input: Data = Data(),
                           timeoutSeconds: Double = 15, maxOutputBytes: Int = 16 * 1024 * 1024) async throws -> Output {
        try Task.checkCancellation()
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("deckard-process-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        let stdinURL = dir.appendingPathComponent("stdin")
        let stdoutURL = dir.appendingPathComponent("stdout")
        let stderrURL = dir.appendingPathComponent("stderr")
        try PrivateFile.write(input, to: stdinURL)
        try PrivateFile.write(Data(), to: stdoutURL)
        try PrivateFile.write(Data(), to: stderrURL)
        let stdin = try FileHandle(forReadingFrom: stdinURL)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr
        let exitLatch = ExitLatch()
        proc.terminationHandler = { _ in exitLatch.signal() }
        try proc.run()
        defer {
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            proc.waitUntilExit()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, timeoutSeconds)))
        func outputSize() throws -> Int {
            let out = try fm.attributesOfItem(atPath: stdoutURL.path)[.size] as? NSNumber
            let err = try fm.attributesOfItem(atPath: stderrURL.path)[.size] as? NSNumber
            return (out?.intValue ?? 0) + (err?.intValue ?? 0)
        }
        // Wake on exit immediately instead of polling every 25 ms (which added
        // ~12 ms to every osascript call). The tick only bounds how often the
        // deadline and output size are re-checked while the child runs.
        while proc.isRunning {
            try Task.checkCancellation()
            let now = ContinuousClock.now
            guard now < deadline else { throw Failure.timeout }
            guard try outputSize() <= maxOutputBytes else { throw Failure.outputLimit }
            let tick = min(Duration.milliseconds(100), deadline - now)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await exitLatch.wait() }
                group.addTask { try? await Task.sleep(for: tick) }
                await group.next()
                group.cancelAll()
            }
        }
        guard try outputSize() <= maxOutputBytes else { throw Failure.outputLimit }
        return Output(exitCode: proc.terminationStatus,
                      stdout: try String(contentsOf: stdoutURL, encoding: .utf8),
                      stderr: try String(contentsOf: stderrURL, encoding: .utf8))
    }
}

/// One-shot signal set from `Process.terminationHandler`. `wait()` returns
/// when the process has exited or the waiting task is cancelled.
final class ExitLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func signal() {
        lock.lock()
        exited = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in pending.values { continuation.resume() }
    }

    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                // Covers both orderings: exit (or cancellation) may already
                // have happened before this continuation was registered.
                if exited || Task.isCancelled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters[id] = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let continuation = waiters.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume()
        }
    }
}
