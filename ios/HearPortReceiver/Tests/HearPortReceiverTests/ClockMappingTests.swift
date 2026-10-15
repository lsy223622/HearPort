import XCTest
@testable import HearPortReceiver

final class ClockMappingTests: XCTestCase {
    func testSustainedRttIncreaseDoesNotExpireMapping() {
        var clock = ClockMapping()
        XCTAssertTrue(clock.observe(localSent: 1_000_000_000, remoteReceived: 1_001_000_000,
            remoteSent: 1_001_000_000, localReceived: 1_002_000_000))
        for second in stride(from: UInt64(2), through: 120, by: 2) {
            let sent = 1_000_000_000 + second * 1_000_000_000
            _ = clock.observe(localSent: sent, remoteReceived: sent + 10_000_000,
                remoteSent: sent + 10_000_000, localReceived: sent + 20_000_000)
            for offset in stride(from: UInt64(20_000_000), to: 2_000_000_000, by: 10_000_000) {
                XCTAssertNotNil(clock.map(remoteNanoseconds: sent + offset, at: sent + offset))
            }
        }
    }

    func testQueuedArrivalCanPrecedeLatestClockUpdate() {
        var clock = ClockMapping()
        XCTAssertTrue(clock.observe(localSent: 1_000_000_000, remoteReceived: 1_501_000_000,
            remoteSent: 1_501_000_000, localReceived: 1_002_000_000))
        XCTAssertEqual(clock.map(remoteNanoseconds: 1_501_000_000, at: 1_001_900_000), 1_001_000_000)
        XCTAssertEqual(clock.remote(localNanoseconds: 1_001_000_000, at: 1_001_900_000), 1_501_000_000)
        XCTAssertGreaterThanOrEqual(clock.uncertainty(at: 1_001_900_000), 1_000_000)
        XCTAssertLessThan(clock.uncertainty(at: 1_001_900_000), 2_000_000)
    }

    func testInvalidOrOldExchangeDoesNotRenewMapping() {
        var clock = ClockMapping()
        XCTAssertTrue(clock.observe(localSent: 1_000_000_000, remoteReceived: 1_001_000_000,
            remoteSent: 1_001_000_000, localReceived: 1_002_000_000))
        XCTAssertFalse(clock.observe(localSent: 900_000_000, remoteReceived: 901_000_000,
            remoteSent: 901_000_000, localReceived: 902_000_000))
        XCTAssertFalse(clock.observe(localSent: 30_000_000_000, remoteReceived: 30_300_000_000,
            remoteSent: 30_300_000_000, localReceived: 30_600_000_000))
        XCTAssertNil(clock.map(remoteNanoseconds: 32_000_000_000, at: 32_000_000_000))
        XCTAssertEqual(clock.uncertainty(at: 32_000_000_000), .max)
    }
}
