import XCTest
@testable import HearPortReceiver

final class RepairWindowTests: XCTestCase {
    func testParityRestoresExactlyOneMissingSourceAndRejectsLateRepair() throws {
        let records = try (0..<4).map { value in
            try TimedAudioRecord(streamID: 7, generation: 1, sequence: UInt32(value),
                frameCount: 120, kind: .audio, capturedAt: 1_000_000_000 + UInt64(value) * 2_500_000,
                sourceFrame: UInt64(value) * 120, payload: Data(repeating: UInt8(value + 1), count: 960))
        }
        var parity = Data(repeating: 0, count: 992)
        for record in records { for index in 0..<992 { parity[index] ^= record.encoded[index] } }
        let fec = try TimedAudioRecord(streamID: 7, generation: 1, sequence: 0, frameCount: 4,
            kind: .fec, capturedAt: 1_000_000_000, sourceFrame: 0, payload: parity)
        for missing in 0..<4 {
            var window = RepairWindow()
            for index in 0..<4 where index != missing {
                XCTAssertTrue(window.ingest(records[index], deadline: 1_100_000_000,
                    now: 1_050_000_000).isEmpty)
            }
            let restored = window.ingest(fec, deadline: 1_100_000_000, now: 1_050_000_000)
            XCTAssertEqual(restored.count, 1)
            XCTAssertEqual(restored.first?.sequence, UInt32(missing))
            XCTAssertEqual(restored.first?.payload, records[missing].payload)
            XCTAssertTrue(window.ingest(fec, deadline: 1_100_000_000, now: 1_050_000_000).isEmpty)
        }
        var late = RepairWindow()
        for record in records.dropFirst() { _ = late.ingest(record, deadline: 1_100_000_000, now: 1_050_000_000) }
        XCTAssertTrue(late.ingest(fec, deadline: 1_100_000_000, now: 1_100_000_000).isEmpty)
    }

    func testSelectiveRequestWaitsForReorderingAndRunsOnlyOnce() {
        var window = RepairWindow()
        XCTAssertFalse(window.shouldRequest(sequence: 3, now: 1_000_000_000,
            deadline: 1_100_000_000, roundTripNanoseconds: 10_000_000))
        XCTAssertTrue(window.shouldRequest(sequence: 3, now: 1_010_000_000,
            deadline: 1_100_000_000, roundTripNanoseconds: 10_000_000))
        XCTAssertFalse(window.shouldRequest(sequence: 3, now: 1_020_000_000,
            deadline: 1_100_000_000, roundTripNanoseconds: 10_000_000))
        XCTAssertFalse(window.shouldRequest(sequence: 4, now: 1_100_000_000,
            deadline: 1_100_000_000, roundTripNanoseconds: 10_000_000))
    }
}
