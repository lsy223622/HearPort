import XCTest
@testable import HearPortReceiver

final class AdaptiveCalibrationTests: XCTestCase {
    private func measurement(_ p: AdaptiveParameters, ratio: Double = 0, valid: Bool = true) -> CalibrationMeasurement {
        var m = CalibrationMeasurement(round: 1, reliable: p.reliable, budget: p.budget,
            outputReserve: p.reserve, inputFingerprint: "paired-test")
        m.complete = valid; m.clockValid = valid
        m.sourceFrames = 48_000; m.missingSourceFrames = UInt64(ratio * 48_000)
        m.outputSeconds = 1; m.missingOutputSeconds = ratio
        m.longestSourceGapMilliseconds = ratio * 1000
        m.ageP95Milliseconds = Double(p.budget.target)
        return m
    }

    func testAdaptiveWireUsesSharedFixtureAndPreservesSelectionFormatAndPhase() throws {
        var request = CalibrationMessage(kind: .request, planID: 0x01020304)
        request.goal = 2; request.seconds = 15; request.budget = CalibrationBudget(target: 0, maximum: 300)
        let fixture = Data([5,6,1,2,3,4,2,0,15,1,44])
        XCTAssertEqual(try request.encoded(), fixture)
        XCTAssertEqual(try CalibrationMessage(encoded: fixture), request)
        var selection = CalibrationMessage(kind: .selection, planID: 7)
        selection.goal = 2; selection.phase = 1
        selection.format = try AudioStreamFormat(opus: true, bitrate: 192_000, frameCount: 480)
        selection.choices = [CalibrationChoice(profileMask: 2, reliable: true,
            budget: CalibrationBudget(target: 90, maximum: 150), outputReserve: 11)]
        let selected = Data([5,4,0,0,0,7,2,0,1,2,1,0,90,0,150,0,11,1,0,2,238,0,1,224,1])
        XCTAssertEqual(try selection.encoded(), selected)
        XCTAssertEqual(try CalibrationMessage(encoded: selected), selection)
        for length in 0..<selected.count {
            XCTAssertThrowsError(try CalibrationMessage(encoded: selected.prefix(length)))
        }
        XCTAssertThrowsError(try CalibrationMessage(encoded: selected + Data([0])))
        selection.goal = 1
        XCTAssertThrowsError(try selection.encoded())
    }

    func testBaselinesUseABBAAndEachChangedSettingIsRepeated() throws {
        var search = AdaptiveCalibrationSearch(goal: 2, maximum: 300, reserve: 11)
        var modes: [Bool] = []
        for _ in 0..<4 {
            let p = try XCTUnwrap(search.next()); modes.append(p.reliable)
            search.record(p, measurement: measurement(p), validation: false)
        }
        XCTAssertEqual(modes, [false,true,true,false])
        let p = try XCTUnwrap(search.next())
        XCTAssertEqual(p.format.frameCount, 120)
        search.record(p, measurement: measurement(p), validation: false)
        XCTAssertEqual(search.next(), p)
    }

    func testBadNetworkReducesLoadThenIncreasesBudgetAndTerminates() throws {
        var search = AdaptiveCalibrationSearch(goal: 2, maximum: 300, reserve: 11)
        var choices: [AdaptiveParameters] = []
        while let p = search.next() {
            choices.append(p)
            search.record(p, measurement: measurement(p, ratio: 0.2), validation: search.validating)
            XCTAssertLessThanOrEqual(choices.count, 16)
        }
        XCTAssertTrue(choices.contains { $0.format.bitrate == 192_000 && $0.format.frameCount == 480 })
        XCTAssertTrue(choices.contains { $0.budget.maximum > 150 })
        XCTAssertEqual(search.observations.filter(\.validation).count, 2)
        XCTAssertNotNil(search.selected)
    }

    func testFailureContinuesFromMeasuredBetterTransportRatherThanLastRound() throws {
        var search = AdaptiveCalibrationSearch(goal: 2, maximum: 300, reserve: 11)
        for _ in 0..<4 {
            let p = try XCTUnwrap(search.next())
            search.record(p, measurement: measurement(p, ratio: p.reliable ? 0.01 : 0.1), validation: false)
        }
        XCTAssertTrue(try XCTUnwrap(search.next()).reliable)
    }

    func testEveryChangedLoadAndBudgetComparesBothTransportsTwice() throws {
        var search = AdaptiveCalibrationSearch(goal: 2, maximum: 300, reserve: 11)
        while let p = search.next() {
            search.record(p, measurement: measurement(p, ratio: 0.2), validation: search.validating)
            XCTAssertLessThanOrEqual(search.observations.count, 16)
        }
        let rows = search.observations.filter { !$0.validation }
        for row in rows {
            let peers = rows.filter { $0.parameters.format == row.parameters.format && $0.parameters.budget == row.parameters.budget }
            XCTAssertEqual(peers.filter { $0.parameters.reliable }.count, 2)
            XCTAssertEqual(peers.filter { !$0.parameters.reliable }.count, 2)
        }
    }

