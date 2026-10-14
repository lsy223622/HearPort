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
}
