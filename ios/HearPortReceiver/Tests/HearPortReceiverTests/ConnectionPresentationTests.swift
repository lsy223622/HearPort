import XCTest
@testable import HearPortReceiver

final class ConnectionPresentationTests: XCTestCase {
    func testCompletionAndReportOutrankPlaybackAndTestCallbacks() {
        XCTAssertEqual(ConnectionPresentationStage.resolve(completed: true, reporting: true,
            recovering: true, connecting: true, playing: true, testing: true), .completed)
        XCTAssertEqual(ConnectionPresentationStage.resolve(completed: false, reporting: true,
            recovering: false, connecting: false, playing: true, testing: true), .reporting)
    }

    func testRecoveryNeverFallsBackToIdleWhileSearching() {
        XCTAssertEqual(ConnectionPresentationStage.resolve(completed: false, reporting: false,
            recovering: true, connecting: true, playing: false, testing: false), .recovering)
        XCTAssertEqual(ConnectionPresentationStage.resolve(completed: false, reporting: false,
            recovering: false, connecting: true, playing: false, testing: false), .connecting)
    }

    func testSilentComputerCanHaveStableTiming() {
        var tracker = AudioLinkQualityTracker()
        for second in stride(from: 0, through: 12, by: 2) {
            var point = sample(Double(second), rtt: 8)
            point.outputGapFrames = UInt64(second * 48_000)
            tracker.observe(point)
        }
        XCTAssertEqual(tracker.quality, .stable)
    }

    func testFiveToTenMillisecondsIsStillStable() {
        var tracker = AudioLinkQualityTracker()
        for (index, delay) in [5.0,10,5,10,5,10].enumerated() {
            tracker.observe(sample(Double(index * 2), rtt: delay))
        }
        XCTAssertEqual(tracker.quality, .stable)
    }

    func testConstantHighRoundTripIsStableRatherThanLowLatency() {
        var tracker = AudioLinkQualityTracker()
        for second in stride(from: 0, through: 12, by: 2) {
            tracker.observe(sample(Double(second), rtt: 180))
        }
        XCTAssertEqual(tracker.quality, .stable)
    }

    func testAbsoluteDelayVariationDistinguishesModerateAndLargeSwings() {
        for (delays, expected) in [([5.0,25,5,25,5], AudioLinkQuality.variable),
                                    ([5.0,65,5,65,5], .poor)] {
            var tracker = AudioLinkQualityTracker()
            for (index, delay) in delays.enumerated() {
                tracker.observe(sample(Double(index * 2), rtt: delay))
            }
            XCTAssertEqual(tracker.quality, expected)
        }
    }

    func testAudioAvailabilityCountersDoNotChangeTimingAssessment() {
        var tracker = AudioLinkQualityTracker()
        for second in stride(from: 0, through: 12, by: 2) {
            var point = sample(Double(second), rtt: 8)
            point.outputGapFrames = UInt64(second * 48_000)
            tracker.observe(point)
        }
        for second in stride(from: 14, through: 24, by: 2) {
            tracker.observe(sample(Double(second), rtt: 8, received: second * 400,
                missing: second * 10, late: second * 15))
        }
        XCTAssertEqual(tracker.quality, .stable)
    }

    func testReceiverReportsRawRttWithFreshnessAndConnectionReset() {
        let receiver = HearPortReceiver()
        XCTAssertNil(receiver.audioLinkSample(at: 1_000_000_000).roundTripMilliseconds)
        XCTAssertTrue(receiver.observeClock(localSent: 1_000_000_000,
            remoteReceived: 2_001_000_000, remoteSent: 2_001_000_000, localReceived: 1_002_000_000))
        // This valid, slow exchange is rejected by the clock estimator's outlier filter.
        XCTAssertFalse(receiver.observeClock(localSent: 2_000_000_000,
            remoteReceived: 3_050_000_000, remoteSent: 3_050_000_000, localReceived: 2_100_000_000))
        XCTAssertEqual(receiver.audioLinkSample(at: 2_100_000_000).roundTripMilliseconds, 100)
        XCTAssertNil(receiver.audioLinkSample(at: 9_000_000_000).roundTripMilliseconds)
        receiver.resetForConnection()
        XCTAssertNil(receiver.audioLinkSample(at: 2_100_000_000).roundTripMilliseconds)
    }

    private func sample(_ time: Double, rtt: Double?, received: Int = 0,
                        missing: Int = 0, late: Int = 0) -> AudioLinkSample {
        AudioLinkSample(epoch: 1, time: time, received: received, missing: missing,
                        late: late, roundTripMilliseconds: rtt, interrupted: true)
    }
}
