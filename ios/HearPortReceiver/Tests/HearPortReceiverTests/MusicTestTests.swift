import XCTest
@testable import HearPortReceiver

final class MusicTestTests: XCTestCase {
    func testRoundPolicyCarriesTransportAndContinuousSource() throws {
        let bytes = Data([3, 3, 8, 3, 0, 120, 0, 0, 0, 1, 119, 0, 0, 0, 0, 4])
        let round = try MusicTestRound(encoded: bytes)
        XCTAssertEqual(round.index, 3)
        XCTAssertTrue(round.reliable)
        XCTAssertTrue(round.adaptive)
        XCTAssertEqual(round.firstSequence, 96_000)
        XCTAssertEqual(round.seconds, 120)
        XCTAssertEqual(round.generation, 4)
        let envelope = ControlEnvelope(.probeManifest(streamID: 7, manifest: bytes))
        XCTAssertEqual(try ControlEnvelope.decode(envelope.encoded()), envelope)
        var invalid = bytes
        invalid[3] = 0
        XCTAssertThrowsError(try MusicTestRound(encoded: invalid))
        invalid = bytes; invalid[11] = 1
        XCTAssertThrowsError(try MusicTestRound(encoded: invalid))
    }

    func testMusicRoundResetsOutputAndRejectsPreviousSource() throws {
        let receiver = HearPortReceiver(bufferTargetPackets: 1)
        XCTAssertTrue(receiver.beginAuthentication(authMode: .oneTime, peerID: Data()))
        XCTAssertTrue(receiver.markAuthenticated())
        XCTAssertTrue(receiver.beginStream(7))
        XCTAssertTrue(receiver.acknowledgeStartStream(7))
        receiver.configurePlayout(try PlayoutBudget(targetMilliseconds: 50,
            maximumMilliseconds: 100, outputReserveMilliseconds: 10))
        let round = try MusicTestRound(encoded: Data([3, 3, 8, 3, 0, 120, 0, 0, 0, 1, 119, 0, 0, 0, 0, 4]))
        XCTAssertTrue(receiver.beginMusicRound(streamID: 7, round: round))
        XCTAssertFalse(receiver.isRenderActive)
        XCTAssertNil(receiver.reliableProgressSequence())
        let record = try TimedAudioRecord(streamID: 7, generation: 3, sequence: 95_999,
            frameCount: 120, kind: .audio, capturedAt: 1,
            sourceFrame: 95_999 * 120, payload: Data(repeating: 0, count: 960))
        XCTAssertNil(receiver.receiveTimedRecord(record))
        XCTAssertEqual(receiver.session.activeStreamID, 7)
        XCTAssertFalse(receiver.beginMusicRound(streamID: 8, round: round))
    }

    func testCompressionMusicManifestParsesAllProfilesAndRepeats() throws {
        let expected = [
            (120, 0), (120, 0), (120, 192), (240, 192),
            (480, 192), (120, 256), (240, 256), (480, 256)
        ]
        for profile in 0..<8 {
            let bytes = compressionManifest(index: 9, profile: profile, repeatIndex: 2,
                                            seconds: 120, generation: 23)
            let round = try MusicTestRound(encoded: bytes)
            XCTAssertEqual(round.version, 4)
            XCTAssertEqual(round.index, 9)
            XCTAssertEqual(round.roundCount, 32)
            XCTAssertEqual(round.profile, profile)
            XCTAssertEqual(round.repeatIndex, 2)
            XCTAssertEqual(round.frameCount, expected[profile].0)
            XCTAssertEqual(round.bitrateKbps, expected[profile].1)
            XCTAssertTrue(round.adaptive)
            XCTAssertEqual(round.firstSequence, 8 * 120 * 400)
        }
    }

    func testCompressionMusicManifestAcceptsAdaptiveDatagramAndReliablePolicies() throws {
        var bytes = compressionManifest(index: 1, profile: 2, repeatIndex: 1,
                                        seconds: 60, generation: 1)
        bytes[3] = 2
        let datagramRound = try MusicTestRound(encoded: bytes)
        XCTAssertFalse(datagramRound.reliable)
        XCTAssertTrue(datagramRound.adaptive)

        bytes[3] = 3
        let reliableRound = try MusicTestRound(encoded: bytes)
        XCTAssertTrue(reliableRound.reliable)
        XCTAssertTrue(reliableRound.adaptive)

        bytes[3] = 1
        XCTAssertThrowsError(try MusicTestRound(encoded: bytes))
    }

    func testCompressionMusicManifestRejectsProfileMismatchAndInvalidReservedFields() {
        var bytes = compressionManifest(index: 1, profile: 2, repeatIndex: 1,
                                        seconds: 60, generation: 1)
        bytes[16] = 0; bytes[17] = 240
        XCTAssertThrowsError(try MusicTestRound(encoded: bytes))
        bytes = compressionManifest(index: 1, profile: 2, repeatIndex: 1,
                                    seconds: 60, generation: 1)
        bytes[22] = 1
        XCTAssertThrowsError(try MusicTestRound(encoded: bytes))
        bytes = compressionManifest(index: 1, profile: 2, repeatIndex: 1,
                                    seconds: 60, generation: 1)
        bytes[20] = 0x03; bytes[21] = 0xC1
        XCTAssertThrowsError(try MusicTestRound(encoded: bytes))
        bytes = compressionManifest(index: 1, profile: 0, repeatIndex: 1,
                                    seconds: 60, generation: 1)
        bytes[3] = 1
        XCTAssertThrowsError(try MusicTestRound(encoded: bytes))
        bytes = compressionManifest(index: 1, profile: 1, repeatIndex: 3,
                                    seconds: 60, generation: 1)
        XCTAssertThrowsError(try MusicTestRound(encoded: bytes))
    }

    private func compressionManifest(index: Int, profile: Int, repeatIndex: Int,
                                     seconds: Int, generation: UInt32) -> Data {
        let frames = [120, 120, 120, 240, 480, 120, 240, 480][profile]
        let bitrate = [0, 0, 192, 192, 192, 256, 256, 256][profile]
        var bytes = Data([4, UInt8(index), 32, 3, UInt8(seconds >> 8), UInt8(seconds & 0xff),
                          UInt8(profile), UInt8(repeatIndex)])
        appendUInt32(UInt32(index - 1) * UInt32(seconds) * 400, to: &bytes)
        appendUInt32(generation, to: &bytes)
        appendUInt16(UInt16(frames), to: &bytes)
        appendUInt16(UInt16(bitrate), to: &bytes)
        appendUInt16(profile >= 2 ? 120 : 0, to: &bytes)
        appendUInt16(0, to: &bytes)
        return bytes
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value >> 8)); data.append(UInt8(value & 0xff))
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff)); data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff)); data.append(UInt8(value & 0xff))
    }
}
