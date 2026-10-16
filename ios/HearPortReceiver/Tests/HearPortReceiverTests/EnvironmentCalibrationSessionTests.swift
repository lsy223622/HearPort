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
    func testIncompleteOrUnknownResultCannotReplaceSavedCalibration() throws {
        let name = "CalibrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let session = EnvironmentCalibrationSession(setup: setup())
        let incomplete = session.result(at: 1, completed: false)
        defaults.set(Data([1,2,3]), forKey: CalibrationResult.storageKey)
        XCTAssertFalse(incomplete.save(to: defaults))
        XCTAssertEqual(defaults.data(forKey: CalibrationResult.storageKey), Data([1,2,3]))
        XCTAssertNil(CalibrationResult.load(from: defaults))
        XCTAssertFalse(incomplete.apply(profile: 1, to: defaults))
        XCTAssertNil(defaults.object(forKey: "hearport.targetLatencyMs"))
        XCTAssertFalse(incomplete.reportSections.contains("nan"))
        XCTAssertTrue(incomplete.reportSections.contains("calibration_summary_v1"))
    }

    func testCompleteResultPersistsAndAppliesAllThreePreferences() throws {
        let name = "CalibrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let budget = CalibrationBudget(target: 50, maximum: 100)
        let choice = CalibrationChoice(profileMask: 7, reliable: true, budget: budget, outputReserve: 11)
        var baseline = CalibrationMeasurement(round: 0, reliable: true, budget: budget, outputReserve: 11, inputFingerprint: "fixture")
        baseline.complete = true; baseline.clockValid = true; baseline.sampleCount = 2
        baseline.sourceFrames = 48000; baseline.outputSeconds = 1; baseline.ageP95Milliseconds = 60
        let recommendations = [1,2,4].map { CalibrationRecommendation(profile: $0, choice: choice, measurement: baseline, metGoal: true) }
        let analysis = CalibrationAnalysis(measurements: [], candidates: [baseline], coverage: [], recommendations: recommendations, pairedRanges: [])
        var first = baseline, second = baseline
        first = CalibrationMeasurement(round: 5, reliable: true, budget: budget, outputReserve: 11, inputFingerprint: "live-a")
        second = CalibrationMeasurement(round: 6, reliable: true, budget: budget, outputReserve: 11, inputFingerprint: "live-b")
        for index in 0..<2 {
            if index == 0 { first.complete = true; first.clockValid = true; first.sourceFrames = 48000; first.outputSeconds = 1; first.ageP95Milliseconds = 60 }
            else { second.complete = true; second.clockValid = true; second.sourceFrames = 48000; second.outputSeconds = 1; second.ageP95Milliseconds = 60 }
        }
        let result = CalibrationResult(version: 1, planID: 7, testedAt: Date(), seconds: 30, maximum: 100,
            analysis: analysis, validation: [first,second], complete: true, warnings: [])
        XCTAssertTrue(result.save(to: defaults))
        XCTAssertTrue(CalibrationResult.load(from: defaults)?.usable == true)
        XCTAssertTrue(result.apply(profile: 2, to: defaults))
        XCTAssertEqual(defaults.string(forKey: "hearport.audioTransportMode"), AudioTransportMode.reliable.rawValue)
        XCTAssertEqual(defaults.integer(forKey: "hearport.targetLatencyMs"), 50)
        XCTAssertEqual(defaults.integer(forKey: "hearport.maximumLatencyMs"), 100)
        XCTAssertEqual(result.validationStatus(profile: 2), "observed")
        second.missingOutputSeconds = 0.002; second.longestOutputGapMilliseconds = 25
        let worse = CalibrationResult(version: 1, planID: 7, testedAt: Date(), seconds: 30, maximum: 100,
            analysis: analysis, validation: [first,second], complete: true, warnings: [])
        XCTAssertEqual(worse.validationStatus(profile: 2), "not_met")
        XCTAssertEqual(worse.validationStatus(profile: 1), "provisional")
        let unknown = CalibrationResult(version: 2, planID: 7, testedAt: Date(), seconds: 30, maximum: 100,
            analysis: analysis, validation: [first,second], complete: true, warnings: [])
        XCTAssertFalse(unknown.save(to: defaults))
        XCTAssertFalse(unknown.apply(profile: 2, to: defaults))
        XCTAssertEqual(CalibrationResult.load(from: defaults)?.planID, 7)
    }

}
