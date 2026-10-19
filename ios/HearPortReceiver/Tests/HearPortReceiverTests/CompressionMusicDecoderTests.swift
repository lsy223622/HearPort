import Foundation
import HearPortOpusBridge
import XCTest
@testable import HearPortReceiver

final class CompressionMusicDecoderTests: XCTestCase {
    private let origin: UInt64 = 5_000_000_000

    func testReorderedLongOpusPacketsDecodeContiguouslyIntoPCMUnits() throws {
        let round = try makeRound(profile: 3, seconds: 60)
        let opus = FakeOpusFrameDecoder()
        var output: [TimedAudioRecord] = []
        let decoder = try makeDecoder(round: round, opus: opus) { record in
            output.append(record)
            return true
        }
        let first = try record(round: round, sequence: round.firstSequence, frameCount: 240,
                               payload: Data([1]), capture: origin)
        let second = try record(round: round, sequence: round.firstSequence + 2, frameCount: 240,
                                payload: Data([2]), capture: origin + 5_000_000)

        decoder.receive(second, mappedCapturedAt: origin + 5_000_000,
                        receivedAt: origin + 6_000_000)
        XCTAssertTrue(output.isEmpty)
        decoder.receive(first, mappedCapturedAt: origin, receivedAt: origin + 7_000_000)

        XCTAssertEqual(opus.packetIDs, [1, 2])
        XCTAssertEqual(output.map(\.sequence), [0, 1, 2, 3])
        XCTAssertEqual(output.map(\.sourceFrame), [0, 120, 240, 360])
        XCTAssertEqual(output.map(\.capturedAt), [origin, origin + 2_500_000,
                                                  origin + 5_000_000, origin + 7_500_000])
        XCTAssertTrue(output.allSatisfy { $0.kind == .audio && $0.frameCount == 120 && $0.payload.count == 960 })
    }

    func testStatelessPCMPacketsAreAdmittedImmediatelyOutOfOrderAndDeduplicated() throws {
        let round = try makeRound(profile: 0, seconds: 60)
        var output: [TimedAudioRecord] = []
        let decoder = try makeDecoder(round: round, opus: nil) { record in
            output.append(record)
            return true
        }
        let later = try record(round: round, sequence: round.firstSequence + 1,
                               frameCount: 120, payload: Data(), capture: origin + 2_500_000)
        let first = try record(round: round, sequence: round.firstSequence,
                               frameCount: 120, payload: Data(), capture: origin)
        decoder.receive(later, mappedCapturedAt: origin + 2_500_000,
                        receivedAt: origin + 10_000_000)
        XCTAssertEqual(output.map(\.sequence), [1])

        decoder.receive(later, mappedCapturedAt: origin + 2_500_000,
                        receivedAt: origin + 11_000_000)
        decoder.receive(first, mappedCapturedAt: origin,
                        receivedAt: origin + 12_000_000)

        XCTAssertEqual(output.map(\.sequence), [1, 0])
        XCTAssertEqual(decoder.finish(at: origin + 20_000_000, reason: "test")?.invalidPackets, 1)
    }

    func testLostFirstOpusPacketUsesPLCAndIsCountedAsMissing() throws {
        let round = try makeRound(profile: 2, seconds: 60)
        let opus = FakeOpusFrameDecoder()
        var output: [TimedAudioRecord] = []
        let decoder = try makeDecoder(round: round, opus: opus) { record in
            output.append(record)
            return true
        }
        let firstReceived = try record(round: round, sequence: round.firstSequence + 1,
                                       frameCount: 120, payload: Data([7]),
                                       capture: origin + 2_500_000)
        decoder.receive(firstReceived, mappedCapturedAt: origin + 2_500_000,
                        receivedAt: origin + 20_000_000)
        decoder.advance(at: origin + 39_000_000)

        XCTAssertEqual(opus.calls.map(\.isPLC), [true, false])
        XCTAssertEqual(output.map(\.sequence), [1])
        let summary = decoder.finish(at: origin + 40_000_000, reason: "test",
                                     sourceFramesPrepared: 120)
        XCTAssertEqual(summary?.missingFrames, 60 * 48_000 - 120)
        XCTAssertEqual(summary?.decoderMissingFrames, 60 * 48_000 - 120)
        XCTAssertEqual(summary?.sourceFramesPrepared, 120)
        XCTAssertEqual(summary?.latePackets, 0)
    }

    func testLatePacketIsDroppedAndRoundSummaryIncludesUnseenTail() throws {
        let round = try makeRound(profile: 0, seconds: 60)
        var output: [TimedAudioRecord] = []
        let decoder = try makeDecoder(round: round, opus: nil) { record in
            output.append(record)
            return true
        }
        let late = try record(round: round, sequence: round.firstSequence, frameCount: 120,
                              payload: Data(repeating: 0, count: 960), capture: origin)
        decoder.receive(late, mappedCapturedAt: origin, receivedAt: origin + 89_000_000)

        XCTAssertTrue(output.isEmpty)
        let summary = decoder.finish(at: origin + 90_000_000, reason: "test")
        XCTAssertEqual(summary?.latePackets, 1)
        XCTAssertEqual(summary?.missingFrames, 60 * 48_000)
        XCTAssertEqual(summary?.packets, 60 * 400)
        XCTAssertEqual(summary?.received, 1)
        XCTAssertEqual(summary?.wireBytes, 1_002)
    }

