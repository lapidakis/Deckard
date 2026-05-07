import Testing
import Foundation
@testable import ServiceVoiceMemo

@Test func coreDataEpochOffsetMatchesAppleSpec() {
    // Apple's reference: 2001-01-01T00:00:00Z = 978307200 unix seconds.
    #expect(CoreDataEpoch.unixOffset == 978_307_200)
}

@Test func coreDataToUnixRoundTrip() {
    let unix = 1_772_049_365.0
    let coreData = CoreDataEpoch.fromUnix(unix)
    #expect(CoreDataEpoch.toUnix(coreData) == unix)
}

@Test func coreDataMatchesObservedRecording() {
    // Real value from Mike's CloudRecordings.db sanity check:
    //   ZDATE = 793742165.971095 → 2026-02-25T19:56:05Z
    let zdate = 793_742_165.971095
    let unix = CoreDataEpoch.toUnix(zdate)
    let date = Date(timeIntervalSince1970: unix)
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    let iso = f.string(from: date)
    #expect(iso == "2026-02-25T19:56:05Z")
}
