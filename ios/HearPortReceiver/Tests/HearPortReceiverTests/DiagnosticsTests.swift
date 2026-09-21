import Foundation
import XCTest
@testable import HearPortReceiver

final class DiagnosticsTests: XCTestCase {
    func testLogRedactsSensitiveFieldsAndKeepsSafeMetadata() throws {
        let diagnostics = try makeDiagnostics()
        diagnostics.level = .debug
        diagnostics.log(
            .debug,
            category: .pairing,
            message: "pair attempt",
            fields: [
                "pin": "123456",
                "spake_scalar": "scalar-value",
                "bytes": "65",
                "stream_id": "7"
            ]
        )

        let exported = try String(contentsOf: diagnostics.export(), encoding: .utf8)

        XCTAssertFalse(exported.contains("123456"))
        XCTAssertFalse(exported.contains("scalar-value"))
        XCTAssertTrue(exported.contains("bytes=65"))
        XCTAssertTrue(exported.contains("stream_id=7"))
    }

    func testRotationAndRecentTailStayBounded() throws {
        let diagnostics = try makeDiagnostics(maxFileBytes: 180, maxRotatedFiles: 2)
        for index in 0..<40 {
            diagnostics.log(
                .info,
                category: .realtime,
                message: "packet",
                fields: ["sequence": "\(index)"]
            )
        }

        let snapshot = diagnostics.snapshot()
        XCTAssertLessThanOrEqual(snapshot.activeBytes, 180)
        XCTAssertLessThanOrEqual(snapshot.rotatedFileCount, 2)
        XCTAssertEqual(diagnostics.recentLines(limit: 1).count, 1)
    }

    func testClearRemovesRetainedDiagnostics() throws {
        let diagnostics = try makeDiagnostics()
        diagnostics.log(.error, category: .app, message: "failure")
        XCTAssertGreaterThan(diagnostics.snapshot().entryCount, 0)

        try diagnostics.clear()

        XCTAssertEqual(diagnostics.snapshot().entryCount, 0)
        XCTAssertEqual(diagnostics.snapshot().activeBytes, 0)
    }

    func testReceiverDiagnosticsCaptureSafeAudioAndLifecycleMetadata() throws {
        let diagnostics = try makeDiagnostics()
        diagnostics.level = .debug
        let receiver = HearPortReceiver(
            startupPackets: 1,
            renderCapacityFrames: AudioDatagram.framesPerPacket,
            diagnostics: diagnostics
        )

        XCTAssertTrue(receiver.session.receiveConnect(authMode: .oneTime, peerID: Data()))
        XCTAssertTrue(receiver.markAuthenticated())
        XCTAssertTrue(receiver.beginStream(7))
        XCTAssertTrue(receiver.acknowledgeStartStream(7))
        let packet = try AudioDatagram(
            streamID: 7,
            sequence: 0,
            pcm: Data(repeating: 0xa5, count: AudioDatagram.pcmByteCount)
        )
        XCTAssertEqual(receiver.receiveDatagram(packet.encoded), .accepted)
        _ = receiver.renderFrames(AudioDatagram.framesPerPacket)
        receiver.handleAudioLifecycle(.routeChanged)

        let exported = try String(contentsOf: diagnostics.export(), encoding: .utf8)
        XCTAssertTrue(exported.contains("[realtime]"))
        XCTAssertTrue(exported.contains("[audio]"))
        XCTAssertTrue(exported.contains("event=datagram_received"))
        XCTAssertTrue(exported.contains("stream_id=7"))
        XCTAssertTrue(exported.contains("sequence=0"))
        XCTAssertTrue(exported.contains("audio_bytes=960"))
        XCTAssertTrue(exported.contains("event=route_changed"))
        XCTAssertFalse(exported.contains("a5a5a5"))
    }

    func testControlMessagesExposeStableSafeDiagnosticNames() {
        XCTAssertEqual(
            ControlEnvelope(.startStreamAck(7)).message.diagnosticName,
            "start_stream_ack"
        )
        XCTAssertEqual(
            ControlEnvelope(.error(code: .authFailed, message: "secret")).message.diagnosticName,
            "error"
        )
    }

    private func makeDiagnostics(
        maxFileBytes: Int = 4_096,
        maxRotatedFiles: Int = 3
    ) throws -> HearPortDiagnostics {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HearPortDiagnosticsTests-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return HearPortDiagnostics(
            directory: directory,
            maxFileBytes: maxFileBytes,
            maxRotatedFiles: maxRotatedFiles
        )
    }
}
