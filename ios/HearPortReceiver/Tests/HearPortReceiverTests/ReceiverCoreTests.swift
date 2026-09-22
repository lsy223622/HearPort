import Foundation
import XCTest
@testable import HearPortReceiver

final class ReceiverCoreTests: XCTestCase {
    func testControlEnvelopeVectorsMatchCanonicalProtoFields() throws {
        let connect = ControlEnvelope(.connectRequest(authMode: .pair, peerID: Data()))
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
            ControlEnvelope(.connectRequest(authMode: .pair, peerID: Data()))
        )

        let duplicate = Data([0x0a, 0x04, 0x08, 0x01, 0x08, 0x02])
        XCTAssertEqual(
            try ControlEnvelope.decode(duplicate),
            ControlEnvelope(.connectRequest(authMode: .pair, peerID: Data()))
        )

        let wrongWireAfterValid = Data([0x0a, 0x02, 0x08, 0x02,
                                        0x09, 0x00, 0x00, 0x00, 0x00,
                                        0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(
            try ControlEnvelope.decode(wrongWireAfterValid),
            ControlEnvelope(.connectRequest(authMode: .pair, peerID: Data()))
        )

        XCTAssertThrowsError(try ControlEnvelope.decode(Data([0xfa, 0x01, 0x02, 0x08, 0x00])))
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
        var jitter = JitterBuffer(streamID: 1, startupPackets: 2)
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

        var lossJitter = JitterBuffer(streamID: 1, startupPackets: 1)
        XCTAssertEqual(lossJitter.insert(packet10), .inserted)
        XCTAssertTrue(lossJitter.startIfReady())
        XCTAssertEqual(lossJitter.consumeNext()?.sequence, 10)
        XCTAssertNil(lossJitter.consumeNext())
        XCTAssertEqual(lossJitter.concealMissing()?.count, AudioDatagram.pcmByteCount)
        XCTAssertEqual(lossJitter.insert(packet11), .late)
        XCTAssertEqual(lossJitter.stats.lostPackets, 1)
    }

    func testJitterBufferStartsWithARecoverableGapAndStaysBounded() throws {
        var jitter = JitterBuffer(streamID: 1, startupPackets: 2, maximumPackets: 3)
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
        var jitter = JitterBuffer(streamID: 1, startupPackets: 1)
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
