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

        _ = try capture.finish(reason: "duration_expired", diagnostics: diagnostics)
        let pendingReport = try XCTUnwrap(transfer.pendingReport())
        let report = try XCTUnwrap(String(data: pendingReport.data, encoding: .utf8))

        XCTAssertTrue(report.contains("format_version=1"))
        XCTAssertTrue(report.contains("session_id=000102030405060708090a0b0c0d0e0f"))
        XCTAssertTrue(report.contains("stream_id=7"))
        XCTAssertTrue(report.contains("duration_seconds=300"))
        XCTAssertTrue(report.contains("app_build_id="))
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

        _ = try capture.persistPartial(reason: "connection_lost")
        let pendingReport = try XCTUnwrap(transfer.pendingReport())
        let report = try XCTUnwrap(String(data: pendingReport.data, encoding: .utf8))

        XCTAssertTrue(report.contains("end_reason=connection_lost"))
        XCTAssertTrue(report.contains("trace_records=1"))
    }

    func testJitterDecisionTraceRecordsExactConcealedAndTrimmedSequences() throws {
        let directory = try temporaryDirectory("DebugSessionJitterDecisions")
        let diagnostics = HearPortDiagnostics(directory: directory.appendingPathComponent("logs"))
        let transfer = DebugReportTransfer(directory: directory.appendingPathComponent("reports"))
        let capture = DebugSessionDiagnostics(
            capacity: 3,
            bufferTargetPackets: 8,
            reportTransfer: transfer,
            diagnostics: diagnostics
        )
        capture.begin(sessionID: Data(repeating: 0x33, count: 16),
                      streamID: 11,
                      durationSeconds: 60)
        capture.recordPacket(streamID: 11,
                             sequence: 39,
                             receivedAt: 23_456,
                             disposition: .accepted,
                             jitterResult: .inserted,
                             fillPackets: 4)
        capture.recordJitterDecision(
            streamID: 11,
            sequence: 40,
            decision: .concealed,
            at: 123_456,
            fillPackets: 3
        )
        capture.recordJitterDecision(
            streamID: 11,
            sequence: 41,
            decision: .trimmed,
            at: 223_456,
            fillPackets: 2
        )
        capture.recordJitterDecision(
            streamID: 11,
            sequence: 42,
            decision: .trimmed,
            at: 323_456,
            fillPackets: 2
        )

        _ = try capture.finish(reason: "duration_expired", diagnostics: diagnostics)
        let pendingReport = try XCTUnwrap(transfer.pendingReport())
        let report = try XCTUnwrap(String(data: pendingReport.data, encoding: .utf8))

        XCTAssertTrue(report.contains("jitter_decision_records=2"))
        XCTAssertTrue(report.contains("trace_records=1"))
        XCTAssertTrue(report.contains("trace_dropped=1"))
        XCTAssertTrue(report.contains("at_ns\tstream_id\tsequence\tdecision\tfill_packets"))
        XCTAssertTrue(report.contains("123456\t11\t40\tconcealed\t3"))
        XCTAssertTrue(report.contains("223456\t11\t41\ttrimmed\t2"))
    }

    func testReceiverTracesTrimmedAndConcealedSequenceNumbers() throws {
        let directory = try temporaryDirectory("DebugSessionReceiverJitterDecisions")
        let diagnostics = HearPortDiagnostics(directory: directory.appendingPathComponent("logs"))
        let transfer = DebugReportTransfer(directory: directory.appendingPathComponent("reports"))
        let capture = DebugSessionDiagnostics(
            capacity: 16,
            bufferTargetPackets: 4,
            reportTransfer: transfer,
            diagnostics: diagnostics
        )
        let receiver = HearPortReceiver(
            bufferTargetPackets: 4,
            renderCapacityFrames: AudioDatagram.framesPerPacket,
            diagnostics: diagnostics,
            debugSessionDiagnostics: capture
        )
        let sessionID = Data(repeating: 0x44, count: 16)
        let pcm = Data(repeating: 0, count: AudioDatagram.pcmByteCount)

        XCTAssertTrue(receiver.beginAuthentication(authMode: .oneTime, peerID: Data()))
        XCTAssertTrue(receiver.markAuthenticated())
        capture.begin(sessionID: sessionID, streamID: 12, durationSeconds: 60)
        XCTAssertTrue(receiver.beginStream(12))
        XCTAssertTrue(receiver.acknowledgeStartStream(12))
        for sequence in [UInt32(0), 1, 2, 3, 5] {
            let packet = try AudioDatagram(streamID: 12, sequence: sequence, pcm: pcm)
            XCTAssertEqual(receiver.receiveDatagram(packet.encoded), .accepted)
        }
        for _ in 0..<4 {
            _ = receiver.renderFrames(AudioDatagram.framesPerPacket)
        }

        _ = try capture.finish(reason: "duration_expired", diagnostics: diagnostics)
        let pendingReport = try XCTUnwrap(transfer.pendingReport())
        let report = try XCTUnwrap(String(data: pendingReport.data, encoding: .utf8))

        XCTAssertTrue(report.contains("jitter_decision_records=2"))
        XCTAssertTrue(report.contains("\t12\t0\ttrimmed\t"))
        XCTAssertTrue(report.contains("\t12\t4\tconcealed\t"))
    }

    func testReceiverAddsDecodedPacketAndJitterDispositionToCapture() throws {
        let directory = try temporaryDirectory("DebugSessionReceiver")
        let diagnostics = HearPortDiagnostics(directory: directory.appendingPathComponent("logs"))
        let transfer = DebugReportTransfer(directory: directory.appendingPathComponent("reports"))
        let capture = DebugSessionDiagnostics(
            capacity: 8,
            bufferTargetPackets: 1,
            reportTransfer: transfer,
            diagnostics: diagnostics
        )
        let receiver = HearPortReceiver(
            bufferTargetPackets: 1,
            diagnostics: diagnostics,
            debugSessionDiagnostics: capture
        )
        let sessionID = Data(repeating: 0x55, count: 16)
        let pcm = Data(repeating: 0xa5, count: AudioDatagram.pcmByteCount)

        XCTAssertTrue(receiver.beginAuthentication(authMode: .oneTime, peerID: Data()))
        XCTAssertTrue(receiver.markAuthenticated())
        capture.begin(sessionID: sessionID, streamID: 7, durationSeconds: 60)
        XCTAssertTrue(receiver.beginStream(7))
        XCTAssertTrue(receiver.acknowledgeStartStream(7))
        let packet = try AudioDatagram(streamID: 7, sequence: 10, pcm: pcm)
        XCTAssertEqual(receiver.receiveDatagram(packet.encoded), .accepted)
        XCTAssertEqual(receiver.receiveDatagram(packet.encoded), .accepted)

        _ = try capture.finish(reason: "duration_expired", diagnostics: diagnostics)
        let pendingReport = try XCTUnwrap(transfer.pendingReport())
        let report = try XCTUnwrap(String(data: pendingReport.data, encoding: .utf8))
        let packetRows = report.components(separatedBy: "\n")
            .filter { $0.contains("\t7\t10\t") }

        XCTAssertEqual(packetRows.count, 2)
        XCTAssertTrue(packetRows[0].contains("accepted\tinserted"))
        XCTAssertTrue(packetRows[1].contains("accepted\tduplicate"))
        XCTAssertFalse(report.contains("a5a5a5"))
    }

    private func temporaryDirectory(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
