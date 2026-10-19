import XCTest
@testable import HearPortReceiver

final class TimedAudioRecordTests: XCTestCase {
    func testSamplePositionAndCaptureTimeSurviveWireEncoding() throws {
        let record = try TimedAudioRecord(streamID: 17, generation: 2, sequence: .max,
            frameCount: 120, kind: .audio, capturedAt: 0x0102030405060708,
            sourceFrame: 0x100000000, payload: Data(repeating: 0x55, count: 960))
        let bytes = record.encoded
        XCTAssertEqual(bytes.count, 992)
        XCTAssertEqual(Array(bytes[16..<24]), [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(try TimedAudioRecord(encoded: bytes), record)
        XCTAssertThrowsError(try TimedAudioRecord(encoded: Data(bytes.prefix(31))))
        var broken = bytes
        broken[7] = 0
        XCTAssertThrowsError(try TimedAudioRecord(encoded: broken))
    }

    func testReliableTimedRecordsSurviveSplitReadAndRejectTruncation() throws {
        let record = try TimedAudioRecord(streamID: 17, generation: 2, sequence: 0,
            frameCount: 120, kind: .audio, capturedAt: 1_000_000_000,
            sourceFrame: 0, payload: Data(repeating: 0, count: 960))
        let preface = Data([0, 0, 0, 17, 0, 0, 0, 2])
        var records = ReliableTimedAudioRecords(expectedStreamID: 17)
        XCTAssertEqual(try records.append(preface + record.encoded.prefix(13)), [])
        XCTAssertEqual(try records.append(record.encoded.dropFirst(13)), [record])
        XCTAssertNoThrow(try records.finish())
        _ = try records.append(Data([0]))
        XCTAssertThrowsError(try records.finish())
    }

    func testCompressionRecordKindsValidateCodecFramingAndPayloadSizes() throws {
        let opus = try TimedAudioRecord(streamID: 17, generation: 2, sequence: 4,
            frameCount: 480, kind: .opus, capturedAt: 1_000,
            sourceFrame: 480, payload: Data(repeating: 0xa5, count: 992))
        XCTAssertEqual(opus.encoded.count, 1_024)
        XCTAssertEqual(try TimedAudioRecord(encoded: opus.encoded), opus)

        let pcm16 = try TimedAudioRecord(streamID: 17, generation: 2, sequence: 0,
            frameCount: 120, kind: .pcm16, capturedAt: 1_000,
            sourceFrame: 0, payload: Data(repeating: 0, count: 480))
        XCTAssertEqual(try TimedAudioRecord(encoded: pcm16.encoded), pcm16)

        let opus240 = try TimedAudioRecord(streamID: 17, generation: 2, sequence: 0,
            frameCount: 240, kind: .opus, capturedAt: 1_000,
            sourceFrame: 0, payload: Data([1]))
        XCTAssertEqual(try TimedAudioRecord(encoded: opus240.encoded), opus240)
        XCTAssertThrowsError(try TimedAudioRecord(streamID: 17, generation: 2, sequence: 0,
            frameCount: 120, kind: .pcm16, capturedAt: 1_000,
            sourceFrame: 0, payload: Data(repeating: 0, count: 478)))
        XCTAssertThrowsError(try TimedAudioRecord(streamID: 17, generation: 2, sequence: 0,
            frameCount: 960, kind: .opus, capturedAt: 1_000,
            sourceFrame: 0, payload: Data([1])))
    }
}
