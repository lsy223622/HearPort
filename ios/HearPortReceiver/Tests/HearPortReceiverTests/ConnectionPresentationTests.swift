import XCTest
@testable import HearPortReceiver

final class ConnectionPresentationTests: XCTestCase {
    func testNetworkEndpointLabelsIncludePortAndBracketIPv6() {
        XCTAssertEqual(networkEndpointLabel(address: "192.0.2.1", port: 52137), "192.0.2.1:52137")
        XCTAssertEqual(networkEndpointLabel(address: "2001:db8::1", port: 60000), "[2001:db8::1]:60000")
        XCTAssertEqual(networkEndpointLabel(address: "fe80::1%en0", port: 52137), "[fe80::1%en0]:52137")
    }
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
        var tracker = LinkStabilityTracker()
        for second in stride(from: 0, through: 12, by: 2) {
            tracker.observe(sample(Double(second), rtt: 8))
        }
        XCTAssertEqual(tracker.quality, .stable)
    }

    func testFiveToTenMillisecondsIsStillStable() {
        var tracker = LinkStabilityTracker()
        for (index, delay) in [5.0,10,5,10,5,10].enumerated() {
            tracker.observe(sample(Double(index * 2), rtt: delay))
        }
        XCTAssertEqual(tracker.quality, .stable)
    }

    func testConstantHighRoundTripIsStableRatherThanLowLatency() {
        var tracker = LinkStabilityTracker()
        for second in stride(from: 0, through: 12, by: 2) {
            tracker.observe(sample(Double(second), rtt: 180))
        }
        XCTAssertEqual(tracker.quality, .stable)
    }

    func testAbsoluteDelayVariationDistinguishesModerateAndLargeSwings() {
        for (delays, expected) in [([5.0,25,5,25,5], LinkStability.variable),
                                    ([5.0,65,5,65,5], .poor)] {
            var tracker = LinkStabilityTracker()
            for (index, delay) in delays.enumerated() {
                tracker.observe(sample(Double(index * 2), rtt: delay))
            }
            XCTAssertEqual(tracker.quality, expected)
        }
    }

    func testOnlyDistinctProbeResponsesCompleteWarmup() {
        var tracker = LinkStabilityTracker()
        for second in 0...5 {
            tracker.observe(sample(Double(second), rtt: 8, observedAt: 0))
        }
        XCTAssertEqual(tracker.sampleCount, 1)
        XCTAssertEqual(tracker.quality, .unknown)
        tracker.observe(sample(6, rtt: 8))
        XCTAssertEqual(tracker.quality, .unknown)
        tracker.observe(sample(8, rtt: 8))
        XCTAssertEqual(tracker.sampleCount, 3)
        XCTAssertEqual(tracker.quality, .stable)
    }

    func testProbeSilenceDegradesAndRecoveryRequiresObservation() {
        var tracker = LinkStabilityTracker()
        for second in [0,2,4] { tracker.observe(sample(Double(second), rtt: 8)) }
        XCTAssertEqual(tracker.quality, .stable)
        for second in 5...11 {
            tracker.observe(sample(Double(second), rtt: nil, observedAt: 4_000_000_000))
        }
        XCTAssertEqual(tracker.quality, .poor)
        for second in [12,14,16,18] { tracker.observe(sample(Double(second), rtt: 8)) }
        XCTAssertEqual(tracker.quality, .poor)
        tracker.observe(sample(20, rtt: 8))
        XCTAssertEqual(tracker.quality, .stable)
    }

    func testConnectionChangeAndLongPollingPauseRestartWarmup() {
        var tracker = LinkStabilityTracker()
        for second in [0,2,4] { tracker.observe(sample(Double(second), rtt: 8)) }
        tracker.observe(sample(5, rtt: 8, epoch: 2))
        XCTAssertEqual(tracker.quality, .unknown)
        tracker.observe(sample(7, rtt: 8, epoch: 2))
        tracker.observe(sample(9, rtt: 8, epoch: 2))
        XCTAssertEqual(tracker.quality, .stable)
        tracker.observe(sample(15, rtt: 8, epoch: 2))
        XCTAssertEqual(tracker.quality, .unknown)
        XCTAssertEqual(tracker.sampleCount, 1)
    }

    func testAudioStreamStartupAndUnderflowDoNotResetTimingAssessment() {
        let receiver = HearPortReceiver()
        XCTAssertTrue(receiver.beginAuthentication(authMode: .oneTime, peerID: Data()))
        XCTAssertTrue(receiver.markAuthenticated())
        var tracker = LinkStabilityTracker()
        for second in [0,2,4] {
            let sent = UInt64(second + 1) * 1_000_000_000
            XCTAssertTrue(receiver.observeClock(localSent: sent, remoteReceived: sent + 4_000_000,
                remoteSent: sent + 4_000_000, localReceived: sent + 8_000_000))
            tracker.observe(receiver.linkTimingSample(at: sent + 8_000_000))
        }
        XCTAssertEqual(tracker.quality, .stable)
        let before = receiver.linkTimingSample(at: 5_008_000_000)
        XCTAssertTrue(receiver.beginStream(7))
        XCTAssertTrue(receiver.beginReliableGeneration(7))
        _ = receiver.renderFrames(120)
        let after = receiver.linkTimingSample(at: 6_008_000_000)
        XCTAssertEqual(before.epoch, after.epoch)
        XCTAssertEqual(before.roundTripObservedAt, after.roundTripObservedAt)
        tracker.observe(after)
        XCTAssertEqual(tracker.quality, .stable)
    }

    func testReceiverReportsRawRttWithFreshnessAndConnectionReset() {
        let receiver = HearPortReceiver()
        XCTAssertNil(receiver.linkTimingSample(at: 1_000_000_000).roundTripMilliseconds)
        XCTAssertTrue(receiver.observeClock(localSent: 1_000_000_000,
            remoteReceived: 2_001_000_000, remoteSent: 2_001_000_000, localReceived: 1_002_000_000))
        // This valid, slow exchange is rejected by the clock estimator's outlier filter.
        XCTAssertFalse(receiver.observeClock(localSent: 2_000_000_000,
            remoteReceived: 3_050_000_000, remoteSent: 3_050_000_000, localReceived: 2_100_000_000))
        XCTAssertEqual(receiver.linkTimingSample(at: 2_100_000_000).roundTripMilliseconds, 100)
        XCTAssertEqual(receiver.linkTimingSample(at: 2_100_000_000).roundTripObservedAt, 2_100_000_000)
        XCTAssertNil(receiver.linkTimingSample(at: 9_000_000_000).roundTripMilliseconds)
        receiver.resetForConnection()
        XCTAssertNil(receiver.linkTimingSample(at: 2_100_000_000).roundTripMilliseconds)
    }

    private func sample(_ time: Double, rtt: Double?, observedAt: UInt64? = nil,
                        epoch: UInt64 = 1) -> LinkTimingSample {
        LinkTimingSample(epoch: epoch, time: time, roundTripMilliseconds: rtt,
            roundTripObservedAt: observedAt ?? (rtt == nil ? nil : UInt64(time * 1_000_000_000)))
    }
}
