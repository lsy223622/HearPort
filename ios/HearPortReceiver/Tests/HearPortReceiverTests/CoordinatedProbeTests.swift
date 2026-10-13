import XCTest
@testable import HearPortReceiver

final class CoordinatedProbeTests: XCTestCase {
    func testSharedManifestPreservesPolicyAndRejectsInvalidPlans() throws {
        let bytes = Data([1, 1, 30, 0, 3, 224, 1, 144, 1, 1, 0, 1, 2, 1, 5, 0])
        let plan = try CoordinatedProbePlan(encoded: bytes)
        XCTAssertEqual(plan.rounds.count, 1)
        XCTAssertEqual(plan.durationSeconds, 40)
        XCTAssertEqual(plan.rounds[0].payloadBytes, 992)
        XCTAssertEqual(plan.rounds[0].repair, 1)
        let envelope = ControlEnvelope(.probeManifest(streamID: 7, manifest: bytes))
        XCTAssertEqual(try ControlEnvelope.decode(envelope.encoded()), envelope)
        var invalid = bytes
        invalid[10] = 1
        XCTAssertThrowsError(try CoordinatedProbePlan(encoded: invalid))
    }

    func testVirtualConsumerCountsContiguousSourceOnceAndRejectsFutureAudio() throws {
        let plan = try CoordinatedProbePlan(encoded: Data([1, 1, 30, 0, 3, 224, 1, 144, 1, 1, 0, 1, 2, 0, 5, 0]))
        let budget = try PlayoutBudget(targetMilliseconds: 10, maximumMilliseconds: 100,
                                       outputReserveMilliseconds: 1)
        var consumer = ProbeConsumer(round: plan.rounds[0], budget: budget,
                                     firstSequence: 0, sourceFrame: 0)
        for sequence in [0, 2, 3, 2] {
            let captured = UInt64(1_000_000_000) + UInt64(sequence) * 2_500_000
            let record = try TimedAudioRecord(streamID: 7, generation: 1, sequence: UInt32(sequence),
                frameCount: 120, kind: .probe, capturedAt: captured,
                sourceFrame: UInt64(sequence) * 120, payload: Data(repeating: 1, count: 960))
            consumer.receive(record, capturedAt: captured, uncertainty: 0, now: 1_010_000_000)
        }
        XCTAssertEqual(consumer.bufferedFrames, 120)
        let future = try TimedAudioRecord(streamID: 7, generation: 1, sequence: 1,
            frameCount: 120, kind: .probe, capturedAt: 2_000_000_000, sourceFrame: 120,
            payload: Data(repeating: 1, count: 960))
        consumer.receive(future, capturedAt: 2_000_000_000, uncertainty: 0, now: 1_010_000_000)
        XCTAssertEqual(consumer.bufferedFrames, 120)
        XCTAssertEqual(consumer.tick(now: 1_010_000_000).playedFrames, 0)
        let missing = try TimedAudioRecord(streamID: 7, generation: 1, sequence: 1,
            frameCount: 120, kind: .probe, capturedAt: 1_002_500_000, sourceFrame: 120,
            payload: Data(repeating: 1, count: 960))
        consumer.receive(missing, capturedAt: missing.capturedAt, uncertainty: 0, now: 1_010_000_000)
        XCTAssertEqual(consumer.bufferedFrames, 480)
        _ = consumer.tick(now: 1_015_000_000)
        XCTAssertGreaterThan(consumer.playedSourceFrame ?? 0, 0)
    }
    func testFutureHoleRequestsRepairBeforeItIsConsumedAndOnlyOnce() throws {
        let plan = try CoordinatedProbePlan(encoded: Data([1, 1, 30, 0, 3, 224, 1, 144, 1, 1, 0, 1, 2, 2, 5, 0]))
        let budget = try PlayoutBudget(targetMilliseconds: 50, maximumMilliseconds: 100,
                                       outputReserveMilliseconds: 1)
        var consumer = ProbeConsumer(round: plan.rounds[0], budget: budget,
                                     firstSequence: 0, sourceFrame: 0)
        for sequence in 0...10 where sequence != 4 {
            let captured = UInt64(1_000_000_000) + UInt64(sequence) * 2_500_000
            let record = try TimedAudioRecord(streamID: 7, generation: 1, sequence: UInt32(sequence),
                frameCount: 120, kind: .probe, capturedAt: captured,
                sourceFrame: UInt64(sequence) * 120, payload: Data(repeating: 1, count: 960))
            consumer.receive(record, capturedAt: captured, uncertainty: 5_000_000, now: 1_030_000_000)
        }
        XCTAssertNil(consumer.requestRepair(now: 1_030_000_000, roundTrip: 4_000_000))
        _ = consumer.tick(now: 1_030_000_000)
        XCTAssertEqual(consumer.requestRepair(now: 1_035_000_000, roundTrip: 4_000_000)?.0, 4)
        XCTAssertNil(consumer.requestRepair(now: 1_040_000_000, roundTrip: 4_000_000))
        XCTAssertNil(consumer.playedSourceFrame)
    }

