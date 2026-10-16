import XCTest
@testable import HearPortReceiver

final class EnvironmentCalibrationReplayTests: XCTestCase {
    private func trace(drop: Range<Int>? = nil) throws -> CalibrationRoundTrace {
        var round = CalibrationMessage(kind: .round, planID: 7)
        round.index = 1; round.count = 4; round.generation = 1
        round.budget = CalibrationBudget(target: 50, maximum: 160); round.outputReserve = 11
        var packets: [CalibrationPacket] = []
        for sequence in 0..<12000 where !(drop?.contains(sequence) ?? false) {
            let capture = UInt64(1_000_000_000 + sequence * 2_500_000)
            packets.append(CalibrationPacket(receivedAt: capture + 10_000_000, capturedAt: capture,
                uncertainty: 0, sequence: UInt32(sequence), generation: 1, sourceFrame: UInt64(sequence * 120)))
        }
        let ticks = stride(from: UInt64(1_000_000_000), through: 31_200_000_000, by: 5_000_000)
            .map { CalibrationTick(at: $0, uncertainty: 0) }
        return CalibrationRoundTrace(round: round, packets: packets, ticks: ticks, endAt: 31_200_000_000)
    }

    func testSameInputFingerprintAndPermanentGapRemainAcrossBudgets() throws {
        let input = try trace(drop: 600..<616)
        let a = CalibrationReplay.evaluate(trace: input, budget: CalibrationBudget(target: 50, maximum: 100))
        let b = CalibrationReplay.evaluate(trace: input, budget: CalibrationBudget(target: 80, maximum: 160))
        XCTAssertEqual(a.inputFingerprint, b.inputFingerprint)
        let curve = [100,160].map { CalibrationReplay.coverage(trace: input, maximum: $0) }
        XCTAssertEqual(curve.map(\.unavailableSourceFrames), [1920,1920])
        XCTAssertEqual(curve.map(\.longestGapMilliseconds), [40,40])
    }

    func testUnobservedTailAndInvalidClockCannotCreateRecommendations() throws {
        var input = try trace()
        input.endAt = 3_100_000_000; input.complete = false
        input.packets = input.packets.filter { $0.capturedAt < 3_000_000_000 }
        let point = CalibrationReplay.coverage(trace: input, maximum: 100)
        XCTAssertLessThanOrEqual(point.observableFrames, 96_000)
        XCTAssertEqual(point.unavailableSourceFrames, 0)
        input.clockValid = false
        let measurement = CalibrationReplay.evaluate(trace: input, budget: CalibrationBudget(target: 50, maximum: 100))
        XCTAssertTrue(CalibrationSelector.select(measurements: [measurement]).isEmpty)
        input.packets = []
        XCTAssertEqual(CalibrationReplay.coverage(trace: input, maximum: 100).observableFrames, 0)
    }

    func testFutureArrivalsCannotChangeFirstBlock() throws {
        let input = try trace()
        var changed = input
        for i in changed.packets.indices where changed.packets[i].sourceFrame >= 20 * 48000 {
            changed.packets[i].receivedAt += 300_000_000
        }
        let budget = CalibrationBudget(target: 50, maximum: 100)
        let a = CalibrationReplay.evaluate(trace: input, budget: budget)
        let b = CalibrationReplay.evaluate(trace: changed, budget: budget)
        XCTAssertEqual(a.blocks.first, b.blocks.first)
        XCTAssertLessThan(a.missingSourceFrames, b.missingSourceFrames)
    }

    func testSelectorUsesVisibleTargetsAndMergesIdenticalRecommendations() {
        func observation(_ target: Int, ratio: Double, gap: Double, age: Double) -> CalibrationMeasurement {
            var m = CalibrationMeasurement(round: 0, reliable: false,
                budget: CalibrationBudget(target: target, maximum: target + 40), outputReserve: 11, inputFingerprint: "fixture")
            m.complete = true; m.clockValid = true; m.sampleCount = 2
            m.sourceFrames = 48000; m.missingSourceFrames = UInt64(ratio * 48000)
            m.outputSeconds = 1; m.missingOutputSeconds = ratio
            m.longestSourceGapMilliseconds = gap; m.ageP95Milliseconds = age; m.ages = [age]
            return m
        }
        let a = observation(30, ratio: 0.004, gap: 30, age: 35)
        let b = observation(60, ratio: 0.0008, gap: 15, age: 65)
        let c = observation(95, ratio: 0.0001, gap: 10, age: 100)
        let choices = CalibrationSelector.select(measurements: [a,b,c])
        XCTAssertEqual(choices.compactMap { $0.choice?.budget.target }, [30,60,95])
        let merged = CalibrationSelector.choices(from: CalibrationSelector.select(measurements: [c]))
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.profileMask, 7)
    }
}
