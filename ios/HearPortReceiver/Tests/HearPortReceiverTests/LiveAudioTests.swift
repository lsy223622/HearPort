import XCTest
@testable import HearPortReceiver

final class LiveAudioTests: XCTestCase {
    private final class Decoder: CompressionOpusFrameDecoding {
        var calls: [Bool] = []
        func decode(packet: Data?, frameCount: Int) -> [Float]? {
            calls.append(packet != nil)
            return [Float](repeating: 0.25, count: frameCount * 2)
        }
    }

    func testFormatDefaultsAndIndependentOverrides() throws {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AudioStreamFormat.load(usb: false, defaults: defaults), try AudioStreamFormat(opus: true))
        XCTAssertEqual(AudioStreamFormat.load(usb: true, defaults: defaults), .pcm)
        defaults.set("pcm", forKey: "hearport.networkAudio.codec")
        defaults.set("opus", forKey: "hearport.usbAudio.codec")
        defaults.set(192_000, forKey: "hearport.usbAudio.bitrate")
        defaults.set(480, forKey: "hearport.usbAudio.frames")
        XCTAssertEqual(AudioStreamFormat.load(usb: false, defaults: defaults), .pcm)
        XCTAssertEqual(AudioStreamFormat.load(usb: true, defaults: defaults),
            try AudioStreamFormat(opus: true, bitrate: 192_000, frameCount: 480))
    }

    func testFormatNegotiationRoundTripAndValidation() throws {
        let budget = try PlayoutBudget(targetMilliseconds: 50, maximumMilliseconds: 100, outputReserveMilliseconds: 11)
        for frames in [120, 240, 480] {
            let format = try AudioStreamFormat(opus: true, frameCount: frames, lookaheadFrames: 120)
            let envelope = ControlEnvelope(.audioSetup(streamID: 7, budget: budget, format: format))
            XCTAssertEqual(try ControlEnvelope.decode(envelope.encoded()), envelope)
        }
        XCTAssertThrowsError(try AudioStreamFormat(opus: true, frameCount: 121))
        XCTAssertThrowsError(try AudioStreamFormat(opus: true, bitrate: 128000))
        XCTAssertFalse(try AudioStreamFormat(opus: true, frameCount: 480).fits(
            PlayoutBudget(targetMilliseconds: 12, maximumMilliseconds: 20, outputReserveMilliseconds: 11)))
    }

    func testReorderingLossAndSilenceDoNotCorruptSourceClock() throws {
        let codec = Decoder()
        let format = try AudioStreamFormat(opus: true, frameCount: 240)
        let budget = try PlayoutBudget(targetMilliseconds: 50, maximumMilliseconds: 100, outputReserveMilliseconds: 10)
        var now: UInt64 = 1_010_000_000
        var output: [TimedAudioRecord] = []
        let decoder = try LiveAudioDecoder(format: format, streamID: 7, budget: budget,
            decoder: codec, startsTimer: false, now: { now }, output: { output.append($0) })
        func record(_ seq: UInt32, _ at: UInt64) throws -> TimedAudioRecord {
            try TimedAudioRecord(streamID: 7, generation: 1, sequence: seq, frameCount: 240,
                kind: .opus, capturedAt: at, sourceFrame: UInt64(seq) * 120, payload: Data([1]))
        }
        decoder.receive(try record(2, 1_005_000_000), captured: 1_005_000_000, uncertainty: 0)
        XCTAssertTrue(output.isEmpty)
        decoder.receive(try record(0, 1_000_000_000), captured: 1_000_000_000, uncertainty: 0)
        XCTAssertEqual(output.map(\.sequence), [0, 1, 2, 3])
        now = 5_000_000_000; decoder.advance()
        XCTAssertEqual(codec.calls, [true, true])
        // Resume after silence uses the next source sequence with a fresh capture timestamp.
        decoder.receive(try record(4, now), captured: now, uncertainty: 0)
        XCTAssertEqual(output.map(\.sequence), [0, 1, 2, 3, 4, 5])
        decoder.receive(try record(8, now + 10_000_000), captured: now + 10_000_000, uncertainty: 0)
        now += 60_000_000; decoder.advance()
        XCTAssertEqual(codec.calls, [true, true, true, false, true])
        XCTAssertEqual(output.suffix(2).map(\.sequence), [8, 9])
        decoder.stop()
        decoder.receive(try record(10, now), captured: now, uncertainty: 0)
        XCTAssertEqual(codec.calls.count, 5)
    }

    func testDelayedStartupUsesRemainingPreparationWindow() {
        let decision = PlayoutDecision(action: .normal, correction: 0,
            targetMilliseconds: 225, prepareDeadline: 1_280_000_000, bufferTargetMilliseconds: 200)
        XCTAssertEqual(decision.startupTargetPackets(now: 1_000_000_000), 80)
        XCTAssertLessThanOrEqual(decision.startupTargetPackets(now: 1_250_000_000), 10)
        XCTAssertEqual(decision.startupTargetPackets(now: 1_281_000_000), 1)
    }

    func testExpiredOriginalAndLongGapRemainBounded() throws {
        let codec = Decoder()
        let format = try AudioStreamFormat(opus: true, frameCount: 240)
        let budget = try PlayoutBudget(targetMilliseconds: 50, maximumMilliseconds: 100, outputReserveMilliseconds: 10)
        var output: [TimedAudioRecord] = []
        let decoder = try LiveAudioDecoder(format: format, streamID: 7, budget: budget,
            decoder: codec, startsTimer: false, now: { 2_000_000_000 }, output: { output.append($0) })
        let expired = try TimedAudioRecord(streamID: 7, generation: 1, sequence: 0, frameCount: 240,
            kind: .opus, capturedAt: 1_000_000_000, sourceFrame: 0, payload: Data([1]))
        decoder.receive(expired, captured: expired.capturedAt, uncertainty: 0)
        XCTAssertTrue(output.isEmpty)
        XCTAssertEqual(codec.calls, [false])
        let fresh = try TimedAudioRecord(streamID: 7, generation: 1, sequence: 10000, frameCount: 240,
            kind: .opus, capturedAt: 2_000_000_000, sourceFrame: 1_200_000, payload: Data([1]))
        decoder.receive(fresh, captured: fresh.capturedAt, uncertainty: 0)
        XCTAssertEqual(codec.calls, [false, true])
        XCTAssertEqual(output.map(\.sequence), [10000, 10001])
        decoder.receive(fresh, captured: fresh.capturedAt, uncertainty: 0)
        XCTAssertEqual(codec.calls.count, 2)
    }
}