    func testSmallLatencyDifferenceWithinRepeatVariationDoesNotDecideTransport() throws {
        var search = AdaptiveCalibrationSearch(goal: 2, maximum: 300, reserve: 11)
        for index in 0..<4 {
            let p = try XCTUnwrap(search.next())
            var m = measurement(p)
            m.ageP95Milliseconds = [114, 110, 113, 112][index]
            search.record(p, measurement: m, validation: false)
        }
        // Both meet the goal, and their ranges overlap: retain the existing default.
        XCTAssertFalse(try XCTUnwrap(search.next()).reliable)
    }

    func testInvalidClockCannotGenerateRecommendation() throws {
        var search = AdaptiveCalibrationSearch(goal: 2, maximum: 300, reserve: 11)
        for _ in 0..<4 {
            let p = try XCTUnwrap(search.next())
            search.record(p, measurement: measurement(p, valid: false), validation: false)
        }
        XCTAssertNil(search.next())
        XCTAssertNil(search.selected)
    }

    func testConfirmedRecommendationAppliesAllNetworkParametersWithoutChangingUSB() throws {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let p = AdaptiveParameters(reliable: true, format: try AudioStreamFormat(opus: true, bitrate: 192_000, frameCount: 480),
            budget: CalibrationBudget(target: 95, maximum: 150), reserve: 11)
        defaults.set("pcm", forKey: "hearport.usbAudio.codec")
        let observed = AdaptiveObservation(parameters: p, measurement: measurement(p), validation: true)
        let result = AdaptiveCalibrationResult(testedAt: Date(), goal: 2, maximum: 300,
            observations: [observed,observed], selected: p, complete: true)
        XCTAssertTrue(result.apply(to: defaults))
        XCTAssertEqual(AudioStreamFormat.load(usb: false, defaults: defaults), p.format)
        XCTAssertEqual(AudioStreamFormat.load(usb: true, defaults: defaults), .pcm)
        XCTAssertEqual(defaults.integer(forKey: "hearport.targetLatencyMs"), 95)
        result.save(to: defaults)
        XCTAssertTrue(try XCTUnwrap(AdaptiveCalibrationResult.load(from: defaults)).canApply)
        let partial = AdaptiveCalibrationResult(testedAt: Date(), goal: 2, maximum: 300,
            observations: [observed], selected: p, complete: true)
        XCTAssertFalse(partial.canApply)
    }

    func testStabilityFirstCanApplyBestObservedSettingsWithNonzeroGaps() throws {
        let p = AdaptiveParameters(reliable: true, format: try AudioStreamFormat(opus: true),
            budget: CalibrationBudget(target: 200, maximum: 300), reserve: 11)
        let observation = AdaptiveObservation(parameters: p, measurement: measurement(p, ratio: 0.01), validation: true)
        let result = AdaptiveCalibrationResult(testedAt: Date(), goal: 4, maximum: 300,
            observations: [observation,observation], selected: p, complete: true)
        XCTAssertTrue(result.canApply)
        var progress = CalibrationProgressSnapshot(stage: "adaptive", index: 1, count: 16, completed: 0, total: 0,
            seconds: 15, roundStartedAt: 1_000_000_000)
        progress.baseSeconds = 15; progress.minimumWindows = 6; progress.maximumWindows = 14
        XCTAssertEqual(progress.adaptiveRemainingSeconds(at: 6_000_000_000), 133...277)
    }

    func testVariablePacketsExpandIntoSourceUnitsAndFinishObservation() throws {
        var setup = CalibrationMessage(kind: .setup, planID: 7)
        setup.goal = 2; setup.seconds = 15; setup.budget = CalibrationBudget(target: 0, maximum: 300)
        let session = AdaptiveCalibrationSession(setup: setup, reserve: 11)
        let selection = session.next(at: 1_000_000_000)
        let choice = try XCTUnwrap(selection.choices.first)
        var round = CalibrationMessage(kind: .round, planID: 7)
        round.goal = 2; round.index = 1; round.count = 16; round.profileMask = 2
        round.seconds = 15; round.format = selection.format; round.budget = choice.budget
        round.outputReserve = 11; round.generation = 1
        _ = try session.begin(round, at: 1_000_000_000)
        for step in 0..<3200 {
            let now = UInt64(1_000_000_000 + step * 5_000_000)
            if step < 3000 {
                let record = try TimedAudioRecord(streamID: 7, generation: 1, sequence: UInt32(step * 2),
                    frameCount: 240, kind: .probe, capturedAt: now - 5_000_000,
                    sourceFrame: UInt64(step * 240), payload: Data(repeating: 1, count: 160))
                session.receive(record, captured: record.capturedAt, uncertainty: 0, at: now)
            }
            session.tick(at: now, uncertainty: 0)
        }
        let progress = session.progress()
        XCTAssertEqual(progress.receivedPackets, 3000)
        XCTAssertTrue(progress.adaptive)
        _ = session.next(at: 17_000_000_000)
        let result = session.result(complete: false)
        XCTAssertEqual(result.observations.count, 1)
        XCTAssertTrue(try XCTUnwrap(result.observations.first).measurement.valid)
        XCTAssertFalse(result.canApply)
    }
}
