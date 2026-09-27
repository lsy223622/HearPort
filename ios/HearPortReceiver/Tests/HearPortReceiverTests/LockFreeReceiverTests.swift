import Foundation
import XCTest
@testable import HearPortReceiver

final class LockFreeReceiverTests: XCTestCase {
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