    func testNewEpochConfirmsConsumedReplayWithoutRewindingPlayback() throws {
        let plan = try CoordinatedProbePlan(encoded: Data([1, 1, 30, 0, 3, 224, 1, 144, 1, 1, 0, 1, 0, 0, 5, 0]))
        let budget = try PlayoutBudget(targetMilliseconds: 5, maximumMilliseconds: 100,
                                       outputReserveMilliseconds: 1)
        var consumer = ProbeConsumer(round: plan.rounds[0], budget: budget,
                                     firstSequence: 0, sourceFrame: 0)
        for sequence in 0...4 {
            let capture = UInt64(1_000_000_000) + UInt64(sequence) * 2_500_000
            let record = try TimedAudioRecord(streamID: 7, generation: 1, sequence: UInt32(sequence),
                frameCount: 120, kind: .probe, capturedAt: capture,
                sourceFrame: UInt64(sequence) * 120, payload: Data(repeating: 1, count: 960))
            consumer.receive(record, capturedAt: capture, uncertainty: 0, now: 1_010_000_000)
        }
        _ = consumer.tick(now: 1_010_000_000)
        let played = consumer.playedSourceFrame
        let record = try TimedAudioRecord(streamID: 7, generation: 2, sequence: 0,
            frameCount: 120, kind: .probe, capturedAt: 1_000_000_000,
            sourceFrame: 0, payload: Data(repeating: 1, count: 960))
        consumer.receive(record, capturedAt: record.capturedAt, uncertainty: 0, now: 1_020_000_000)
        XCTAssertEqual(consumer.generation, 2)
        XCTAssertEqual(consumer.latestReceivedSequence, 0)
        XCTAssertEqual(consumer.playedSourceFrame, played)
        XCTAssertGreaterThan(consumer.bufferedFrames, 0)
        let result = consumer.tick(now: 1_025_000_000)
        XCTAssertEqual(result.waitingFrames, 0)
        XCTAssertGreaterThanOrEqual(consumer.playedSourceFrame ?? 0, played ?? 0)
    }

    func testExpiredDeliveryIsConfirmedWithoutBecomingPlayable() throws {
        let plan = try CoordinatedProbePlan(encoded: Data([1, 1, 30, 0, 3, 224, 1, 144, 1, 1, 1, 1, 0, 0, 5, 0]))
        let budget = try PlayoutBudget(targetMilliseconds: 50, maximumMilliseconds: 100,
                                       outputReserveMilliseconds: 1)
        var consumer = ProbeConsumer(round: plan.rounds[0], budget: budget,
                                     firstSequence: 0, sourceFrame: 0)
        let record = try TimedAudioRecord(streamID: 7, generation: 1, sequence: 0,
            frameCount: 120, kind: .probe, capturedAt: 1_000_000_000,
            sourceFrame: 0, payload: Data(repeating: 1, count: 960))
        consumer.receive(record, capturedAt: record.capturedAt, uncertainty: 0, now: 1_100_000_000)
        XCTAssertEqual(consumer.latestReceivedSequence, 0)
        XCTAssertEqual(consumer.bufferedFrames, 0)
        XCTAssertEqual(consumer.tick(now: 1_100_000_000).playedFrames, 0)

        let staleGeneration = try TimedAudioRecord(streamID: 7, generation: 2, sequence: 1,
            frameCount: 120, kind: .retransmission, capturedAt: 1_002_500_000,
            sourceFrame: 120, payload: Data(repeating: 1, count: 960))
        consumer.receive(staleGeneration, capturedAt: staleGeneration.capturedAt, uncertainty: 0,
                         now: 1_110_000_000)
        consumer.receive(record, capturedAt: record.capturedAt, uncertainty: 0, now: 1_110_000_000)
        XCTAssertEqual(consumer.generation, 2)
        XCTAssertEqual(consumer.latestReceivedSequence, 1)
        XCTAssertEqual(consumer.bufferedFrames, 0)
    }

