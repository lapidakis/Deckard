import Testing
@testable import BridgeCore

// Regression guard for the Hermes tailnet session storm (2026-05): a client
// re-`initialize`ing on every request must not be able to drive an unbounded
// recreate loop. `RecreateThrottle` caps self-heal frequency per window; these
// tests pin that behavior with injected timestamps (no sleeping).
//
// `permit` is `mutating`, which the `#expect` macro can't introspect, so each
// call is captured into a `let` before the expectation.

@Test func throttleAllowsUpToBudgetThenRefusesWithinWindow() {
    var t = RecreateThrottle(maxPerWindow: 3, window: .seconds(30))
    let base = ContinuousClock().now
    let a = t.permit(now: base)
    let b = t.permit(now: base.advanced(by: .seconds(1)))
    let c = t.permit(now: base.advanced(by: .seconds(2)))
    // The 4th recreate inside the window is the storm — refuse it.
    let d = t.permit(now: base.advanced(by: .seconds(3)))
    let e = t.permit(now: base.advanced(by: .seconds(29)))
    #expect(a && b && c)
    #expect(d == false)
    #expect(e == false)
}

@Test func throttleBudgetRefreshesAfterWindowRolls() {
    var t = RecreateThrottle(maxPerWindow: 2, window: .seconds(30))
    let base = ContinuousClock().now
    let a = t.permit(now: base)
    let b = t.permit(now: base.advanced(by: .seconds(5)))
    let c = t.permit(now: base.advanced(by: .seconds(6)))    // spent
    // Past the window the budget refreshes, so a later legitimate reconnect heals.
    let d = t.permit(now: base.advanced(by: .seconds(31)))
    let e = t.permit(now: base.advanced(by: .seconds(32)))
    let f = t.permit(now: base.advanced(by: .seconds(33)))
    #expect(a && b)
    #expect(c == false)
    #expect(d && e)
    #expect(f == false)
}

@Test func throttleNeverTripsForOccasionalReconnects() {
    // A well-behaved client that reconnects once every couple of minutes opens a
    // fresh window each time and never approaches the budget — the heal must
    // stay available for it indefinitely.
    var t = RecreateThrottle(maxPerWindow: 5, window: .seconds(30))
    let base = ContinuousClock().now
    for i in 0..<20 {
        let ok = t.permit(now: base.advanced(by: .seconds(Double(i) * 120)))
        #expect(ok)
    }
}

@Test func throttleFirstRecreateIsAlwaysAllowed() {
    // Even a budget of 1 must let the genuine first reconnect through.
    var t = RecreateThrottle(maxPerWindow: 1, window: .seconds(60))
    let ok = t.permit(now: ContinuousClock().now)
    #expect(ok)
}