    func testOriginalPacketsBetweenTargetAndMaximumDeadlineReachAdaptivePlayout() throws {
        for profile in [0, 1, 2, 7] {
            let round = try makeRound(profile: profile, seconds: 60)
            let clock = TestMonotonicClock(now: origin + 45_000_000)
            let opus = profile >= 2 ? FakeOpusFrameDecoder() : nil
            var output: [TimedAudioRecord] = []
            let decoder = try CompressionMusicDecoder(round: round, streamID: 7,
                budget: PlayoutBudget(targetMilliseconds: 50, maximumMilliseconds: 100,
                                      outputReserveMilliseconds: 10),
                diagnostics: .shared, roundStartedAt: origin, opusDecoder: opus,
                startsTimer: false, monotonicNow: { clock.now }, onDecoded: { record in
                    output.append(record)
                    return true
                })
            let original = try record(round: round, sequence: round.firstSequence,
                frameCount: round.frameCount, payload: Data([8]), capture: origin)

            decoder.receive(original, mappedCapturedAt: origin, receivedAt: clock.now)

            XCTAssertEqual(output.count, round.frameCount / 120, "profile \(profile)")
            let summary = decoder.finish(at: clock.now, reason: "test")
            XCTAssertEqual(summary?.latePackets, 0, "profile \(profile)")
            XCTAssertEqual(summary?.decodedAdmittedFrames, round.frameCount, "profile \(profile)")
        }
    }

    func testSlowOpusDecodeDoesNotAdvanceCodecStateTwiceAfterDeadline() throws {
        let round = try makeRound(profile: 2, seconds: 60)
        let clock = TestMonotonicClock(now: origin + 5_000_000)
        let opus = FakeOpusFrameDecoder { packet in
            if packet != nil { clock.now += 90_000_000 }
        }
        var output: [TimedAudioRecord] = []
        let decoder = try CompressionMusicDecoder(round: round, streamID: 7,
            budget: PlayoutBudget(targetMilliseconds: 50, maximumMilliseconds: 100,
                                  outputReserveMilliseconds: 10),
            diagnostics: .shared, roundStartedAt: origin, opusDecoder: opus,
            startsTimer: false, monotonicNow: { clock.now }, onDecoded: { record in
                output.append(record)
                return true
            })
        let packet = try record(round: round, sequence: round.firstSequence, frameCount: 120,
                                payload: Data([8]), capture: origin)
        decoder.receive(packet, mappedCapturedAt: origin, receivedAt: clock.now)

        XCTAssertEqual(opus.calls.map(\.isPLC), [false])
        XCTAssertTrue(output.isEmpty)
        let summary = decoder.finish(at: clock.now, reason: "test")
        XCTAssertEqual(summary?.latePackets, 1)
    }

    func testRoundCompletenessRequiresElapsedDurationBudgetAndNormalBoundary() throws {
        let round = try makeRound(profile: 0, seconds: 60)
        let decoder = try makeDecoder(round: round, opus: nil) { _ in true }
        let threshold = origin + 60_100_000_000
        XCTAssertFalse(decoder.finish(at: threshold, reason: "cancelled")?.complete ?? true)

        let completeRound = try makeRound(profile: 0, seconds: 60)
        let completeDecoder = try makeDecoder(round: completeRound, opus: nil) { _ in true }
        XCTAssertTrue(completeDecoder.finish(at: threshold, reason: "diagnostics_end")?.complete ?? false)
    }

    func testFinishDoesNotDecodeOrAdmitPendingRecordsAfterReceiverDetachesRound() throws {
        let round = try makeRound(profile: 2, seconds: 60)
        let opus = FakeOpusFrameDecoder()
        var output: [TimedAudioRecord] = []
        let decoder = try makeDecoder(round: round, opus: opus) { record in
            output.append(record)
            return true
        }
        let reordered = try record(round: round, sequence: round.firstSequence + 1,
                                   frameCount: 120, payload: Data([9]),
                                   capture: origin + 2_500_000)
        decoder.receive(reordered, mappedCapturedAt: origin + 2_500_000,
                        receivedAt: origin + 10_000_000)

        let summary = decoder.finish(at: origin + 100_000_000, reason: "next_round")

        XCTAssertNotNil(summary)
        XCTAssertTrue(opus.calls.isEmpty)
        XCTAssertTrue(output.isEmpty)
    }