    func testExpiredNewEpochPacketPreservesUnexpiredStagedPlayback() throws {
        let plan = try CoordinatedProbePlan(encoded: Data([1, 1, 30, 0, 3, 224, 1, 144, 1, 1, 1, 1, 0, 0, 5, 0]))
        let budget = try PlayoutBudget(targetMilliseconds: 10, maximumMilliseconds: 100,
                                       outputReserveMilliseconds: 1)
        var consumer = ProbeConsumer(round: plan.rounds[0], budget: budget,
                                     firstSequence: 32, sourceFrame: 32 * 120)
        for sequence in 32...40 {
            let capture = UInt64(1_000_000_000) + UInt64(sequence) * 2_500_000
            let record = try TimedAudioRecord(streamID: 7, generation: 1, sequence: UInt32(sequence),
                frameCount: 120, kind: .probe, capturedAt: capture,
                sourceFrame: UInt64(sequence) * 120, payload: Data(repeating: 1, count: 960))
            consumer.receive(record, capturedAt: capture, uncertainty: 0, now: 1_110_000_000)
        }
        XCTAssertGreaterThan(consumer.tick(now: 1_110_000_000).playedFrames, 0)
        let played = consumer.playedSourceFrame
        let expired = try TimedAudioRecord(streamID: 7, generation: 2, sequence: 0,
            frameCount: 120, kind: .retransmission, capturedAt: 1_000_000_000,
            sourceFrame: 0, payload: Data(repeating: 1, count: 960))
        consumer.receive(expired, capturedAt: expired.capturedAt, uncertainty: 0, now: 1_110_000_000)
        XCTAssertEqual(consumer.latestReceivedSequence, 0)
        XCTAssertEqual(consumer.playedSourceFrame, played)
        let result = consumer.tick(now: 1_115_000_000)
        XCTAssertGreaterThan(result.playedFrames, 0)
        XCTAssertEqual(result.waitingFrames, 0)
        XCTAssertEqual(consumer.repairedPackets, 0)
    }

    func testNewEpochRetainsOnlyBoundedStagedOutput() throws {
        let plan = try CoordinatedProbePlan(encoded: Data([1, 1, 30, 0, 3, 224, 1, 144, 1, 1, 1, 1, 0, 0, 5, 0]))
        let budget = try PlayoutBudget(targetMilliseconds: 50, maximumMilliseconds: 100,
                                       outputReserveMilliseconds: 1)
        var consumer = ProbeConsumer(round: plan.rounds[0], budget: budget,
                                     firstSequence: 0, sourceFrame: 0)
        for sequence in 0...24 {
            let capture = UInt64(1_000_000_000) + UInt64(sequence) * 2_500_000
            let record = try TimedAudioRecord(streamID: 7, generation: 1, sequence: UInt32(sequence),
                frameCount: 120, kind: .probe, capturedAt: capture,
                sourceFrame: UInt64(sequence) * 120, payload: Data(repeating: 1, count: 960))
            consumer.receive(record, capturedAt: capture, uncertainty: 0, now: 1_060_000_000)
        }
        _ = consumer.tick(now: 1_060_000_000)
        XCTAssertGreaterThan(consumer.bufferedFrames, 2_048)
        let replay = try TimedAudioRecord(streamID: 7, generation: 2, sequence: 0,
            frameCount: 120, kind: .retransmission, capturedAt: 1_000_000_000,
            sourceFrame: 0, payload: Data(repeating: 1, count: 960))
        consumer.receive(replay, capturedAt: replay.capturedAt, uncertainty: 0, now: 1_060_000_000)
        XCTAssertEqual(consumer.bufferedFrames, 2_040)
        XCTAssertEqual(consumer.repairedPackets, 0)
    }

    func testManifestCarriesRecoveryOutsideMeasuredSourceDuration() throws {
        let round: [UInt8] = [3, 224, 1, 144, 1, 1, 0, 1, 2, 0, 5, 0]
        let plan = try CoordinatedProbePlan(encoded: Data([2, 2, 30, 5] + round + round))
        XCTAssertEqual(plan.recoverySeconds, 5)
        XCTAssertEqual(plan.activeDurationSeconds, 65)
        XCTAssertEqual(plan.durationSeconds, 75)
        XCTAssertThrowsError(try CoordinatedProbePlan(encoded: Data([2, 2, 30, 11] + round + round)))
    }

}
