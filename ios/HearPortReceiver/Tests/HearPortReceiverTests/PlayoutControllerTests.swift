import XCTest
@testable import HearPortReceiver

final class PlayoutControllerTests: XCTestCase {
    func testAdaptiveBudgetAccommodatesCallbackPreparationWithinMaximum() throws {
        let budget = try PlayoutBudget(targetMilliseconds: 30, maximumMilliseconds: 60,
                                       outputReserveMilliseconds: 11)
        var controller = PlayoutController(budget: budget)
        controller.observeArrival(sourceFrame: 0, capturedAt: 1_000_000_000, receivedAt: 1_005_000_000)
        let decision = controller.decision(now: 1_020_000_000, nextSourceFrame: 0,
            playableFrames: 720, stagedSourceFrames: 0, uncertaintyNanoseconds: 15_000_000,
            minimumBufferMilliseconds: 16)
        XCTAssertGreaterThanOrEqual(decision.bufferTargetMilliseconds, 16)
        XCTAssertEqual(decision.targetMilliseconds, 32)
        XCTAssertLessThanOrEqual(controller.decision(now: 1_025_000_000, nextSourceFrame: 0,
            playableFrames: 720, stagedSourceFrames: 0, uncertaintyNanoseconds: 40_000_000,
            minimumBufferMilliseconds: 16).targetMilliseconds, 15)
    }

    func testRepeatedConsumedOriginalDoesNotBiasDelayEstimate() throws {
        let budget = try PlayoutBudget(targetMilliseconds: 50, maximumMilliseconds: 100,
                                       outputReserveMilliseconds: 11)
        var controller = PlayoutController(budget: budget)
        for frame in 0..<16 {
            controller.observeArrival(sourceFrame: UInt64(frame) * 120,
                capturedAt: 1_000_000_000 + UInt64(frame) * 2_500_000,
                receivedAt: 1_005_000_000 + UInt64(frame) * 2_500_000)
        }
        _ = controller.decision(now: 1_100_000_000, nextSourceFrame: 1920,
            playableFrames: 1920, stagedSourceFrames: 0)
        for _ in 0..<300 {
            controller.observeArrival(sourceFrame: 0, capturedAt: 1_000_000_000,
                receivedAt: 1_400_000_000)
        }
        XCTAssertEqual(controller.decision(now: 1_500_000_000, nextSourceFrame: 1920,
            playableFrames: 1920, stagedSourceFrames: 0).targetMilliseconds, 50)
    }

    func testClockMappingPreservesOffsetAndUncertainty() {
        var clock = ClockMapping()
        XCTAssertNil(clock.map(remoteNanoseconds: 1_600_000_000, at: 1_010_000_000))
        clock.observe(localSent: 1_000_000_000, remoteReceived: 1_505_000_000,
                      remoteSent: 1_505_000_000, localReceived: 1_010_000_000)
        XCTAssertEqual(clock.map(remoteNanoseconds: 1_600_000_000, at: 1_010_000_000),
                       1_100_000_000)
        XCTAssertEqual(clock.uncertaintyNanoseconds, 5_000_000)
        XCTAssertEqual(clock.remote(localNanoseconds: 1_100_000_000, at: 1_010_000_000),
                       1_600_000_000)
        XCTAssertEqual(clock.map(remoteNanoseconds: 1_600_000_000, at: 7_010_000_000), 1_100_000_000)
        XCTAssertGreaterThanOrEqual(clock.uncertainty(at: 7_010_000_000), 17_000_000)
        XCTAssertLessThan(clock.uncertainty(at: 7_010_000_000), 18_000_000)
        XCTAssertNil(clock.map(remoteNanoseconds: 1_600_000_000, at: 32_010_000_000))
    }

    func testBadClockExchangeDoesNotReplaceGoodMapping() {
        var clock = ClockMapping()
        clock.observe(localSent: 1_000_000_000, remoteReceived: 1_505_000_000,
                      remoteSent: 1_505_000_000, localReceived: 1_010_000_000)
        clock.observe(localSent: 1_020_000_000, remoteReceived: 1_800_000_000,
                      remoteSent: 1_700_000_000, localReceived: 1_030_000_000)
        XCTAssertEqual(clock.map(remoteNanoseconds: 1_600_000_000, at: 1_030_000_000),
                       1_100_000_000)
    }

    func testClockRelearnsAfterMappingExpires() {
        var clock = ClockMapping()
        clock.observe(localSent: 1_000_000_000, remoteReceived: 1_000_500_000,
                      remoteSent: 1_000_500_000, localReceived: 1_001_000_000)
        XCTAssertTrue(clock.observe(localSent: 32_000_000_000, remoteReceived: 32_010_000_000,
                      remoteSent: 32_010_000_000, localReceived: 32_020_000_000))
        XCTAssertEqual(clock.map(remoteNanoseconds: 32_010_000_000, at: 32_020_000_000), 32_010_000_000)
    }

