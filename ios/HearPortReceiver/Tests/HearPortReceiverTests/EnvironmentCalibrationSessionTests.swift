import XCTest
@testable import HearPortReceiver

final class EnvironmentCalibrationSessionTests: XCTestCase {
    private func setup() -> CalibrationMessage {
        var m = CalibrationMessage(kind: .setup, planID: 7)
        m.budget = CalibrationBudget(target: 0, maximum: 100)
        return m
    }
    private func round(_ index: Int) -> CalibrationMessage {
        var m = CalibrationMessage(kind: .round, planID: 7)
        m.index = index; m.count = 4; m.generation = UInt32(index)
        m.budget = CalibrationBudget(target: 50, maximum: 100); m.outputReserve = 11
        m.firstSequence = UInt32((index - 1) * 12000); m.firstSourceFrame = UInt64(m.firstSequence) * 120
        return m
    }
    func testRoundSessionRejectsWrongPlanAndOldPackets() throws {
        let session = EnvironmentCalibrationSession(setup: setup())
        let ack = try session.beginRound(round(1), at: 1_000_000_000)
        XCTAssertEqual(ack.kind, .ack)
        XCTAssertThrowsError(try session.beginRound(round(1), at: 1_000_000_000))
        let old = try TimedAudioRecord(streamID: 1, generation: 1, sequence: 12000, frameCount: 120,
            kind: .probe, capturedAt: 1_000_000_000, sourceFrame: 1_440_000, payload: Data(repeating: 0, count: 960))
        XCTAssertFalse(session.receive(old, capturedAt: old.capturedAt, uncertainty: 0,
                                       receivedAt: 1_010_000_000, processedAt: 1_010_000_000))
        var wrong = round(2); wrong.planID = 8
        XCTAssertThrowsError(try session.beginRound(wrong, at: 31_200_000_000))
    }
    func testMissingDataAndInterruptedRunCannotPublishCompleteResult() throws {
        let session = EnvironmentCalibrationSession(setup: setup())
        for index in 1...4 {
            _ = try session.beginRound(round(index), at: UInt64(index) * 35_000_000_000)
        }
        let analysis = try session.analyze(at: 175_000_000_000, progress: { _,_ in })
        XCTAssertTrue(analysis.recommendations.isEmpty)
        XCTAssertFalse(session.result(at: 176_000_000_000, completed: true).complete)
        session.cancel()
        XCTAssertThrowsError(try session.analyze(at: 177_000_000_000, progress: { _,_ in }))
        XCTAssertFalse(session.result(at: 178_000_000_000, completed: true).complete)
    }
}
