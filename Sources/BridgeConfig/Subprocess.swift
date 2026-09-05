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
        while proc.isRunning {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            guard try outputSize() <= maxOutputBytes else { throw Failure.outputLimit }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard try outputSize() <= maxOutputBytes else { throw Failure.outputLimit }
        return Output(exitCode: proc.terminationStatus,
                      stdout: try String(contentsOf: stdoutURL, encoding: .utf8),
                      stderr: try String(contentsOf: stderrURL, encoding: .utf8))
    }
}
