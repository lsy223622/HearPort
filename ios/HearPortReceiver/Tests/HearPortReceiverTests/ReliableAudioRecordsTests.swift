import Foundation
import XCTest
@testable import HearPortReceiver

final class ReliableAudioRecordsTests: XCTestCase {
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
