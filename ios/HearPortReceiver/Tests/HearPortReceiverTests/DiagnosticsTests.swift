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

    func testExportIncludesSafeEnvironmentSummary() throws {
        let diagnostics = try makeDiagnostics()

        let exported = try String(contentsOf: diagnostics.export(), encoding: .utf8)

        XCTAssertTrue(exported.contains("Environment:"))
        XCTAssertTrue(exported.contains("platform="))
        XCTAssertTrue(exported.contains("os_version="))
        XCTAssertTrue(exported.contains("app_version="))
    }

    func testReceiverDiagnosticsCaptureSafeAudioAndLifecycleMetadata() throws {
        let diagnostics = try makeDiagnostics()
        diagnostics.level = .debug
        let receiver = HearPortReceiver(
            bufferTargetPackets: 1,
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

    func testAsyncEntriesDrainBeforeExportAndRemainRedacted() throws {
        let diagnostics = try makeDiagnostics(asyncQueueCapacity: 4)
        diagnostics.level = .debug

        XCTAssertTrue(diagnostics.logAsync(
            .debug,
            category: .realtime,
            message: "async packet summary",
            fields: ["pin": "123456", "stream_id": "7", "packets": "400"]
        ))
        XCTAssertTrue(diagnostics.flushAsync(timeout: 1.0))

        let exported = try String(contentsOf: diagnostics.export(), encoding: .utf8)
        XCTAssertFalse(exported.contains("123456"))
        XCTAssertTrue(exported.contains("stream_id=7"))
        XCTAssertTrue(exported.contains("packets=400"))
    }

    func testBoundedAsyncQueueDropsWithoutBlocking() throws {
        let queue = DiagnosticsAsyncQueue<Int>(capacity: 1)
        XCTAssertTrue(queue.tryEnqueue(1))
        XCTAssertFalse(queue.tryEnqueue(2))
        XCTAssertEqual(queue.droppedCount, 1)
        XCTAssertEqual(queue.dequeue(), 1)
    }

    func testAtomicCounterExchangesIntervalValue() {
        let counter = AtomicUInt64(3)
        XCTAssertEqual(counter.increment(by: 4), 7)
        XCTAssertEqual(counter.exchange(0), 7)
        XCTAssertEqual(counter.load(), 0)
    }

    private func makeDiagnostics(
        maxFileBytes: Int = 4_096,
        maxRotatedFiles: Int = 3,
        asyncQueueCapacity: Int = 512
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
            maxRotatedFiles: maxRotatedFiles,
            asyncQueueCapacity: asyncQueueCapacity
        )
    }
}
