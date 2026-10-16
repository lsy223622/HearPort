import XCTest
@testable import HearPortReceiver

final class EnvironmentCalibrationTests: XCTestCase {
    func testCandidateBudgetsRespectReserveAndIncludeUserCeiling() {
        let budgets = calibrationBudgets(maximum: 95, outputReserve: 11)
        XCTAssertEqual(budgets.last?.maximum, 95)
        XCTAssertTrue(calibrationBudgets(maximum: 20, outputReserve: 20).isEmpty)
        for budget in budgets {
            XCTAssertEqual(budget.target % 5, 0)
            XCTAssertGreaterThan(budget.target, 11)
            XCTAssertLessThanOrEqual(budget.target + 5, budget.maximum)
        }
    }

    func testCalibrationMessageMatchesSharedFixtureAndRejectsTrailingBytes() throws {
        var setup = CalibrationMessage(kind: .setup, planID: 0x01020304)
        setup.seconds = 30; setup.budget = CalibrationBudget(target: 0, maximum: 100)
        let fixture = Data([4,0,1,2,3,4,0,30,0,100])
        XCTAssertEqual(try setup.encoded(), fixture)
        XCTAssertEqual(try CalibrationMessage(encoded: fixture), setup)
        XCTAssertThrowsError(try CalibrationMessage(encoded: fixture + Data([0])))
        for count in 0..<fixture.count {
            XCTAssertThrowsError(try CalibrationMessage(encoded: fixture.prefix(count)))
        }
    }

    func testRoundSelectionAndProgressRoundTrip() throws {
        var round = CalibrationMessage(kind: .round, planID: 7)
        round.phase = 1; round.index = 1; round.count = 2; round.profileMask = 7
        round.seconds = 30; round.reliable = true; round.budget = CalibrationBudget(target: 50, maximum: 100)
        round.outputReserve = 11; round.generation = 1; round.firstSequence = 12000
        round.firstSourceFrame = 1_440_000
        let bytes = try round.encoded()
        XCTAssertEqual(try CalibrationMessage(encoded: bytes), round)
        var invalid = bytes; invalid[11] = 1
        XCTAssertThrowsError(try CalibrationMessage(encoded: invalid))
        var selection = CalibrationMessage(kind: .selection, planID: 7)
        selection.choices = [CalibrationChoice(profileMask: 7, reliable: true, budget: round.budget, outputReserve: 11)]
        XCTAssertEqual(try CalibrationMessage(encoded: selection.encoded()), selection)
        var progress = CalibrationMessage(kind: .progress, planID: 7)
        progress.completed = 12; progress.total = 24
        XCTAssertEqual(try CalibrationMessage(encoded: progress.encoded()), progress)
        progress.completed = 25
        XCTAssertThrowsError(try progress.encoded())
    }
}
