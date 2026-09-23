import Foundation
import XCTest
@testable import HearPortReceiver

final class DebugReportTransferTests: XCTestCase {
    func testChunksPreserveOrderAndOnlyMatchingAcknowledgementDeletesReport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugReportTransfer-\(UUID().uuidString)", isDirectory: true)
        let transfer = DebugReportTransfer(directory: directory)
        let sessionID = Data((0..<16).map { UInt8($0) })
        let report = Data((0..<31).map { UInt8($0) })

        _ = try transfer.store(sessionID: sessionID, formatVersion: 1, data: report)

        let chunks = try transfer.makeChunks(maxBytes: 7)
        XCTAssertEqual(chunks.count, 5)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 7 })
        XCTAssertEqual(Data(chunks.flatMap { Array($0) }), report)
        XCTAssertEqual(try transfer.pendingReport()?.sessionID, sessionID)

        XCTAssertThrowsError(try transfer.acknowledge(sessionID: Data(repeating: 0xff, count: 16)))
        XCTAssertNotNil(try transfer.pendingReport())

        try transfer.acknowledge(sessionID: sessionID)
        XCTAssertNil(try transfer.pendingReport())
    }

    func testTransferRetainsOnlyOneBoundedPendingReport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugReportBounds-\(UUID().uuidString)", isDirectory: true)
        let transfer = DebugReportTransfer(directory: directory, maximumReportBytes: 8)
        _ = try transfer.store(
            sessionID: Data(repeating: 1, count: 16),
            formatVersion: 1,
            data: Data(repeating: 0x11, count: 8)
        )

        XCTAssertThrowsError(try transfer.store(
            sessionID: Data(repeating: 2, count: 16),
            formatVersion: 1,
            data: Data([0x22])
        ))
        XCTAssertThrowsError(try transfer.store(
            sessionID: Data(repeating: 3, count: 16),
            formatVersion: 1,
            data: Data(repeating: 0x33, count: 9)
        ))
        XCTAssertEqual(try transfer.pendingReport()?.sessionID, Data(repeating: 1, count: 16))
    }
}
