import Foundation
import XCTest
@testable import HearPortReceiver

final class ReliableAudioRecordsTests: XCTestCase {
    func testVariablePcmAndLegacyRecordsShareReliableStream() throws {
        var records = ReliableAudioRecords(expectedStreamID: 7, timed: true)
        // 44.1 kHz, 24-bit stereo. Constant -0.5 left, +0.25 right.
        let samples: [UInt8] = [0, 0, 0xc0, 0, 0, 0x20]
        let payload = Data([0xac, 0x44, 24] + Array(repeating: samples, count: 111).flatMap { $0 })
        let reduced = try TimedAudioRecord(streamID: 7, generation: 1, sequence: 3,
            frameCount: 120, kind: .adaptivePcm, capturedAt: 9, sourceFrame: 360, payload: payload)
        let original = try TimedAudioRecord(streamID: 7, generation: 1, sequence: 4,
            frameCount: 120, kind: .audio, capturedAt: 10, sourceFrame: 480,
            payload: Data(repeating: 0, count: 960))
        let bytes = Data([0, 0, 0, 7, 0, 0, 0, 1]) + reduced.encoded + original.encoded
        XCTAssertTrue(try records.append(bytes.prefix(42)).isEmpty)
        let decoded = try records.append(bytes.dropFirst(42))
        XCTAssertEqual(decoded.map(\.sequence), [3, 4])
        XCTAssertEqual(decoded[0].pcm.count, 960)
        let stereo: [Float] = [-0.5, 0.25]
        XCTAssertEqual(decoded[0].pcm, (0..<120).flatMap { _ in stereo }.withUnsafeBytes { Data($0) })
        XCTAssertEqual(records.timedPackets, [reduced, original])
        XCTAssertNoThrow(try records.finish())
        XCTAssertThrowsError(try TimedAudioRecord(encoded: Data(reduced.encoded.dropLast())))
    }

    func testReliableProbeRecordsKeepVariablePacketLengthsAcrossChunks() throws {
        var records = ReliableProbeRecords(expectedStreamID: 7)
        let first = Data([0, 0, 0, 7, 0, 0, 0, 1] + Array(repeating: 0x31, count: 480))
        let second = Data([0, 0, 0, 7, 0, 0, 0, 2] + Array(repeating: 0x42, count: 960))
        let preface = Data([0, 0, 0, 7, 0, 0, 0, 1])
        let framed = preface + Data([0x01, 0xe8]) + first +
            Data([0x03, 0xc8]) + second
        XCTAssertTrue(try records.append(framed.prefix(490)).isEmpty)
        let packets = try records.append(framed.dropFirst(490))
        XCTAssertEqual(packets, [first, second])
        XCTAssertNoThrow(try records.finish())
    }
    func testSplitPrefaceAndJoinedRecordsYieldOriginalAudio() throws {
        var records = ReliableAudioRecords(expectedStreamID: 7)
        let first = try AudioDatagram(streamID: 7, sequence: 0,
                                      pcm: Data(repeating: 0x11, count: AudioDatagram.pcmByteCount))
        let second = try AudioDatagram(streamID: 7, sequence: 1,
                                       pcm: Data(repeating: 0x22, count: AudioDatagram.pcmByteCount))
        let bytes = Data([0, 0, 0, 7, 0, 0, 0, 1]) + first.encoded + second.encoded
        XCTAssertTrue(try records.append(bytes.prefix(3)).isEmpty)
        XCTAssertTrue(try records.append(bytes.subdata(in: 3..<11)).isEmpty)
        XCTAssertEqual(try records.append(bytes.subdata(in: 11..<bytes.count)),
                       [first, second])
        XCTAssertEqual(records.generation, 1)
        XCTAssertNoThrow(try records.finish())
    }

    func testWrongStreamAndZeroGenerationAreRejected() throws {
        var wrongStream = ReliableAudioRecords(expectedStreamID: 7)
        XCTAssertThrowsError(try wrongStream.append(Data([0, 0, 0, 8, 0, 0, 0, 1])))
        var zeroGeneration = ReliableAudioRecords(expectedStreamID: 7)
        XCTAssertThrowsError(try zeroGeneration.append(Data([0, 0, 0, 7, 0, 0, 0, 0])))
    }

    func testPartialRecordFailsAtEndWithoutEmittingAudio() throws {
        var records = ReliableAudioRecords(expectedStreamID: 7)
        XCTAssertTrue(try records.append(Data([0, 0, 0, 7, 0, 0, 0, 1, 0])).isEmpty)
        XCTAssertThrowsError(try records.finish())
    }
}