    func testRealOpusDecoderHandlesEveryConfiguredBitrateAndFrameDuration() throws {
        for profile in 2..<8 {
            let round = try makeRound(profile: profile, seconds: 60)
            let frameCount = round.frameCount
            var error: Int32 = 0
            guard let encoder = hp_opus_encoder_create(Int32(round.bitrateKbps * 1_000), &error) else {
                XCTFail("Opus encoder creation failed for profile \(profile): \(error)")
                return
            }
            defer { hp_opus_encoder_destroy(encoder) }
            XCTAssertEqual(Int(hp_opus_lookahead(encoder)), round.codecLookaheadFrames)

            let samples = (0..<(frameCount * 2)).map { index in
                Float(sin(Double(index / 2) * 2 * Double.pi * 440 / 48_000) * 0.15)
            }
            var packet = [UInt8](repeating: 0, count: 992)
            let encodedCount = samples.withUnsafeBufferPointer { input in
                packet.withUnsafeMutableBufferPointer { bytes in
                    hp_opus_encode(encoder, input.baseAddress, Int32(frameCount),
                                   bytes.baseAddress, Int32(bytes.count))
                }
            }
            XCTAssertGreaterThan(encodedCount, 0, "profile \(profile)")

            let timed = try record(round: round, sequence: round.firstSequence,
                frameCount: frameCount, payload: Data(packet.prefix(Int(encodedCount))), capture: origin)
            var output: [TimedAudioRecord] = []
            let decoder = try makeDecoder(round: round, opus: nil) { record in
                output.append(record)
                return true
            }
            decoder.receive(timed, mappedCapturedAt: origin, receivedAt: origin + 5_000_000)

            XCTAssertEqual(output.count, frameCount / 120, "profile \(profile)")
            XCTAssertTrue(output.allSatisfy { $0.payload.count == 960 && $0.payload.contains { $0 != 0 } },
                          "profile \(profile) produced no decoded PCM")
        }
    }

    private func makeDecoder(round: MusicTestRound, opus: CompressionOpusFrameDecoding?,
                             onDecoded: @escaping (TimedAudioRecord) -> Bool) throws -> CompressionMusicDecoder {
        try CompressionMusicDecoder(round: round, streamID: 7,
            budget: PlayoutBudget(targetMilliseconds: 50, maximumMilliseconds: 100,
                                  outputReserveMilliseconds: 10),
            diagnostics: .shared, roundStartedAt: origin, opusDecoder: opus,
            startsTimer: false, monotonicNow: { origin + 10_000_000 }, onDecoded: onDecoded)
    }

    private func makeRound(profile: Int, seconds: Int) throws -> MusicTestRound {
        let frames = [120, 120, 120, 240, 480, 120, 240, 480][profile]
        let bitrate = [0, 0, 192, 192, 192, 256, 256, 256][profile]
        var bytes = Data([4, 1, 32, 3, UInt8(seconds >> 8), UInt8(seconds & 0xff),
                          UInt8(profile), 1, 0, 0, 0, 0, 0, 0, 0, 1])
        let lookahead = profile < 2 ? 0 : 120
        bytes.append(contentsOf: [UInt8(frames >> 8), UInt8(frames & 0xff),
                                  UInt8(bitrate >> 8), UInt8(bitrate & 0xff),
                                  UInt8(lookahead >> 8), UInt8(lookahead & 0xff), 0, 0])
        return try MusicTestRound(encoded: bytes)
    }

    private func record(round: MusicTestRound, sequence: UInt32, frameCount: Int,
                        payload: Data, capture: UInt64) throws -> TimedAudioRecord {
        let kind: AudioRecordKind = round.profile == 0 ? .audio :
            (round.profile == 1 ? .pcm16 : .opus)
        let actualPayload: Data
        if round.profile == 0 && payload.count != 960 {
            actualPayload = Data(repeating: 0, count: 960)
        } else if round.profile == 1 && payload.count != 480 {
            actualPayload = Data(repeating: 0, count: 480)
        } else {
            actualPayload = payload
        }
        return try TimedAudioRecord(streamID: 7, generation: round.generation,
            sequence: sequence, frameCount: UInt16(frameCount), kind: kind, capturedAt: capture,
            sourceFrame: UInt64(sequence) * 120, payload: actualPayload)
    }
}

private final class FakeOpusFrameDecoder: CompressionOpusFrameDecoding {
    struct Call {
        let packet: Data?
        let frameCount: Int
        var isPLC: Bool { packet == nil }
    }

    private(set) var calls: [Call] = []
    private let onDecode: (Data?) -> Void
    var packetIDs: [UInt8] { calls.compactMap { $0.packet?.first } }

    init(onDecode: @escaping (Data?) -> Void = { _ in }) { self.onDecode = onDecode }

    func decode(packet: Data?, frameCount: Int) -> [Float]? {
        calls.append(Call(packet: packet, frameCount: frameCount))
        onDecode(packet)
        return Array(repeating: packet?.first.map { Float($0) / 255 } ?? 0,
                     count: frameCount * 2)
    }
}

private final class TestMonotonicClock {
    var now: UInt64
    init(now: UInt64) { self.now = now }
}
