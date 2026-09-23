import Foundation
import XCTest
@testable import HearPortReceiver

final class ReceiverCoreTests: XCTestCase {
    func testControlEnvelopeVectorsMatchCanonicalProtoFields() throws {
        let connect = ControlEnvelope(.connectRequest(authMode: .pair, peerID: Data(), features: 0))
        XCTAssertEqual(try connect.encoded(), Data([0x0a, 0x02, 0x08, 0x02]))
        XCTAssertEqual(try ControlEnvelope.decode(connect.encoded()), connect)

        let ack = ControlEnvelope(.startStreamAck(7))
        XCTAssertEqual(try ack.encoded(), Data([0xfa, 0x01, 0x02, 0x08, 0x07]))
        XCTAssertEqual(try ControlEnvelope.decode(ack.encoded()), ack)
    }

    func testControlEnvelopeIgnoresUnknownAndUsesLastScalarValue() throws {
        let withUnknown = Data([0x10, 0x01, 0x0a, 0x02, 0x08, 0x02])
        XCTAssertEqual(
            try ControlEnvelope.decode(withUnknown),
            ControlEnvelope(.connectRequest(authMode: .pair, peerID: Data(), features: 0))
        )

        let duplicate = Data([0x0a, 0x04, 0x08, 0x01, 0x08, 0x02])
        XCTAssertEqual(
            try ControlEnvelope.decode(duplicate),
            ControlEnvelope(.connectRequest(authMode: .pair, peerID: Data(), features: 0))
        )

        let wrongWireAfterValid = Data([0x0a, 0x02, 0x08, 0x02,
                                        0x09, 0x00, 0x00, 0x00, 0x00,
                                        0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(
            try ControlEnvelope.decode(wrongWireAfterValid),
            ControlEnvelope(.connectRequest(authMode: .pair, peerID: Data(), features: 0))
        )

        XCTAssertThrowsError(try ControlEnvelope.decode(Data([0xfa, 0x01, 0x02, 0x08, 0x00])))
    }

    func testDiagnosticControlMessagesRoundTripCanonicalBytes() throws {
        let sessionID = [UInt8](repeating: 0x11, count: 16)
        let connect = envelope(1, body: varintField(1, 2) + varintField(3, 1))
        let ready = envelope(2, body: varintField(1, 1))
        let receiverReady = envelope(32, body: [])
        let diagnosticsStart = envelope(
            33,
            body: bytesField(1, sessionID) + varintField(2, 7) + varintField(3, 60)
        )
        let diagnosticsEnd = envelope(
            34,
            body: bytesField(1, sessionID) + varintField(2, 1)
        )
        let reportStart = envelope(
            35,
            body: bytesField(1, sessionID) + varintField(2, 1) +
                varintField(3, 123) + varintField(4, 2)
        )
        let reportChunk = envelope(
            36,
            body: bytesField(1, sessionID) + varintField(2, 0) +
                bytesField(3, [0x61, 0x62, 0x63])
        )
        let reportEnd = envelope(37, body: bytesField(1, sessionID))
        let reportReceived = envelope(38, body: bytesField(1, sessionID))

        let vectors: [(Data, String)] = [
            (connect, "connect_request"),
            (ready, "session_ready"),
            (receiverReady, "receiver_ready"),
            (diagnosticsStart, "diagnostics_start"),
            (diagnosticsEnd, "diagnostics_end"),
            (reportStart, "diagnostics_report_start"),
            (reportChunk, "diagnostics_report_chunk"),
            (reportEnd, "diagnostics_report_end"),
            (reportReceived, "diagnostics_report_received")
        ]
        for (bytes, expectedName) in vectors {
            let decoded = try ControlEnvelope.decode(bytes)
            XCTAssertEqual(decoded.message.diagnosticName, expectedName)
            XCTAssertEqual(try decoded.encoded(), bytes)
        }
    }

    func testDiagnosticReportChunkEnforcesSizeAndSessionID() throws {
        let sessionID = [UInt8](repeating: 0x11, count: 16)
        let maximumChunk = envelope(
            36,
            body: bytesField(1, sessionID) + varintField(2, 0) +
                bytesField(3, [UInt8](repeating: 0xa5, count: 60 * 1024))
        )
        let decoded = try ControlEnvelope.decode(maximumChunk)
        XCTAssertEqual(try decoded.encoded(), maximumChunk)

        let oversizedChunk = envelope(
            36,
            body: bytesField(1, sessionID) + varintField(2, 0) +
                bytesField(3, [UInt8](repeating: 0xa5, count: 60 * 1024 + 1))
        )
        XCTAssertThrowsError(try ControlEnvelope.decode(oversizedChunk)) { error in
            XCTAssertEqual(error as? ControlMessageError, .invalidMessage)
        }

        let invalidSession = envelope(
            33,
            body: bytesField(1, Array(sessionID.dropLast())) +
                varintField(2, 7) + varintField(3, 60)
        )
        XCTAssertThrowsError(try ControlEnvelope.decode(invalidSession)) { error in
            XCTAssertEqual(error as? ControlMessageError, .invalidMessage)
        }
    }

    private func varintField(_ field: UInt32, _ value: UInt32) -> [UInt8] {
        var encoded = varint((field << 3) | 0)
        encoded += varint(value)
        return encoded
    }

    private func bytesField(_ field: UInt32, _ value: [UInt8]) -> [UInt8] {
        var encoded = varint((field << 3) | 2)
        encoded += varint(UInt32(value.count))
        encoded += value
        return encoded
    }

    private func envelope(_ field: UInt32, body: [UInt8]) -> Data {
        Data(bytesField(field, body))
    }

    private func varint(_ value: UInt32) -> [UInt8] {
        var remaining = value
        var encoded: [UInt8] = []
        while remaining >= 0x80 {
            encoded.append(UInt8(remaining & 0x7f) | 0x80)
            remaining >>= 7
        }
        encoded.append(UInt8(remaining))
        return encoded
    }

    func testControlFramingUsesBigEndianAndHandlesFragmentation() throws {
        let payload = Data([0x01, 0x02, 0x03])
        let encoded = try ControlFraming.encode(payload)
        XCTAssertEqual(Array(encoded), [0, 0, 0, 3, 1, 2, 3])

        var decoder = ControlFrameDecoder()
        XCTAssertEqual(try decoder.append(Data(encoded.prefix(2))), [])
        XCTAssertEqual(try decoder.append(Data(encoded.dropFirst(2))), [payload])
    }

    func testControlFramingDecodesSuccessiveAndCoalescedMessages() throws {
        let first = Data(repeating: 0x41, count: 64)
        let second = Data(repeating: 0x42, count: 96)
        let firstFrame = try ControlFraming.encode(first)
        let secondFrame = try ControlFraming.encode(second)
        var decoder = ControlFrameDecoder()
        XCTAssertEqual(try decoder.append(firstFrame), [first])
        XCTAssertEqual(try decoder.append(secondFrame), [second])
        XCTAssertEqual(try decoder.append(firstFrame + secondFrame), [first, second])
    }

    func testAudioDatagramValidatesFixedLayoutAndBigEndianHeader() throws {
        var encoded = Data(repeating: 0, count: AudioDatagram.byteCount)
        encoded[3] = 7
        encoded[4] = 0xFF
        encoded[5] = 0xFF
        encoded[6] = 0xFF
        encoded[7] = 0xFE
        let packet = try AudioDatagram(encoded: encoded)
        XCTAssertEqual(packet.streamID, 7)
        XCTAssertEqual(packet.sequence, UInt32.max - 1)
        XCTAssertEqual(packet.pcm.count, AudioDatagram.pcmByteCount)
        XCTAssertEqual(packet.encoded, encoded)

        XCTAssertThrowsError(try AudioDatagram(encoded: Data(repeating: 0, count: 967)))
    }

    func testPendingStreamDropsAudioUntilAckAndReplacesOldStream() throws {
        let session = ReceiverSessionState()
        XCTAssertTrue(session.receiveConnect(authMode: .oneTime, peerID: Data()))
        session.markAuthenticated()
        XCTAssertTrue(session.beginStream(7))
        let packet = try AudioDatagram(streamID: 7, sequence: 0,
                                      pcm: Data(repeating: 0, count: AudioDatagram.pcmByteCount))
        XCTAssertEqual(session.acceptAudio(packet), .pendingAudioDiscarded)
        XCTAssertTrue(session.ackWritten(7))
        XCTAssertEqual(session.acceptAudio(packet), .accepted)
        XCTAssertTrue(session.beginStream(9))
        XCTAssertEqual(session.acceptAudio(packet), .oldStreamDiscarded)
    }

    func testReceiverSessionCanResetForAnotherConnection() {
        let session = ReceiverSessionState()
        XCTAssertTrue(session.receiveConnect(authMode: .oneTime, peerID: Data()))
        XCTAssertTrue(session.markAuthenticated())
        XCTAssertTrue(session.beginStream(7))

        session.resetForConnection()

        XCTAssertEqual(session.phase, .awaitingConnect)
        XCTAssertNil(session.authMode)
        XCTAssertNil(session.pendingStreamID)
        XCTAssertNil(session.activeStreamID)
        XCTAssertTrue(session.receiveConnect(authMode: .pair, peerID: Data()))
    }

    func testJitterBufferReordersDropsDuplicatesLateAndConcealsLoss() throws {
        var jitter = JitterBuffer(streamID: 1, targetPackets: 3)
        let packet10 = try AudioDatagram(streamID: 1, sequence: 10,
                                         pcm: Data(repeating: 1, count: AudioDatagram.pcmByteCount))
        let packet11 = try AudioDatagram(streamID: 1, sequence: 11,
                                         pcm: Data(repeating: 2, count: AudioDatagram.pcmByteCount))
        let packet12 = try AudioDatagram(streamID: 1, sequence: 12,
                                         pcm: Data(repeating: 3, count: AudioDatagram.pcmByteCount))
        XCTAssertEqual(jitter.insert(packet10), .inserted)
        XCTAssertEqual(jitter.insert(packet12), .inserted)
        XCTAssertEqual(jitter.insert(packet11), .inserted)
        XCTAssertTrue(jitter.startIfReady())
        XCTAssertEqual(jitter.consumeNext()?.sequence, 10)
        XCTAssertEqual(jitter.insert(packet12), .duplicate)
        XCTAssertEqual(jitter.consumeNext()?.sequence, 11)
        XCTAssertEqual(jitter.consumeNext()?.sequence, 12)

        var lossJitter = JitterBuffer(streamID: 1, targetPackets: 1)
        XCTAssertEqual(lossJitter.insert(packet10), .inserted)
        XCTAssertTrue(lossJitter.startIfReady())
        XCTAssertEqual(lossJitter.consumeNext()?.sequence, 10)
        XCTAssertNil(lossJitter.consumeNext())
        XCTAssertEqual(lossJitter.concealMissing()?.count, AudioDatagram.pcmByteCount)
        XCTAssertEqual(lossJitter.insert(packet11), .late)
        XCTAssertEqual(lossJitter.stats.lostPackets, 1)
    }

    func testJitterBufferStartsWithARecoverableGapAndStaysBounded() throws {
        var jitter = JitterBuffer(streamID: 1, targetPackets: 2, maximumPackets: 3)
        let packet10 = try AudioDatagram(streamID: 1, sequence: 10,
                                         pcm: Data(repeating: 1, count: AudioDatagram.pcmByteCount))
        let packet12 = try AudioDatagram(streamID: 1, sequence: 12,
                                         pcm: Data(repeating: 3, count: AudioDatagram.pcmByteCount))
        let packet13 = try AudioDatagram(streamID: 1, sequence: 13,
                                         pcm: Data(repeating: 4, count: AudioDatagram.pcmByteCount))
        let packet14 = try AudioDatagram(streamID: 1, sequence: 14,
                                         pcm: Data(repeating: 5, count: AudioDatagram.pcmByteCount))

        XCTAssertEqual(jitter.insert(packet10), .inserted)
        XCTAssertEqual(jitter.insert(packet12), .inserted)
        XCTAssertTrue(jitter.startIfReady())
        XCTAssertEqual(jitter.consumeNext()?.sequence, 10)
        XCTAssertEqual(jitter.concealMissing()?.count, AudioDatagram.pcmByteCount)
        XCTAssertEqual(jitter.consumeNext()?.sequence, 12)

        XCTAssertEqual(jitter.insert(packet13), .inserted)
        XCTAssertEqual(jitter.insert(packet14), .inserted)
        XCTAssertLessThanOrEqual(jitter.fillPackets, 3)
        XCTAssertEqual(jitter.stats.capacityDrops, 0)
    }

    func testStreamingResamplerPreservesEveryFrameAtOneToOneRatio() {
        var resampler = StreamingStereoResampler()
        let first = (0..<256).flatMap { value in [Float(value), -Float(value)] }
        let second = (256..<512).flatMap { value in [Float(value), -Float(value)] }

        XCTAssertEqual(resampler.requiredInputFrames(outputFrameCount: 256, ratio: 1), 256)
        XCTAssertEqual(resampler.process(first, outputFrameCount: 256, ratio: 1), first)
        XCTAssertEqual(resampler.process(second, outputFrameCount: 256, ratio: 1), second)
    }

    func testSequenceComparisonHandlesWrap() {
        XCTAssertTrue(SequenceNumber.isBefore(UInt32.max, 0))
        XCTAssertTrue(SequenceNumber.isBefore(0, 1))
        XCTAssertFalse(SequenceNumber.isBefore(1, 0))
    }

    func testSilentRebufferDoesNotCreateLossOrMoveDrift() throws {
        var jitter = JitterBuffer(streamID: 1, targetPackets: 1)
        let packet = try AudioDatagram(streamID: 1, sequence: 100,
                                       pcm: Data(repeating: 0, count: AudioDatagram.pcmByteCount))
        XCTAssertEqual(jitter.insert(packet), .inserted)
        XCTAssertTrue(jitter.startIfReady())
        jitter.enterSilentRebuffer()
        XCTAssertNil(jitter.consumeNext())
        XCTAssertEqual(jitter.stats.lostPackets, 0)

        var drift = DriftController()
        let nominal = drift.ratio
        _ = drift.update(fillError: 500, validAudio: false)
        XCTAssertEqual(drift.ratio, nominal, accuracy: 0.0000001)
        _ = drift.update(fillError: 500, validAudio: true)
        XCTAssertNotEqual(drift.ratio, nominal)
        drift.reset()
        XCTAssertEqual(drift.ratio, nominal, accuracy: 0.0000001)
    }

    func testAudioDatagramDiagnosticsAreRateLimited() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HearPortRealtimeDiagnostics-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let diagnostics = HearPortDiagnostics(directory: directory)
        diagnostics.level = .debug
        let receiver = HearPortReceiver(
            bufferTargetPackets: 1,
            renderCapacityFrames: AudioDatagram.framesPerPacket,
            diagnostics: diagnostics
        )

        XCTAssertTrue(receiver.beginAuthentication(authMode: .oneTime, peerID: Data()))
        XCTAssertTrue(receiver.markAuthenticated())
        XCTAssertTrue(receiver.beginStream(7))
        XCTAssertTrue(receiver.acknowledgeStartStream(7))

        for sequence in 0..<20 {
            let packet = try AudioDatagram(
                streamID: 7,
                sequence: UInt32(sequence),
                pcm: Data(repeating: 0, count: AudioDatagram.pcmByteCount)
            )
            XCTAssertEqual(receiver.receiveDatagram(packet.encoded), .accepted)
        }

        XCTAssertTrue(diagnostics.flushAsync(timeout: 1.0))
        let packetLogs = diagnostics.recentLines(limit: 200)
            .filter { $0.contains("event=datagram_received") }
        XCTAssertLessThan(packetLogs.count, 20)
    }

    func testAudioLifecycleResetsBuffersForInterruptionAndRouteChange() {
        let lifecycle = AudioLifecycleController()
        lifecycle.startSpeakerSession()
        lifecycle.handle(.interruptionBegan)
        XCTAssertEqual(lifecycle.state, .interrupted)
        XCTAssertTrue(lifecycle.shouldRenderSilence)
        XCTAssertEqual(lifecycle.resetGeneration, 1)
        lifecycle.handle(.interruptionEnded)
        XCTAssertEqual(lifecycle.state, .silentRebuffer)
        lifecycle.handle(.routeChanged)
        XCTAssertEqual(lifecycle.state, .silentRebuffer)
        XCTAssertEqual(lifecycle.resetGeneration, 2)
    }
}
