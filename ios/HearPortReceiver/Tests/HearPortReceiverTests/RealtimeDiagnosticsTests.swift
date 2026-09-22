import Foundation
import XCTest
@testable import HearPortReceiver

final class RealtimeDiagnosticsTests: XCTestCase {
    func testJitterConfigurationSupportsAllSixTargets() {
        XCTAssertEqual(
            JitterBufferConfiguration.supportedTargetPacketCounts.map {
                JitterBufferConfiguration(targetPackets: $0).targetLatencyMilliseconds
            },
            [10, 20, 40, 80, 160, 320]
        )
    }

    func testInvalidJitterConfigurationFallsBackToBalanced() {
        XCTAssertEqual(JitterBufferConfiguration(targetPackets: 0).targetPackets, 8)
        XCTAssertEqual(JitterBufferConfiguration(targetPackets: 129).targetPackets, 8)
    }

    func testJitterBuffer128PacketTargetRemainsBounded() throws {
        var jitter = JitterBuffer(
            streamID: 1,
            configuration: JitterBufferConfiguration(targetPackets: 128),
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
        XCTAssertLessThanOrEqual(jitter.fillPackets, 128)

        for sequence in 128..<136 {
            let packet = try AudioDatagram(
                streamID: 1,
                sequence: UInt32(sequence),
                pcm: pcm
            )
            XCTAssertEqual(jitter.insert(packet), .inserted)
            XCTAssertEqual(jitter.fillPackets, 128)
        }
        XCTAssertEqual(jitter.expectedSequence, UInt32(8))
        XCTAssertEqual(jitter.consumeNext()?.sequence, UInt32(8))
        XCTAssertEqual(jitter.stats.trimmedPackets, 8)
        XCTAssertEqual(jitter.stats.capacityDrops, 0)
    }

    func testRunningJitterBufferKeepsNewestPacketsAtItsTarget() throws {
        var jitter = JitterBuffer(streamID: 1, targetPackets: 2, maximumPackets: 4)
        let pcm = Data(repeating: 0, count: AudioDatagram.pcmByteCount)
        for sequence in 0..<2 {
            let packet = try AudioDatagram(
                streamID: 1,
                sequence: UInt32(sequence),
                pcm: pcm
            )
            XCTAssertEqual(jitter.insert(packet), .inserted)
        }
        XCTAssertTrue(jitter.startIfReady())

        let nextPacket = try AudioDatagram(streamID: 1, sequence: 2, pcm: pcm)
        XCTAssertEqual(jitter.insert(nextPacket), .inserted)

        XCTAssertEqual(jitter.fillPackets, 2)
        XCTAssertEqual(jitter.expectedSequence, UInt32(1))
        XCTAssertEqual(jitter.consumeNext()?.sequence, UInt32(1))
        XCTAssertEqual(jitter.stats.trimmedPackets, 1)
    }

    func testRunningJitterBufferCanTrimAtItsMaximumCapacity() throws {
        var jitter = JitterBuffer(streamID: 1, targetPackets: 2, maximumPackets: 2)
        let pcm = Data(repeating: 0, count: AudioDatagram.pcmByteCount)
        for sequence in 0..<2 {
            let packet = try AudioDatagram(
                streamID: 1,
                sequence: UInt32(sequence),
                pcm: pcm
            )
            XCTAssertEqual(jitter.insert(packet), .inserted)
        }
        XCTAssertTrue(jitter.startIfReady())

        let nextPacket = try AudioDatagram(streamID: 1, sequence: 2, pcm: pcm)
        XCTAssertEqual(jitter.insert(nextPacket), .inserted)

        XCTAssertEqual(jitter.fillPackets, 2)
        XCTAssertEqual(jitter.expectedSequence, UInt32(1))
        XCTAssertEqual(jitter.consumeNext()?.sequence, UInt32(1))
        XCTAssertEqual(jitter.stats.capacityDrops, 0)
        XCTAssertEqual(jitter.stats.trimmedPackets, 1)
    }

    func testRunningJitterBufferTrimsOldestPacketAcrossSequenceWrap() throws {
        var jitter = JitterBuffer(streamID: 1, targetPackets: 2)
        let pcm = Data(repeating: 0, count: AudioDatagram.pcmByteCount)
        for sequence in [UInt32.max - 1, UInt32.max] {
            let packet = try AudioDatagram(streamID: 1, sequence: sequence, pcm: pcm)
            XCTAssertEqual(jitter.insert(packet), .inserted)
        }
        XCTAssertTrue(jitter.startIfReady())

        let wrappedPacket = try AudioDatagram(streamID: 1, sequence: 0, pcm: pcm)
        XCTAssertEqual(jitter.insert(wrappedPacket), .inserted)

        XCTAssertEqual(jitter.fillPackets, 2)
        XCTAssertEqual(jitter.expectedSequence, UInt32.max)
        XCTAssertEqual(jitter.consumeNext()?.sequence, UInt32.max)
        XCTAssertEqual(jitter.stats.trimmedPackets, 1)
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
            bufferTargetPackets: 4,
            renderCapacityFrames: AudioDatagram.framesPerPacket,
            diagnostics: diagnostics
        )

        XCTAssertTrue(receiver.beginAuthentication(authMode: .oneTime, peerID: Data()))
        XCTAssertTrue(receiver.markAuthenticated())
        XCTAssertTrue(receiver.beginStream(7))
        XCTAssertTrue(receiver.acknowledgeStartStream(7))
        for sequence in 0..<5 {
            let packet = try AudioDatagram(
                streamID: 7,
                sequence: UInt32(sequence),
                pcm: Data(repeating: 0xa5, count: AudioDatagram.pcmByteCount)
            )
            XCTAssertEqual(receiver.receiveDatagram(packet.encoded), .accepted)
        }
        _ = receiver.renderFrames(AudioDatagram.framesPerPacket)

        receiver.emitRealtimeDiagnosticsForTesting()
        XCTAssertTrue(diagnostics.flushAsync(timeout: 1.0))
        let exported = try String(contentsOf: diagnostics.export(), encoding: .utf8)

        XCTAssertTrue(exported.contains("event=realtime_summary"))
        XCTAssertTrue(exported.contains("jitter_target_packets=4"))
        XCTAssertTrue(exported.contains("jitter_fill_packets="))
        XCTAssertTrue(exported.contains("buffer_trimmed_packets=1"))
        XCTAssertTrue(exported.contains("render_fill_frames="))
        XCTAssertTrue(exported.contains("render_underflow_frames="))
        XCTAssertTrue(exported.contains("last_sequence=4"))
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

    func testReceiverBufferTargetFramesMatchSelectedPacketCount() {
        let receiver = HearPortReceiver(bufferTargetPackets: 128)

        XCTAssertEqual(receiver.jitterTargetFrames, 128 * AudioDatagram.framesPerPacket)
    }
}
