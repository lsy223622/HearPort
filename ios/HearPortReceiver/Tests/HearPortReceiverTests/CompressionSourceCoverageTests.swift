import XCTest
@testable import HearPortReceiver

final class CompressionSourceCoverageTests: XCTestCase {
    func testLeadingAndIsolatedGapsUseSourceFrames() {
        var coverage = CompressionSourceCoverage(sourceBegin: 100, sourceEnd: 820)
        coverage.recordPrepared(sourceBegin: 220, sourceEnd: 340)
        coverage.recordPrepared(sourceBegin: 580, sourceEnd: 820)
        XCTAssertEqual(coverage.preparedFrames, 360)
        XCTAssertEqual(coverage.longestMissingSourceFrames, 240)
    }

    func testUnpreparedTailContributesToLongestGap() {
        var coverage = CompressionSourceCoverage(sourceBegin: 100, sourceEnd: 820)
        coverage.recordPrepared(sourceBegin: 100, sourceEnd: 340)
        XCTAssertEqual(coverage.preparedFrames, 240)
        XCTAssertEqual(coverage.longestMissingSourceFrames, 480)
    }

    func testNoPreparedAudioCountsTheEntireRound() {
        let coverage = CompressionSourceCoverage(sourceBegin: 100, sourceEnd: 820)
        XCTAssertEqual(coverage.preparedFrames, 0)
        XCTAssertEqual(coverage.longestMissingSourceFrames, 720)
    }

    func testAdjacentIntervalsHaveNoGap() {
        var coverage = CompressionSourceCoverage(sourceBegin: 100, sourceEnd: 820)
        coverage.recordPrepared(sourceBegin: 100, sourceEnd: 340)
        coverage.recordPrepared(sourceBegin: 340, sourceEnd: 820)
        XCTAssertEqual(coverage.preparedFrames, 720)
        XCTAssertEqual(coverage.longestMissingSourceFrames, 0)
    }

    func testCoverageClipsToTheRoundAndIgnoresEmptyIntervals() {
        var coverage = CompressionSourceCoverage(sourceBegin: 100, sourceEnd: 820)
        coverage.recordPrepared(sourceBegin: 0, sourceEnd: 220)
        coverage.recordPrepared(sourceBegin: 220, sourceEnd: 220)
        coverage.recordPrepared(sourceBegin: 220, sourceEnd: 1_000)
        coverage.recordPrepared(sourceBegin: 1_000, sourceEnd: 1_120)
        XCTAssertEqual(coverage.preparedFrames, 720)
        XCTAssertEqual(coverage.longestMissingSourceFrames, 0)
    }

    func testOverlappingIntervalsDoNotCountPreparedFramesTwice() {
        var coverage = CompressionSourceCoverage(sourceBegin: 100, sourceEnd: 820)
        coverage.recordPrepared(sourceBegin: 100, sourceEnd: 340)
        coverage.recordPrepared(sourceBegin: 220, sourceEnd: 580)
        coverage.recordPrepared(sourceBegin: 100, sourceEnd: 220)
        coverage.recordPrepared(sourceBegin: 580, sourceEnd: 820)
        XCTAssertEqual(coverage.preparedFrames, 720)
        XCTAssertEqual(coverage.longestMissingSourceFrames, 0)
    }
}
