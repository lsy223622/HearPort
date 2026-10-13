import Foundation
import XCTest
@testable import HearPortReceiver

final class LockFreeReceiverTests: XCTestCase {
    func testStagedAudioExpiresWhenClockUncertaintyGrows() {
        let ring = RenderRingBuffer(capacityFrames: 240)
        let now = DispatchTime.now().uptimeNanoseconds
        ring.setMaximumAge(nanoseconds: 90_000_000)
        let captured = now - 70_000_000
        XCTAssertEqual(ring.pushTimed(Array(repeating: 1, count: 240), sourceBegin: 0,
            sourceEnd: 120, capturedAt: captured, deadline: captured + 88_000_000), 120)
        ring.setClockUncertainty(nanoseconds: 40_000_000)
        let output = ring.pop(frames: 120)
        XCTAssertEqual(output.renderedFrames, 0)
        XCTAssertEqual(ring.expiredFrames, 120)
        XCTAssertEqual(ring.lastSourceFrame, 120)
    }

    func testFutureTimedPacketsDoNotConcealGapBeforeDeadline() throws {
        let receiver = readyReceiver(target: 4)
        _ = receiver.renderFrames(120)
        let now = DispatchTime.now().uptimeNanoseconds
        receiver.configurePlayout(try PlayoutBudget(targetMilliseconds: 50,
            maximumMilliseconds: 100, outputReserveMilliseconds: 1))
        receiver.observeClock(localSent: now - 2_000_000, remoteReceived: now - 1_000_000,
                              remoteSent: now - 1_000_000, localReceived: now)
        for sequence in UInt32(0)..<20 {
            let packet = try AudioDatagram(encoded: datagram(stream: 7, sequence: sequence, value: 2))
            let record = try TimedAudioRecord(streamID: 7, generation: 1, sequence: sequence,
                frameCount: 120, kind: .audio,
                capturedAt: now - 50_000_000 + UInt64(sequence) * 2_500_000,
                sourceFrame: UInt64(sequence) * 120, payload: packet.pcm)
            _ = receiver.receiveTimedRecord(record)
        }
        _ = receiver.renderFrames(480)
        let future = try AudioDatagram(encoded: datagram(stream: 7, sequence: 21, value: 2))
        _ = receiver.receiveTimedRecord(try TimedAudioRecord(streamID: 7, generation: 1,
            sequence: 21, frameCount: 120, kind: .audio, capturedAt: now,
            sourceFrame: 21 * 120, payload: future.pcm))
        XCTAssertEqual(receiver.jitterStats?.lostPackets, 0)
        let missing = try AudioDatagram(encoded: datagram(stream: 7, sequence: 20, value: 2))
        _ = receiver.receiveTimedRecord(try TimedAudioRecord(streamID: 7, generation: 1,
            sequence: 20, frameCount: 120, kind: .audio, capturedAt: now,
            sourceFrame: 20 * 120, payload: missing.pcm))
        XCTAssertEqual(receiver.jitterStats?.latePackets, 0)
        XCTAssertEqual(receiver.jitterStats?.lostPackets, 0)
    }

    func testJitterLimitIncludesPcmAlreadyStagedInRing() throws {
        var jitter = JitterBuffer(streamID: 7, targetPackets: 4)
        for sequence in 0..<4 {
            let packet = try AudioDatagram(encoded: datagram(stream: 7,
                                                              sequence: UInt32(sequence),
                                                              value: 1))
            XCTAssertEqual(jitter.insert(packet), .inserted)
        }
        XCTAssertTrue(jitter.startIfReady())
        XCTAssertEqual(jitter.consumeNext()?.sequence, 0)
        XCTAssertEqual(jitter.consumeNext()?.sequence, 1)
        let next = try AudioDatagram(encoded: datagram(stream: 7, sequence: 4, value: 1))
        XCTAssertEqual(jitter.insert(next, stagedFrames: 240), .inserted)
        XCTAssertEqual(jitter.takeTrimmedSequences(), [2])
        XCTAssertEqual(jitter.expectedSequence, 3)
        XCTAssertEqual(jitter.fillPackets * 120 + 240, 480)
    }

