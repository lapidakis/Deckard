import Foundation

/// A synchronous fence between tool execution and transport replacement.
/// Dispatch holds a call lease through approval, execution and audit. Recovery
/// refuses while any lease exists, and new calls refuse while recovery runs.
public final class SessionLifecycleGate: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var recovering = false

    public init() {}

    public func beginCall() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !recovering else { return false }
        calls += 1
        return true
    }

    public func endCall() {
        lock.lock(); defer { lock.unlock() }
        calls -= 1
    }

    public func beginRecovery() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !recovering, calls == 0 else { return false }
        recovering = true
        return true
    }

    public func endRecovery() {
        lock.lock(); defer { lock.unlock() }
        recovering = false
    }
}
