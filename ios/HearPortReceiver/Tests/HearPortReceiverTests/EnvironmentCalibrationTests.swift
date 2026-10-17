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

    func testCalibrationRequestMatchesSharedFixtureAndValidatesBounds() throws {
        var request = CalibrationMessage(kind: .request, planID: 0x01020304)
        request.budget = CalibrationBudget(target: 0, maximum: 300)
        let fixture = Data([4,6,1,2,3,4,0,30,1,44])
        XCTAssertEqual(try request.encoded(), fixture)
        XCTAssertEqual(try CalibrationMessage(encoded: fixture), request)
        for seconds in [30,60,120] {
            for maximum in [20,2000] {
                request.seconds = seconds
                request.budget = CalibrationBudget(target: 0, maximum: maximum)
                XCTAssertEqual(try CalibrationMessage(encoded: request.encoded()), request)
            }
        }
        for seconds in [-1,0,29,31,65536] {
            request.seconds = seconds
            XCTAssertThrowsError(try request.encoded())
        }
        request.seconds = 30
        for maximum in [-1,0,19,2001,65536] {
            request.budget = CalibrationBudget(target: 0, maximum: maximum)
            XCTAssertThrowsError(try request.encoded())
        }
        for count in 0..<fixture.count {
            XCTAssertThrowsError(try CalibrationMessage(encoded: fixture.prefix(count)))
        }
        XCTAssertThrowsError(try CalibrationMessage(encoded: fixture + Data([0])))
        for (offset, bytes) in [(1, [UInt8(7)]), (2, [0,0,0,0]), (6, [0,31]), (8, [0,19]), (8, [7,209])] {
            var invalid = fixture
            invalid.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
            XCTAssertThrowsError(try CalibrationMessage(encoded: invalid))
        }
    }
}
