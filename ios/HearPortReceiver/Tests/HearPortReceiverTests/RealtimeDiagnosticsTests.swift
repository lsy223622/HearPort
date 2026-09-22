import Foundation
import XCTest
@testable import HearPortReceiver

final class RealtimeDiagnosticsTests: XCTestCase {
    func testJitterConfigurationSupportsAllSixTargets() {
        XCTAssertEqual(
            JitterBufferConfiguration.supportedStartupPacketCounts.map {
                JitterBufferConfiguration(startupPackets: $0).startupLatencyMilliseconds
            },
            [10, 20, 40, 80, 160, 320]
        )
    }

    func testInvalidJitterConfigurationFallsBackToBalanced() {
        XCTAssertEqual(JitterBufferConfiguration(startupPackets: 0).startupPackets, 8)
        XCTAssertEqual(JitterBufferConfiguration(startupPackets: 129).startupPackets, 8)
    }

    func testJitterBuffer128PacketTargetRemainsBounded() throws {
        var jitter = JitterBuffer(
            streamID: 1,
            configuration: JitterBufferConfiguration(startupPackets: 128),
            maximumPackets: 256
        )
        let pcm = Data(repeating: 0, count: AudioDatagram.pcmByteCount)
        for sequence in 0..<127 {
            let packet = try AudioDatagram(
                streamID: 1,
                sequence: UInt32(sequence),
                pcm: pcm
            )
            XCTAssertEqual(jitter.insert(packet), .inserted)
        }
        XCTAssertFalse(jitter.startIfReady())
        let finalPacket = try AudioDatagram(streamID: 1, sequence: 127, pcm: pcm)
        XCTAssertEqual(jitter.insert(finalPacket), .inserted)
        XCTAssertTrue(jitter.startIfReady())
        XCTAssertEqual(jitter.fillPackets, 128)
        XCTAssertLessThanOrEqual(jitter.fillPackets, 256)
    }

    func testReceiverRealtimeSummaryContainsSafeTransportAndBufferFields() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HearPortRealtimeMetrics-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        let diagnostics = HearPortDiagnostics(directory: directory)
        diagnostics.level = .debug
        let receiver = HearPortReceiver(
            startupPackets: 4,
            renderCapacityFrames: AudioDatagram.framesPerPacket,
            diagnostics: diagnostics
        )

        XCTAssertTrue(receiver.beginAuthentication(authMode: .oneTime, peerID: Data()))
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

        receiver.emitRealtimeDiagnosticsForTesting()
        XCTAssertTrue(diagnostics.flushAsync(timeout: 1.0))
        let exported = try String(contentsOf: diagnostics.export(), encoding: .utf8)

        XCTAssertTrue(exported.contains("event=realtime_summary"))
        XCTAssertTrue(exported.contains("jitter_target_packets=4"))
        XCTAssertTrue(exported.contains("jitter_fill_packets="))
        XCTAssertTrue(exported.contains("render_fill_frames="))
        XCTAssertTrue(exported.contains("render_underflow_frames="))
        XCTAssertTrue(exported.contains("last_sequence=0"))
        XCTAssertFalse(exported.contains("a5a5a5"))
    }

    func testReceiverRealtimeSummaryContainsRenderConversionMetrics() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HearPortRenderMetrics-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        let diagnostics = HearPortDiagnostics(directory: directory)
        diagnostics.level = .debug
        let receiver = HearPortReceiver(diagnostics: diagnostics)

        XCTAssertTrue(receiver.beginAuthentication(authMode: .oneTime, peerID: Data()))
        XCTAssertTrue(receiver.markAuthenticated())
        XCTAssertTrue(receiver.beginStream(9))
        XCTAssertTrue(receiver.acknowledgeStartStream(9))
        receiver.recordRenderCallback(
            requestedFrames: 480,
            renderedFrames: 480,
            fillFrames: 720,
            resamplerRatio: 1.0002,
            fillError: -240
        )

        receiver.emitRealtimeDiagnosticsForTesting()
        XCTAssertTrue(diagnostics.flushAsync(timeout: 1.0))
        let exported = try String(contentsOf: diagnostics.export(), encoding: .utf8)

        XCTAssertTrue(exported.contains("render_callbacks=1"))
        XCTAssertTrue(exported.contains("rendered_frames=480"))
        XCTAssertTrue(exported.contains("render_fill_frames=720"))
        XCTAssertTrue(exported.contains("resampler_ratio=1.0002"))
        XCTAssertTrue(exported.contains("drift_fill_error=-240.0"))
    }
}