    func testPreparationDeadlineIncludesOutputAndProcessing() throws {
        let budget = try PlayoutBudget(targetMilliseconds: 50, maximumMilliseconds: 100,
                                       outputReserveMilliseconds: 10)
        XCTAssertEqual(budget.prepareDeadline(capturedAt: 1_000_000_000,
                                              processingMilliseconds: 5,
                                              uncertaintyNanoseconds: 2_000_000),
                       1_083_000_000)
        XCTAssertEqual(budget.prepareDeadline(capturedAt: 2_000_000_000,
            uncertaintyNanoseconds: 100_000_000), 0)
        XCTAssertThrowsError(try PlayoutBudget(targetMilliseconds: 100,
                                              maximumMilliseconds: 50,
                                              outputReserveMilliseconds: 10))
    }

    func testBufferRecoveryExceedsClockCorrectionButRespectsDeadline() throws {
        let budget = try PlayoutBudget(targetMilliseconds: 50, maximumMilliseconds: 100,
                                       outputReserveMilliseconds: 10)
        var controller = PlayoutController(budget: budget, maximumCorrection: 0.1)
        controller.observeArrival(sourceFrame: 0, capturedAt: 1_000_000_000,
                                  receivedAt: 1_005_000_000)
        let full = controller.decision(now: 1_010_000_000, nextSourceFrame: 0,
                                       playableFrames: 3_840, stagedSourceFrames: 0)
        XCTAssertGreaterThan(full.correction, 0.001)
        XCTAssertLessThanOrEqual(full.correction, 0.1)
        let old = controller.decision(now: 1_100_000_000, nextSourceFrame: 0,
                                      playableFrames: 3_840, stagedSourceFrames: 0)
        XCTAssertEqual(old.action, .resync)
        XCTAssertGreaterThanOrEqual(old.correction, 0)
    }

    func testCaptureAnchorFollowsRecentOrderedOriginalSamples() throws {
        let budget = try PlayoutBudget(targetMilliseconds: 50, maximumMilliseconds: 100,
                                       outputReserveMilliseconds: 10)
        var control = PlayoutController(budget: budget)
        control.observeArrival(sourceFrame: 0, capturedAt: 1_000_000_000, receivedAt: 1_010_000_000)
        control.observeArrival(sourceFrame: 48_000, capturedAt: 2_000_100_000, receivedAt: 2_010_100_000)
        control.observeArrival(sourceFrame: 0, capturedAt: 1_000_000_000, receivedAt: 2_010_100_000, original: false)
        XCTAssertEqual(control.captureTime(sourceFrame: 48_000), 2_000_100_000)
    }

    func testStagedFramesAreChargedOnceAndMissingDataCannotSlowForever() throws {
        let budget = try PlayoutBudget(targetMilliseconds: 50, maximumMilliseconds: 100,
                                       outputReserveMilliseconds: 10)
        var a = PlayoutController(budget: budget, maximumCorrection: 0.1)
        var b = a
        let first = a.decision(now: 1_000_000_000, nextSourceFrame: 0,
                               playableFrames: 1_920, stagedSourceFrames: 480)
        let second = b.decision(now: 1_000_000_000, nextSourceFrame: 0,
                                playableFrames: 2_400, stagedSourceFrames: 0)
        XCTAssertEqual(first.correction, second.correction)
        let empty = a.decision(now: 1_010_000_000, nextSourceFrame: 480,
                               playableFrames: 0, stagedSourceFrames: 0)
        XCTAssertEqual(empty.correction, 0)
    }
    func testClockHoldoverRejectsCongestedAnchorAndTargetReservesUncertainty() throws {
        var clock = ClockMapping()
        XCTAssertTrue(clock.observe(localSent: 1_000_000_000, remoteReceived: 1_000_500_000,
            remoteSent: 1_000_500_000, localReceived: 1_001_000_000))
        XCTAssertFalse(clock.observe(localSent: 7_000_000_000, remoteReceived: 7_010_000_000,
            remoteSent: 7_010_000_000, localReceived: 7_020_000_000))
        XCTAssertEqual(clock.map(remoteNanoseconds: 7_010_000_000, at: 7_020_000_000), 7_010_000_000)
        let budget = try PlayoutBudget(targetMilliseconds: 50, maximumMilliseconds: 100,
                                      outputReserveMilliseconds: 1)
        var control = PlayoutController(budget: budget)
        for index in 0..<16 {
            control.observeArrival(sourceFrame: UInt64(index) * 120,
                capturedAt: 1_000_000_000 + UInt64(index) * 2_500_000,
                receivedAt: 1_080_000_000 + UInt64(index) * 2_500_000)
        }
        _ = control.decision(now: 1_100_000_000, nextSourceFrame: 0,
            playableFrames: 4_800, stagedSourceFrames: 0)
        let result = control.decision(now: 2_000_000_000, nextSourceFrame: 0,
            playableFrames: 4_800, stagedSourceFrames: 0, uncertaintyNanoseconds: 30_000_000)
        XCTAssertLessThanOrEqual(result.targetMilliseconds, 65)
        XCTAssertGreaterThanOrEqual(result.correction, 0)
        var fixed = PlayoutController(budget: budget, maximumCorrection: 0, adaptive: false)
        XCTAssertEqual(fixed.decision(now: 1_000_000_000, nextSourceFrame: 0,
            playableFrames: 2_400, stagedSourceFrames: 0,
            uncertaintyNanoseconds: 70_000_000).targetMilliseconds, 25)
        XCTAssertEqual(fixed.decision(now: 1_005_000_000, nextSourceFrame: 0,
            playableFrames: 2_400, stagedSourceFrames: 0).targetMilliseconds, 50)

    }

}
