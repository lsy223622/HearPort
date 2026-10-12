import Foundation

public struct CoordinatedProbePlan: Sendable {
    public struct Round: Sendable {
        public let payloadBytes, packetsPerSecond, burstPackets, variant: Int
        public let reliable: Bool
        public let repeatIndex, controller, repair, correctionPercent: Int
        public var framesPerPacket: Int { 48_000 / packetsPerSecond }
    }
    public let rounds: [Round]
    public var durationSeconds: Int { rounds.count * 30 + 10 }

    public init(encoded: Data) throws {
        guard encoded.count >= 4, encoded[0] == 1, encoded[2] == 30,
              (1...100).contains(Int(encoded[1])), encoded.count == 4 + Int(encoded[1]) * 12
        else { throw ControlMessageError.invalidMessage }
        var result: [Round] = []
        for start in stride(from: 4, to: encoded.count, by: 12) {
            let bytes = Int(encoded[start]) * 256 + Int(encoded[start + 1])
            let rate = Int(encoded[start + 2]) * 256 + Int(encoded[start + 3])
            let burst = Int(encoded[start + 4]), variant = Int(encoded[start + 5])
            let reliable = encoded[start + 6], repeated = Int(encoded[start + 7])
            let controller = Int(encoded[start + 8]), repair = Int(encoded[start + 9])
            let correction = Int(encoded[start + 10])
            guard [512, 992].contains(bytes), [200, 400].contains(rate),
                  [1, 4].contains(burst), variant < 5, reliable <= 1,
                  [1, 2].contains(repeated), (0...3).contains(controller), (0...3).contains(repair),
                  reliable == 0 || repair == 0, [5, 10].contains(correction)
            else { throw ControlMessageError.invalidMessage }
            result.append(Round(payloadBytes: bytes, packetsPerSecond: rate, burstPackets: burst,
                variant: variant, reliable: reliable == 1, repeatIndex: repeated,
                controller: controller, repair: repair, correctionPercent: correction))
        }
        rounds = result
    }
}

struct ProbeConsumption: Sendable {
    let playedFrames: Int
    let concealedFrames: Int
    let waitingFrames: Int
    let skippedFrames: UInt64
    let correction: Double
    let targetMilliseconds: Double
    let sourceAgeMilliseconds: Double?
}

struct ProbeConsumer: Sendable {
    private struct Packet: Sendable { let record: TimedAudioRecord; let captured: UInt64; let uncertainty: UInt64 }
    let round: CoordinatedProbePlan.Round
    let budget: PlayoutBudget
    private var control: PlayoutController
    private var packets: [UInt32: Packet] = [:]
    private var nextSequence: UInt32
    private var sourceFrame: UInt64
    private let endSourceFrame: UInt64
    private var offset = 0
    private var fractionalFrames = 0.0
    private var running = false
    private var lastTick: UInt64?
    private(set) var generation: UInt32 = 0
    private(set) var repairedPackets = 0
    private(set) var latestReceivedSequence: UInt32?
    private(set) var playedSourceFrame: UInt64?
    private var repair = RepairWindow()

    init(round: CoordinatedProbePlan.Round, budget: PlayoutBudget,
         firstSequence: UInt32, sourceFrame: UInt64) {
        self.round = round; self.budget = budget
        nextSequence = firstSequence; self.sourceFrame = sourceFrame
        endSourceFrame = sourceFrame + 30 * 48_000
        control = PlayoutController(budget: budget,
            maximumCorrection: round.controller == 0 ? 0 : Double(round.correctionPercent) / 100,
            adaptive: round.controller >= 2)
    }

    var bufferedFrames: Int {
        var sequence = nextSequence, result = -offset
        while let packet = packets[sequence], result < 96_000 {
            result += Int(packet.record.frameCount); sequence = SequenceNumber.next(sequence)
        }
        return max(0, result)
    }

    mutating func receive(_ record: TimedAudioRecord, capturedAt: UInt64,
                          uncertainty: UInt64, now: UInt64) {
        guard capturedAt <= now + uncertainty,
              (!SequenceNumber.isBefore(record.sequence, nextSequence) ||
               (record.kind == .fec && !SequenceNumber.isBefore(record.sequence &+ 3, nextSequence))),
              record.kind == .fec || Int(record.frameCount) == round.framesPerPacket,
              record.kind == .fec || record.payload.count + 32 == round.payloadBytes else { return }
        if generation != record.generation {
            if generation != 0, SequenceNumber.isBefore(record.generation, generation) { return }
            if generation != 0 {
                packets.removeAll(keepingCapacity: true); repair.reset()
                nextSequence = record.sequence; sourceFrame = record.sourceFrame; offset = 0
                running = false; fractionalFrames = 0; playedSourceFrame = nil
                control = PlayoutController(budget: budget,
                    maximumCorrection: round.controller == 0 ? 0 : Double(round.correctionPercent) / 100,
                    adaptive: round.controller >= 2)
            }
            generation = record.generation
        }
        let deadline = budget.prepareDeadline(capturedAt: capturedAt, uncertaintyNanoseconds: uncertainty)
        guard deadline > now else { return }
        if round.repair == 1 {
            for recovered in repair.ingest(record, deadline: deadline, now: now) {
                let delta = (Double(recovered.sourceFrame) - Double(record.sourceFrame)) / 48_000 * 1e9
                let capture = max(0, Double(capturedAt) + delta)
                insert(recovered, capturedAt: UInt64(capture), uncertainty: uncertainty, now: now)
            }
        }
        guard record.kind != .fec else { return }
        insert(record, capturedAt: capturedAt, uncertainty: uncertainty, now: now)
    }

