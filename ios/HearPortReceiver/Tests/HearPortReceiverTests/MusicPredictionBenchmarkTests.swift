import XCTest
@testable import HearPortReceiver

final class MusicPredictionBenchmarkTests: XCTestCase {
    func testMeasurementIncludesWorkerQueueReturnAndAllWorkloads() async throws {
        let report = try await MusicPredictionBenchmark.run()
        XCTAssertEqual(report.cases.count, 4)
        for item in report.cases {
            XCTAssertTrue([120, 480].contains(item.frames))
            let counts = Dictionary(grouping: item.measurements, by: \.phase).mapValues(\.count)
            XCTAssertEqual(counts, ["first": 1, "warm": 200, "consecutive": 80, "idle100": 5, "idle1000": 3])
            for sample in item.measurements {
                XCTAssertGreaterThan(sample.computeMilliseconds, 0)
                XCTAssertGreaterThanOrEqual(sample.queueMilliseconds, 0)
                XCTAssertGreaterThanOrEqual(sample.totalMilliseconds + 0.000001,
                                            sample.queueMilliseconds + sample.computeMilliseconds)
                XCTAssertTrue(sample.checksum.isFinite)
            }
        }
        let data = try JSONEncoder().encode(report)
        XCTAssertEqual(try JSONDecoder().decode(MusicPredictionBenchmarkReport.self, from: data).cases.count, 4)
    }
}
