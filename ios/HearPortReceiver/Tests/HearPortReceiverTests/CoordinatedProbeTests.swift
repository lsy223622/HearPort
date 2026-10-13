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

    func testNewEpochClearsFeedbackEvenWhenItsFirstPacketIsBehindCursor() throws {
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
        let record = try TimedAudioRecord(streamID: 7, generation: 2, sequence: 0,
            frameCount: 120, kind: .probe, capturedAt: 1_000_000_000,
            sourceFrame: 0, payload: Data(repeating: 1, count: 960))
        consumer.receive(record, capturedAt: record.capturedAt, uncertainty: 0, now: 1_020_000_000)
        XCTAssertEqual(consumer.generation, 2)
        XCTAssertNil(consumer.latestReceivedSequence)
        XCTAssertNil(consumer.playedSourceFrame)
        XCTAssertEqual(consumer.bufferedFrames, 0)
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