    private mutating func insert(_ record: TimedAudioRecord, capturedAt: UInt64,
                                 uncertainty: UInt64, now: UInt64) {
        guard packets[record.sequence] == nil, packets.count < 1_024,
              !SequenceNumber.isBefore(record.sequence, nextSequence),
              budget.prepareDeadline(capturedAt: capturedAt, uncertaintyNanoseconds: uncertainty) > now
        else { return }
        if record.kind == .retransmission || record.kind == .repeated { repairedPackets += 1 }
        packets[record.sequence] = Packet(record: record, captured: capturedAt, uncertainty: uncertainty)
        if latestReceivedSequence == nil || SequenceNumber.isBefore(latestReceivedSequence!, record.sequence) {
            latestReceivedSequence = record.sequence
        }
        control.observeArrival(sourceFrame: record.sourceFrame, capturedAt: capturedAt,
            receivedAt: now, original: record.kind == .probe)
    }

    mutating func requestRepair(now: UInt64, roundTrip: UInt64) -> (UInt32, UInt32)? {
        guard round.repair == 2, packets[nextSequence] == nil, !packets.isEmpty,
              let capture = control.captureTime(sourceFrame: sourceFrame) else { return nil }
        let deadline = budget.prepareDeadline(capturedAt: capture)
        guard repair.shouldRequest(sequence: nextSequence, now: now, deadline: deadline,
                                   roundTripNanoseconds: roundTrip) else { return nil }
        return (nextSequence, UInt32(min(2_000, (deadline - now) / 1_000_000)))
    }

    mutating func tick(now: UInt64) -> ProbeConsumption {
        let elapsed = lastTick.map { now >= $0 ? Double(now - $0) / 1e9 : 0 } ?? 0.005
        lastTick = now
        let decision = control.decision(now: now, nextSourceFrame: sourceFrame,
            playableFrames: bufferedFrames, stagedSourceFrames: 0, hasFuturePacket: !packets.isEmpty)
        var skipped: UInt64 = 0
        if decision.action == .resync {
            let valid = packets.values.filter {
                budget.prepareDeadline(capturedAt: $0.captured, uncertaintyNanoseconds: $0.uncertainty) > now
            }.min { ($0.record.sequence &- nextSequence) < ($1.record.sequence &- nextSequence) }
            if let valid, valid.record.sourceFrame >= sourceFrame {
                skipped = valid.record.sourceFrame - sourceFrame
                sourceFrame = valid.record.sourceFrame; nextSequence = valid.record.sequence; offset = 0
            }
            packets = packets.filter { !SequenceNumber.isBefore($0.key, nextSequence) &&
                budget.prepareDeadline(capturedAt: $0.value.captured,
                    uncertaintyNanoseconds: $0.value.uncertainty) > now }
        }
        if !running, bufferedFrames >= max(round.framesPerPacket, Int(decision.bufferTargetMilliseconds * 48)) {
            running = true
        }
        guard running else {
            return ProbeConsumption(playedFrames: 0, concealedFrames: 0, waitingFrames: Int(min(2, elapsed) * 48_000), skippedFrames: skipped,
                correction: decision.correction, targetMilliseconds: decision.targetMilliseconds,
                sourceAgeMilliseconds: nil)
        }
        fractionalFrames += min(2, elapsed) * 48_000 * (1 + decision.correction)
        var wanted = Int(fractionalFrames), played = 0, concealed = 0
        fractionalFrames -= Double(wanted)
        wanted = min(wanted, Int(endSourceFrame - min(endSourceFrame, sourceFrame)))
        var age: Double?
        while wanted > 0 {
            let packet = packets[nextSequence]
            let count = min(wanted, round.framesPerPacket - offset)
            let capture = packet.map { $0.captured + UInt64(offset) * 1_000_000_000 / 48_000 }
            if let packet, let capture,
               budget.prepareDeadline(capturedAt: capture, uncertaintyNanoseconds: packet.uncertainty) > now {
                played += count
                if age == nil { age = now >= capture ? Double(now - capture) / 1e6 : 0 }
            } else { concealed += count }
            wanted -= count; offset += count; sourceFrame += UInt64(count)
            if offset == round.framesPerPacket {
                packets.removeValue(forKey: nextSequence)
                nextSequence = SequenceNumber.next(nextSequence); offset = 0
            }
        }
        playedSourceFrame = sourceFrame
        return ProbeConsumption(playedFrames: played, concealedFrames: concealed, waitingFrames: 0, skippedFrames: skipped,
            correction: decision.correction, targetMilliseconds: decision.targetMilliseconds,
            sourceAgeMilliseconds: age)
    }
}
