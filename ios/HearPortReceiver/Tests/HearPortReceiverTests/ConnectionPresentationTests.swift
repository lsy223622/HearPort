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

    func testQualityWarmsUpThenDowngradesImmediatelyAndRecoversSlowly() {
        var tracker = AudioLinkQualityTracker()
        tracker.observe(sample(0, received: 0))
        tracker.observe(sample(1, received: 400))
        XCTAssertEqual(tracker.quality, .unknown)
        tracker.observe(sample(2, received: 800))
        tracker.observe(sample(3, received: 1200))
        XCTAssertEqual(tracker.quality, .stable)
        tracker.observe(sample(4, received: 1600, missing: 20))
        XCTAssertEqual(tracker.quality, .poor)
        for second in 5...13 {
            tracker.observe(sample(Double(second), received: second * 400, missing: 20))
        }
        XCTAssertEqual(tracker.quality, .poor)
        for second in 14...20 {
            tracker.observe(sample(Double(second), received: second * 400, missing: 20))
        }
        XCTAssertEqual(tracker.quality, .stable)
    }

    func testCounterResetAndLongSamplingPauseReturnToUnknown() {
        var tracker = AudioLinkQualityTracker()
        for second in 0...3 { tracker.observe(sample(Double(second), received: second * 400)) }
        XCTAssertEqual(tracker.quality, .stable)
        tracker.observe(sample(4, received: 10, epoch: 2))
        XCTAssertEqual(tracker.quality, .unknown)
        for second in 5...7 { tracker.observe(sample(Double(second), received: (second - 4) * 400, epoch: 2)) }
        XCTAssertEqual(tracker.quality, .stable)
        tracker.observe(sample(20, received: 1400, epoch: 2))
        XCTAssertEqual(tracker.quality, .unknown)
    }

    func testNoTrafficAndInterruptedOutputAreNotStable() {
        var tracker = AudioLinkQualityTracker()
        for second in 0...3 { tracker.observe(sample(Double(second), received: second * 400)) }
        tracker.observe(sample(4, received: 1200, interrupted: true))
        XCTAssertEqual(tracker.quality, .poor)
        for second in 5...15 { tracker.observe(sample(Double(second), received: 1200)) }
        XCTAssertEqual(tracker.quality, .unknown)
    }

    func testRoundTripAndLatePacketsCanDowngradeOtherwiseCleanDelivery() {
        var tracker = AudioLinkQualityTracker()
        for second in 0...3 {
            tracker.observe(sample(Double(second), received: second * 400, rtt: 90))
        }
        XCTAssertEqual(tracker.quality, .variable)
        tracker.observe(sample(4, received: 1600, late: 80, rtt: 20))
        XCTAssertEqual(tracker.quality, .poor)
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

    func testOutputUnderflowBetweenPollsDowngradesQuality() {
        var tracker = AudioLinkQualityTracker()
        for second in 0...3 { tracker.observe(sample(Double(second), received: second * 400)) }
        let receiver = HearPortReceiver()
        _ = receiver.renderFrames(120)
        var next = sample(4, received: 1600)
        next.outputGapFrames = receiver.audioLinkSample().outputGapFrames
        tracker.observe(next)
        XCTAssertEqual(tracker.quality, .poor)
    }

    private func sample(_ time: Double, received: Int, missing: Int = 0, late: Int = 0,
                        epoch: UInt64 = 1, rtt: Double? = 10, interrupted: Bool = false) -> AudioLinkSample {
        AudioLinkSample(epoch: epoch, time: time, received: received, missing: missing,
                        late: late, roundTripMilliseconds: rtt, interrupted: interrupted)
    }
}
