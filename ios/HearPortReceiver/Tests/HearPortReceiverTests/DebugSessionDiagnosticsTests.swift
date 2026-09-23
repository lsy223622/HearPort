import Foundation
import XCTest
@testable import HearPortReceiver

final class DebugSessionDiagnosticsTests: XCTestCase {
    func testPacketTraceIsBoundedAndContainsSafeMetadataOnly() throws {
        let directory = try temporaryDirectory("DebugSessionTrace")
        let logs = directory.appendingPathComponent("logs", isDirectory: true)
        let reportDirectory = directory.appendingPathComponent("reports", isDirectory: true)
        let diagnostics = HearPortDiagnostics(directory: logs)
        let transfer = DebugReportTransfer(directory: reportDirectory)
        let capture = DebugSessionDiagnostics(
            capacity: 2,
            bufferTargetPackets: 16,
            reportTransfer: transfer,
            diagnostics: diagnostics
        )
        let sessionID = Data((0..<16).map { UInt8($0) })

        capture.begin(sessionID: sessionID, streamID: 7, durationSeconds: 300)
        for sequence in 10..<13 {
            capture.recordPacket(
                streamID: 7,
                sequence: UInt32(sequence),
                receivedAt: UInt64(sequence) * 1_000_000,
                disposition: .accepted,
                jitterResult: .inserted,
                fillPackets: sequence - 9
            )
        }

        let reportURL = try capture.finish(reason: "duration_expired", diagnostics: diagnostics)
        let report = try String(contentsOf: reportURL, encoding: .utf8)

        XCTAssertTrue(report.contains("format_version=1"))
        XCTAssertTrue(report.contains("session_id=000102030405060708090a0b0c0d0e0f"))
        XCTAssertTrue(report.contains("stream_id=7"))
        XCTAssertTrue(report.contains("duration_seconds=300"))
        XCTAssertTrue(report.contains("buffer_target_packets=16"))
        XCTAssertTrue(report.contains("end_reason=duration_expired"))
        XCTAssertTrue(report.contains("trace_records=2"))
        XCTAssertTrue(report.contains("trace_dropped=1"))
        XCTAssertTrue(report.contains("received_at_ns\tstream_id\tsequence\tdisposition\tjitter_result\tfill_packets"))
        XCTAssertTrue(report.contains("10000000\t7\t10\taccepted\tinserted\t1"))
        XCTAssertTrue(report.contains("11000000\t7\t11\taccepted\tinserted\t2"))
        XCTAssertFalse(report.contains("12\taccepted"))
        XCTAssertFalse(report.contains("AudioDatagram.pcm"))
        XCTAssertFalse(report.contains("a5a5a5"))
        XCTAssertNotNil(try transfer.pendingReport())
    }

    func testDisconnectPersistsPartialReportForLaterUpload() throws {
        let directory = try temporaryDirectory("DebugSessionPartial")
        let diagnostics = HearPortDiagnostics(directory: directory.appendingPathComponent("logs"))
        let transfer = DebugReportTransfer(directory: directory.appendingPathComponent("reports"))
        let capture = DebugSessionDiagnostics(
            capacity: 4,
            bufferTargetPackets: 8,
            reportTransfer: transfer,
            diagnostics: diagnostics
        )
        let sessionID = Data(repeating: 0x42, count: 16)
        capture.begin(sessionID: sessionID, streamID: 9, durationSeconds: 300)
        capture.recordPacket(
            streamID: 9,
            sequence: 3,
            receivedAt: 123_456,
            disposition: .oldStreamDiscarded,
            jitterResult: nil,
            fillPackets: 0
        )

        let reportURL = try capture.persistPartial(reason: "connection_lost")
        let report = try String(contentsOf: reportURL, encoding: .utf8)

        XCTAssertTrue(report.contains("end_reason=connection_lost"))
        XCTAssertTrue(report.contains("trace_records=1"))
        XCTAssertNotNil(try transfer.pendingReport())
    }

    private func temporaryDirectory(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