    func testSmallTargetDoesNotGainHiddenRingLatency() throws {
        let receiver = readyReceiver(target: 4)
        _ = receiver.renderFrames(120) // acknowledge stream reset
        for sequence in 0..<4 {
            XCTAssertEqual(receiver.receiveDatagram(try datagram(stream: 7,
                                                                 sequence: UInt32(sequence),
                                                                 value: 1)), .accepted)
        }
        XCTAssertLessThanOrEqual(receiver.renderFillFrames, 480)
        let output = receiver.renderFrames(1_024)
        XCTAssertEqual(output[0], 1)
        XCTAssertEqual(output[479 * 2], 1)
        XCTAssertEqual(output[480 * 2], 0)
    }

    func testBufferedAudioContinuesDuringReceiveGap() throws {
        let receiver = readyReceiver(target: 128)
        _ = receiver.renderFrames(120)
        for sequence in 0..<128 {
            XCTAssertEqual(receiver.receiveDatagram(try datagram(stream: 7,
                                                                 sequence: UInt32(sequence),
                                                                 value: 2)), .accepted)
        }
        XCTAssertLessThanOrEqual(receiver.renderFillFrames, 15_360)
        XCTAssertEqual(receiver.renderFrames(1_024)[0], 2)
        Thread.sleep(forTimeInterval: 0.03)
        let second = receiver.renderFrames(1_024)
        XCTAssertEqual(second[0], 2)
        XCTAssertEqual(second[1_023 * 2], 2)
    }

    func testPendingStreamAudioCannotEnterRing() throws {
        let receiver = HearPortReceiver(bufferTargetPackets: 4)
        XCTAssertTrue(receiver.beginAuthentication(authMode: .oneTime, peerID: Data()))
        XCTAssertTrue(receiver.markAuthenticated())
        XCTAssertTrue(receiver.beginStream(7))
        _ = receiver.renderFrames(120)
        for sequence in 0..<4 {
            XCTAssertEqual(receiver.receiveDatagram(try datagram(stream: 7,
                                                                 sequence: UInt32(sequence),
                                                                 value: 3)), .pendingAudioDiscarded)
        }
        XCTAssertTrue(receiver.acknowledgeStartStream(7))
        XCTAssertEqual(receiver.renderFillFrames, 0)
        XCTAssertEqual(receiver.renderFrames(120), Array(repeating: 0, count: 240))
    }

    func testNewStreamDiscardsOldPcmAfterGenerationAck() throws {
        let receiver = readyReceiver(target: 4)
        _ = receiver.renderFrames(120)
        for sequence in 0..<4 {
            _ = receiver.receiveDatagram(try datagram(stream: 7,
                                                       sequence: UInt32(sequence), value: 4))
        }
        XCTAssertTrue(receiver.beginStream(9))
        XCTAssertTrue(receiver.acknowledgeStartStream(9))
        XCTAssertEqual(receiver.renderFrames(120), Array(repeating: 0, count: 240))
        for sequence in 0..<4 {
            _ = receiver.receiveDatagram(try datagram(stream: 9,
                                                       sequence: UInt32(sequence), value: 9))
        }
        XCTAssertEqual(receiver.renderFrames(120)[0], 9)
    }

    private func readyReceiver(target: Int) -> HearPortReceiver {
        let receiver = HearPortReceiver(bufferTargetPackets: target)
        XCTAssertTrue(receiver.beginAuthentication(authMode: .oneTime, peerID: Data()))
        XCTAssertTrue(receiver.markAuthenticated())
        XCTAssertTrue(receiver.beginStream(7))
        XCTAssertTrue(receiver.acknowledgeStartStream(7))
        return receiver
    }

    private func datagram(stream: UInt32, sequence: UInt32, value: Float) throws -> Data {
        var pcm = Data(capacity: AudioDatagram.pcmByteCount)
        let bits = value.bitPattern.littleEndian
        for _ in 0..<(AudioDatagram.framesPerPacket * 2) {
            withUnsafeBytes(of: bits) { pcm.append(contentsOf: $0) }
        }
        return try AudioDatagram(streamID: stream, sequence: sequence, pcm: pcm).encoded
    }
}
