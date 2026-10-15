import XCTest
@testable import HearPortReceiver

final class ClockMappingTests: XCTestCase {
    func testAsymmetricExchangeAndEarlierCapturesStayWithinUncertainty() throws {
        var clock = ClockMapping()
        XCTAssertTrue(clock.observe(localSent: 1_000_000_000, remoteReceived: 12_000_000_000,
            remoteSent: 12_000_000_000, localReceived: 1_020_000_000))
        for local in [UInt64(900_000_000), 1_014_000_000] {
            let timestamp = UInt64((12e9 + (Double(local) - 1e9) / 0.998).rounded())
            let mapped = try XCTUnwrap(clock.map(remoteNanoseconds: timestamp, at: 1_020_000_000))
            let error = abs(Double(mapped) - Double(local))
            XCTAssertLessThanOrEqual(error,
                Double(clock.uncertainty(at: 1_020_000_000, remoteNanoseconds: timestamp)))
        }
    }

    func testFittedRateReversalStaysWithinHoldoverUncertainty() throws {
        var clock = ClockMapping()
        var lastReceived: UInt64 = 0
        var lastMidpoint: UInt64 = 0
        var lastRemote: UInt64 = 0
        for index in 0...200 {
            let sent = 1_000_000_000 + UInt64(index) * 2_000_000_000
            lastMidpoint = sent + 50_000
            lastReceived = sent + 100_000
            lastRemote = UInt64((12e9 + Double(lastMidpoint - 1_000_000_000) / 1.002).rounded())
            XCTAssertTrue(clock.observe(localSent: sent, remoteReceived: lastRemote,
                remoteSent: lastRemote, localReceived: lastReceived))
        }
        let now = lastReceived + 30_000_000_000
        let capture = now - 6_000_000
        let timestamp = lastRemote + UInt64((Double(capture - lastMidpoint) / 0.998).rounded())
        let mapped = try XCTUnwrap(clock.map(remoteNanoseconds: timestamp, at: now))
        XCTAssertLessThanOrEqual(abs(Double(mapped) - Double(capture)),
            Double(clock.uncertainty(at: now, remoteNanoseconds: timestamp)))
    }

    func testSustainedRttIncreaseDoesNotExpireMapping() {
        var clock = ClockMapping()
        XCTAssertTrue(clock.observe(localSent: 1_000_000_000, remoteReceived: 1_001_000_000,
            remoteSent: 1_001_000_000, localReceived: 1_002_000_000))
        for second in stride(from: UInt64(2), through: 120, by: 2) {
            let delay: UInt64 = second == 8 ? 100_000_000 : 0
            let sent = 1_000_000_000 + second * 1_000_000_000 + delay
            let halfRtt: UInt64 = second < 10 ? 1_000_000 : 10_000_000
            _ = clock.observe(localSent: sent, remoteReceived: sent + halfRtt,
                remoteSent: sent + halfRtt, localReceived: sent + halfRtt * 2)
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
