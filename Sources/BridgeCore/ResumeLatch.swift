import Foundation

/// Single-shot latch used to guarantee a `CheckedContinuation` resumes
/// exactly once when two paths might race to fulfill it. The first caller
/// to `tryResume()` wins; subsequent callers become no-ops.
///
/// Use case: `RemindersAdapter.performAccessRequest` races EventKit's
/// completion handler against a `DispatchQueue.asyncAfter` timeout. Either
/// path may complete first and call `cont.resume(...)`. Without this latch
/// the loser of the race would crash the process by double-resuming a
/// CheckedContinuation.
///
/// The class is `@unchecked Sendable` because access is guarded by NSLock;
/// access from non-async contexts (Dispatch closures) is fine. Don't reach
/// for it inside an actor's async method — that's where Swift 6 would
/// reject the `lock()` call. The intended call sites are non-isolated:
/// completion handlers, DispatchQueue.asyncAfter blocks, low-level NIO
/// callbacks.
public final class ResumeLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false

    public init() {}

    /// Returns true exactly once across all callers. The caller that gets
    /// `true` is responsible for resuming the continuation; callers that
    /// get `false` must do nothing.
    public func tryResume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if consumed { return false }
        consumed = true
        return true
    }
}
