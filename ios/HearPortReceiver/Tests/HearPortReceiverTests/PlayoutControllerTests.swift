import XCTest
@testable import HearPortReceiver

final class PlayoutControllerTests: XCTestCase {
    func testClockMappingPreservesOffsetAndUncertainty() {
        var clock = ClockMapping()
        XCTAssertNil(clock.map(remoteNanoseconds: 1_600_000_000, at: 1_010_000_000))
        clock.observe(localSent: 1_000_000_000, remoteReceived: 1_505_000_000,
                      remoteSent: 1_505_000_000, localReceived: 1_010_000_000)
        XCTAssertEqual(clock.map(remoteNanoseconds: 1_600_000_000, at: 1_010_000_000),
                       1_100_000_000)
        XCTAssertEqual(clock.uncertaintyNanoseconds, 5_000_000)
        XCTAssertNil(clock.map(remoteNanoseconds: 1_600_000_000, at: 7_010_000_000))
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

    func testPreparationDeadlineIncludesOutputAndProcessing() throws {
        let budget = try PlayoutBudget(targetMilliseconds: 50, maximumMilliseconds: 100,
                                       outputReserveMilliseconds: 10)
        XCTAssertEqual(budget.prepareDeadline(capturedAt: 1_000_000_000,
                                              processingMilliseconds: 5,
                                              uncertaintyNanoseconds: 2_000_000),
                       1_083_000_000)
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
}
