import Foundation

private let captureStart: UInt64 = 1_000_000_000
private let packetInterval: UInt64 = 2_500_000
private let packetCount = 12_000
private let totalFrames = packetCount * 120
var offlineDeadlineGuardMilliseconds = 0.0
var offlineKeepController = false
var offlineKeepBuffer = false
var offlineKeepTarget = false
var offlineKeepHistory = false
var offlineKeepRate = false
var offlineKeepAnchor = false
struct OfflineProbeAudit {
    var discardedSequences: Set<UInt32> = []
    var expiredSequences: Set<UInt32> = []
    var networkMissingFrames = 0, expiredQueuedFrames = 0, discardedMissingFrames = 0
    var lateArrivalFrames = 0, rejectedExpiredPackets = 0, droppedBufferedFrames = 0
    var receivedAfterConsumptionPackets = 0
}
var offlineProbeAudit = OfflineProbeAudit()

private enum Experiment: String, CaseIterable {
    case baseline, keepController = "keep_controller", keepBuffer = "keep_buffer"
    case noReplay = "no_replay", keepBoth = "keep_both", controllerNoReplay = "controller_no_replay"
    case keepAll = "keep_all", fixedConsumer = "fixed_consumer"
    case keepTarget = "keep_target", keepHistory = "keep_history", keepRate = "keep_rate"
    case keepAnchor = "keep_anchor", keepTargetHistory = "keep_target_history"
    var keepsController: Bool { [.keepController, .keepBoth, .controllerNoReplay, .keepAll].contains(self) }
    var keepsBuffer: Bool { [.keepBuffer, .keepBoth, .keepAll].contains(self) }
    var replays: Bool { ![.noReplay, .controllerNoReplay, .keepAll].contains(self) }
}

private struct RandomSource {
    var state: UInt64
    mutating func next(_ bound: UInt64) -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return (value ^ (value >> 31)) % bound
    }
}

private enum Scenario: String, CaseIterable {
    case healthy, jitter, isolatedLoss = "isolated_loss", weakWifi = "weak_wifi", longOutage = "long_outage"
}

private struct NetworkPacket {
    let sequence: Int
    let captured, arrived, retryDelay, jitter: UInt64
    let lost: Bool
}

private struct NetworkTrace {
    let packets: [NetworkPacket]
    let fingerprint: String
    let pauses: [(UInt64, UInt64)]
    let seed: UInt64

    static func make(_ scenario: Scenario, seed: UInt64) -> NetworkTrace {
        var random = RandomSource(state: seed)
        var pauses: [(UInt64, UInt64)] = []
        if scenario == .jitter || scenario == .weakWifi {
            for index in 1..<40 {
                let start = UInt64(index) * 750_000_000 + random.next(150_000_000)
                let duration = 10_000_000 + random.next(scenario == .weakWifi ? 170_000_000 : 50_000_000)
                pauses.append((captureStart + start, captureStart + start + duration))
            }
        }
        if scenario == .longOutage {
            pauses = [(captureStart + 10_000_000_000, captureStart + 10_500_000_000),
                      (captureStart + 20_000_000_000, captureStart + 20_800_000_000)]
        }
        var fingerprint: UInt64 = 0xcbf29ce484222325
        var packets: [NetworkPacket] = []
        for sequence in 0..<packetCount {
            let captured = captureStart + UInt64(sequence) * packetInterval
            let jitter = random.next(scenario == .weakWifi || scenario == .jitter ? 12_000_000 : 3_000_000)
            let lossDraw = random.next(10_000)
            let retryDelay = 60_000_000 + random.next(100_000_000)
            var arrived = captured + 6_000_000 + jitter
            for (start, end) in pauses where captured >= start && captured < end {
                arrived = end + 6_000_000 + jitter
            }
            let lost = (scenario == .isolatedLoss && lossDraw < 50) ||
                       (scenario == .weakWifi && lossDraw < 40)
            packets.append(NetworkPacket(sequence: sequence, captured: captured,
                arrived: arrived, retryDelay: retryDelay, jitter: jitter, lost: lost))
            for value in [UInt64(sequence), captured, arrived, retryDelay, lost ? 1 : 0] {
                fingerprint = (fingerprint ^ value) &* 0x100000001b3
            }
        }
        return NetworkTrace(packets: packets, fingerprint: String(fingerprint, radix: 16),
                            pauses: pauses, seed: seed)
    }

    func returnArrival(generated: UInt64) -> UInt64 {
        var random = RandomSource(state: seed ^ generated ^ 0xa0761d6478bd642f)
        var sent = generated
        for (start, end) in pauses where generated >= start && generated < end { sent = end }
        return sent + 20_000_000 + random.next(20_000_000)
    }

    func originalArrival(_ packet: NetworkPacket, sent: UInt64) -> UInt64 {
        var released = sent
        for (start, end) in pauses where sent >= start && sent < end { released = end }
        return released + 6_000_000 + packet.jitter + (packet.lost ? packet.retryDelay : 0)
    }

    func replayArrival(sequence: Int, attempt: Int, sent: UInt64, scenario: Scenario) -> UInt64 {
        var random = RandomSource(state: seed ^ UInt64(sequence) &* 0xe7037ed1a0b428db ^ UInt64(attempt))
        var released = sent
        for (start, end) in pauses where sent >= start && sent < end { released = end }
        let jitter = random.next(scenario == .weakWifi || scenario == .jitter ? 12_000_000 : 3_000_000)
        let loss = random.next(10_000)
        let lost = (scenario == .isolatedLoss && loss < 50) || (scenario == .weakWifi && loss < 40)
        return released + 6_000_000 + jitter + (lost ? 60_000_000 + random.next(100_000_000) : 0)
    }

    func deliveries(reliable: Bool, sendMegabitsPerSecond: Double = 0) -> [NetworkPacket] {
        var lastArrival: UInt64 = 0
        var sendFinished = captureStart
        let serialization = sendMegabitsPerSecond > 0 ? UInt64(992 * 8 * 1_000 / sendMegabitsPerSecond) : 0
        var result: [NetworkPacket] = []
        for packet in packets {
            sendFinished = max(sendFinished, packet.captured) + serialization
            if packet.lost && !reliable { continue }
            let candidate = originalArrival(packet, sent: sendFinished)
            let arrived = reliable ? max(candidate, lastArrival) : candidate
            lastArrival = arrived
            result.append(NetworkPacket(sequence: packet.sequence, captured: packet.captured,
                arrived: arrived, retryDelay: packet.retryDelay, jitter: packet.jitter, lost: packet.lost))
        }
        return result.sorted { lhs, rhs in
            lhs.arrived == rhs.arrived ? lhs.sequence < rhs.sequence : lhs.arrived < rhs.arrived
        }
    }
}

private enum Policy: String, CaseIterable {
    case fixed, speedOnly = "speed_only", bufferOnly = "buffer_only", adaptive, guarded
    var controller: Int { self == .fixed ? 0 : (self == .speedOnly ? 1 : 2) }
    var correctionPercent: Int { self == .fixed || self == .bufferOnly ? 0 : 5 }
}

private enum Transport: String, CaseIterable {
    case datagram, hol = "reliable_hol_model", legacy = "reliable_legacy_recovery"
    case corrected = "reliable_corrected_recovery"
    var reliable: Bool { self != .datagram }
    var recovery: Bool { self == .legacy || self == .corrected }
}

private struct Delivery {
    let packet: NetworkPacket
    let generation: UInt32
    let replayed: Bool
    let arrived: UInt64
}

private struct Feedback {
    let generation: UInt32
    let received: UInt32
    let played, generated, arrived: UInt64
}

private struct Result: Codable, Equatable {
    let scenario, transport, policy, inputFingerprint, experiment: String
    let seed: UInt64
    let targetMilliseconds, maximumMilliseconds: Double
    let feedbackIntervalMilliseconds, restartDelayMilliseconds: Int
    let recoveryLeadMilliseconds: Int
    let sendMegabitsPerSecond: Double
    let lostPackets, playedFrames, concealedFrames, unfinishedFrames: Int
    let skippedFrames: UInt64
    let unavailableSourcePercent: Double
    let firstConsumptionMilliseconds: Double?
    let p50PresentationMilliseconds, p99PresentationMilliseconds, maxPresentationMilliseconds: Double?
    let slowTicks, fastTicks, resyncTicks, maxConcealTickRunMilliseconds: Int
    let minimumCorrection, maximumCorrection: Double
    let restarts, replayedPackets, canceledPackets: Int
    let networkMissingFrames, expiredQueuedFrames, discardedMissingFrames, lateArrivalFrames: Int
    let rejectedExpiredPackets, droppedBufferedFrames, rebufferWaitFrames: Int
    let receivedAfterConsumptionPackets: Int
    let concealedOutputMilliseconds, waitingOutputMilliseconds: Double
    let outputGapPercent: Double?
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "OfflineTransport", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func simulate(trace: NetworkTrace, scenario: Scenario, seed: UInt64,
                      transport: Transport, policy: Policy, budget: PlayoutBudget,
                      experiment: Experiment = .baseline, feedbackIntervalMilliseconds: Int = 50,
                      restartDelayMilliseconds: Int = 0, recoveryLeadMilliseconds: Int = 0,
                      sendMegabitsPerSecond: Double = 0) throws -> Result {
    offlineDeadlineGuardMilliseconds = policy == .guarded ? 10 : 0
    offlineKeepController = experiment.keepsController
    offlineKeepBuffer = experiment.keepsBuffer
    offlineKeepTarget = [.keepTarget, .keepTargetHistory].contains(experiment)
    offlineKeepHistory = [.keepHistory, .keepTargetHistory].contains(experiment)
    offlineKeepRate = experiment == .keepRate
    offlineKeepAnchor = experiment == .keepAnchor
    offlineProbeAudit = OfflineProbeAudit()
    let round = CoordinatedProbePlan.Round(payloadBytes: 992, packetsPerSecond: 400,
        burstPackets: 1, variant: 1, reliable: transport.reliable, repeatIndex: 1,
        controller: policy.controller, repair: 0, correctionPercent: policy.correctionPercent)
    var consumer = ProbeConsumer(round: round, budget: budget, firstSequence: 0, sourceFrame: 0)
    let deliveries = trace.deliveries(reliable: transport.reliable, sendMegabitsPerSecond: sendMegabitsPerSecond)
    let recovery = transport.recovery ? offline_recovery_create(
        Int32(budget.maximumMilliseconds - budget.outputReserveMilliseconds)) : nil
    defer { if let recovery { offline_recovery_destroy(recovery) } }
    var pending: [Delivery] = [], feedback: [Feedback] = []
    var generation: UInt32 = 1
    var producedIndex = 0, restarts = 0, replayed = 0, canceled = 0
    var lastArrival: UInt64 = 0
    var lastFeedbackArrival: UInt64 = 0
    var generationReady = captureStart
    var sendFinished = captureStart
    let serialization = sendMegabitsPerSecond > 0 ? UInt64(992 * 8 * 1_000 / sendMegabitsPerSecond) : 0
    var attempts: [Int: Int] = [:]
    func enqueue(_ packet: NetworkPacket, sent: UInt64, replay: Bool) {
        let attempt = attempts[packet.sequence, default: 0]
        attempts[packet.sequence] = attempt + 1
        sendFinished = max(max(sent, generationReady), sendFinished) + serialization
        let transmitted = sendFinished
        let candidate = replay ? trace.replayArrival(sequence: packet.sequence, attempt: attempt,
            sent: transmitted, scenario: scenario) : trace.originalArrival(packet, sent: transmitted)
        lastArrival = max(lastArrival, candidate)
        pending.append(Delivery(packet: packet, generation: generation, replayed: replay, arrived: lastArrival))
    }
    let payload = Data(repeating: 0, count: 960)
    var index = 0, played = 0, concealed = 0, slow = 0, fast = 0, resync = 0
    var skipped: UInt64 = 0
    var firstConsumption: Double?
    var latencies: [Double] = []
    var correctionMinimum = 0.0, correctionMaximum = 0.0
    var concealRun = 0, longestConcealRun = 0
    var rebufferWait = 0
    var concealedOutput = 0.0, playedOutput = 0.0
    for now in stride(from: captureStart, through: captureStart + 32_000_000_000, by: 2_500_000) {
        var incoming: [Delivery] = []
        if let recovery {
            while producedIndex < trace.packets.count && trace.packets[producedIndex].captured <= now {
                let packet = trace.packets[producedIndex]
                offline_recovery_produced(recovery, UInt32(packet.sequence), packet.captured, packet.captured)
                enqueue(packet, sent: packet.captured, replay: false)
                producedIndex += 1
            }
            incoming = pending.filter { $0.arrived <= now }
            pending.removeAll { $0.arrived <= now }
        } else {
            while index < deliveries.count && deliveries[index].arrived <= now {
                let packet = deliveries[index]
                incoming.append(Delivery(packet: packet, generation: 1, replayed: false, arrived: packet.arrived))
                index += 1
            }
        }
        for delivery in incoming {
            let packet = delivery.packet
            let record = try TimedAudioRecord(streamID: 7, generation: delivery.generation,
                sequence: UInt32(packet.sequence), frameCount: 120,
                kind: delivery.replayed ? .retransmission : .probe,
                capturedAt: packet.captured, sourceFrame: UInt64(packet.sequence * 120), payload: payload)
            consumer.receive(record, capturedAt: packet.captured, uncertainty: 0, now: delivery.arrived)
        }
        if let recovery {
            let arrivedFeedback = feedback.filter { $0.arrived <= now }.sorted { $0.arrived < $1.arrived }
            feedback.removeAll { $0.arrived <= now }
            for report in arrivedFeedback {
                var sequences = [UInt32](repeating: 0, count: 256)
                let count = offline_recovery_feedback(recovery, report.generation, report.received,
                    report.played, report.generated, now, transport == .corrected ? 1 : 0,
                    experiment.replays ? 1 : 0,
                    Int32(recoveryLeadMilliseconds),
                    &sequences, 256)
                try require(count != -2, "replay capacity exceeded")
                if count < 0 { continue }
                restarts += 1; canceled += pending.count
                pending.removeAll(); lastArrival = 0
                // Cancel unsent old-stream work while charging an already started record.
                sendFinished = max(now, min(sendFinished, now + serialization))
                generationReady = now + UInt64(restartDelayMilliseconds) * 1_000_000
                generation = offline_recovery_generation(recovery)
                replayed += Int(count)
                for sequence in sequences.prefix(Int(count)) {
                    let packet = trace.packets[Int(sequence)]
                    try require(now - packet.captured < UInt64(budget.maximumMilliseconds -
                        budget.outputReserveMilliseconds) * 1_000_000, "expired source was replayed")
                    enqueue(packet, sent: now, replay: true)
                }
            }
        }
        if (now - captureStart) % 5_000_000 != 0 { continue }
        let consumed = consumer.tick(now: now)
        if firstConsumption != nil && consumer.offlineSourceFrame < UInt64(totalFrames) &&
            now <= captureStart + 30_000_000_000 + UInt64(budget.maximumMilliseconds -
                budget.outputReserveMilliseconds) * 1_000_000 {
            rebufferWait += consumed.waitingFrames
        }
        concealedOutput += Double(consumed.concealedFrames) / (48 * (1 + consumed.correction))
        playedOutput += Double(consumed.playedFrames) / (48 * (1 + consumed.correction))
        if recovery != nil && (now - captureStart) % (UInt64(feedbackIntervalMilliseconds) * 1_000_000) == 0 {
            lastFeedbackArrival = max(lastFeedbackArrival, trace.returnArrival(generated: now))
            feedback.append(Feedback(generation: consumer.generation,
                received: consumer.latestReceivedSequence ?? .max, played: consumer.playedSourceFrame ?? .max,
                generated: now, arrived: lastFeedbackArrival))
        }
        played += consumed.playedFrames
        concealed += consumed.concealedFrames
        skipped += consumed.skippedFrames
        if consumed.playedFrames + consumed.concealedFrames > 0, firstConsumption == nil {
            firstConsumption = Double(now - captureStart) / 1e6
        }
        if let age = consumed.sourceAgeMilliseconds {
            let presentationAge = age + budget.outputReserveMilliseconds
            try require(presentationAge <= budget.maximumMilliseconds + 0.001,
                        "a played source frame exceeded its presentation budget")
            latencies.append(presentationAge)
        }
        if consumed.correction < -0.001 { slow += 1 }
        if consumed.correction > 0.001 { fast += 1 }
        if consumed.skippedFrames > 0 { resync += 1 }
        correctionMinimum = min(correctionMinimum, consumed.correction)
        correctionMaximum = max(correctionMaximum, consumed.correction)
        if consumed.concealedFrames > 0 { concealRun += 5 } else { concealRun = 0 }
        longestConcealRun = max(longestConcealRun, concealRun)
    }
    let unfinished = totalFrames - Int(consumer.offlineSourceFrame)
    try require(unfinished >= 0 && played + concealed + Int(skipped) + unfinished == totalFrames,
                "source accounting: \(scenario) seed=\(seed) \(transport) \(policy) \(experiment) " +
                "played=\(played) concealed=\(concealed) skipped=\(skipped) unfinished=\(unfinished)")
    try require(concealed == offlineProbeAudit.networkMissingFrames + offlineProbeAudit.expiredQueuedFrames +
        offlineProbeAudit.discardedMissingFrames + offlineProbeAudit.lateArrivalFrames,
        "concealment attribution is not conserved")
    if scenario == .healthy && trace.packets.count == packetCount {
        try require(concealed == 0 && skipped == 0 && unfinished == 0 && restarts == 0,
                    "healthy control lost source or restarted")
    }
    latencies.sort()
    let waitingOutput = Double(rebufferWait) / 48
    let totalOutput = playedOutput + concealedOutput + waitingOutput
    func percentile(_ fraction: Double) -> Double? {
        latencies.isEmpty ? nil : latencies[Int(Double(latencies.count - 1) * fraction)]
    }
    return Result(scenario: scenario.rawValue, transport: transport.rawValue,
        policy: policy.rawValue, inputFingerprint: trace.fingerprint, experiment: experiment.rawValue, seed: seed,
        targetMilliseconds: budget.targetMilliseconds, maximumMilliseconds: budget.maximumMilliseconds,
        feedbackIntervalMilliseconds: feedbackIntervalMilliseconds, restartDelayMilliseconds: restartDelayMilliseconds,
        recoveryLeadMilliseconds: recoveryLeadMilliseconds,
        sendMegabitsPerSecond: sendMegabitsPerSecond,
        lostPackets: trace.packets.filter { $0.lost }.count, playedFrames: played,
        concealedFrames: concealed, unfinishedFrames: unfinished, skippedFrames: skipped,
        unavailableSourcePercent: Double(concealed + Int(skipped) + unfinished) / Double(totalFrames) * 100,
        firstConsumptionMilliseconds: firstConsumption,
        p50PresentationMilliseconds: percentile(0.5), p99PresentationMilliseconds: percentile(0.99),
        maxPresentationMilliseconds: latencies.last, slowTicks: slow, fastTicks: fast, resyncTicks: resync,
        maxConcealTickRunMilliseconds: longestConcealRun,
        minimumCorrection: correctionMinimum, maximumCorrection: correctionMaximum,
        restarts: restarts, replayedPackets: replayed, canceledPackets: canceled,
        networkMissingFrames: offlineProbeAudit.networkMissingFrames,
        expiredQueuedFrames: offlineProbeAudit.expiredQueuedFrames,
        discardedMissingFrames: offlineProbeAudit.discardedMissingFrames,
        lateArrivalFrames: offlineProbeAudit.lateArrivalFrames,
        rejectedExpiredPackets: offlineProbeAudit.rejectedExpiredPackets,
        droppedBufferedFrames: offlineProbeAudit.droppedBufferedFrames, rebufferWaitFrames: rebufferWait,
        receivedAfterConsumptionPackets: offlineProbeAudit.receivedAfterConsumptionPackets,
        concealedOutputMilliseconds: concealedOutput, waitingOutputMilliseconds: waitingOutput,
        outputGapPercent: totalOutput > 0 ? (concealedOutput + waitingOutput) / totalOutput * 100 : nil)
}

@main
private struct OfflineTransport {
    static func main() throws {
        guard (2...3).contains(CommandLine.arguments.count) else {
            throw NSError(domain: "Usage: offline-transport report.json [ablation|sensitivity|components|timing|capacity]", code: 2)
        }
        let mode = CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : "baseline"
        let ablation = mode != "baseline"
        let sensitivity = mode == "sensitivity"
        let components = mode == "components"
        let timing = mode == "timing"
        let capacity = mode == "capacity"
        let experiments: [Experiment] = capacity ? [.baseline, .keepController]
            : timing ? [.keepController]
            : sensitivity ? [.baseline, .keepController, .keepBoth, .noReplay, .fixedConsumer]
            : components ? [.baseline, .keepController, .keepTarget, .keepHistory, .keepRate, .keepAnchor, .keepTargetHistory]
            : ablation ? [.baseline, .keepController, .keepBuffer, .noReplay, .keepBoth, .controllerNoReplay, .keepAll, .fixedConsumer]
            : [.baseline]
        let healthy = NetworkTrace.make(.healthy, seed: 1)
        try require(healthy.fingerprint == NetworkTrace.make(.healthy, seed: 1).fingerprint,
                    "network generation is not reproducible")
        let budget = try PlayoutBudget(targetMilliseconds: 50, maximumMilliseconds: 100,
                                       outputReserveMilliseconds: 11)
        let baseline = try simulate(trace: healthy, scenario: .healthy, seed: 1,
                                    transport: .datagram, policy: .fixed, budget: budget)
        try require(baseline.playedFrames == totalFrames && baseline.unavailableSourcePercent == 0,
                    "healthy control did not play every source frame")
        try require(baseline == simulate(trace: healthy, scenario: .healthy, seed: 1,
                    transport: .datagram, policy: .fixed, budget: budget), "simulation is not reproducible")
        let closed = try simulate(trace: healthy, scenario: .healthy, seed: 1,
                                  transport: .corrected, policy: .adaptive, budget: budget)
        try require(closed.restarts == 0 && closed.unavailableSourcePercent == 0,
                    "healthy closed-loop control restarted or lost source")
        let impaired = NetworkTrace.make(.weakWifi, seed: 1)
        let repeated = try simulate(trace: impaired, scenario: .weakWifi, seed: 1,
                                    transport: .corrected, policy: .guarded, budget: budget)
        try require(repeated.restarts > 0 && repeated.replayedPackets > 0 && repeated.canceledPackets > 0,
                    "impaired control did not exercise cancellation and fresh replay")
        try require(repeated == simulate(trace: impaired, scenario: .weakWifi, seed: 1,
            transport: .corrected, policy: .guarded, budget: budget), "closed-loop simulation is not reproducible")
        let empty = NetworkTrace(packets: [], fingerprint: "empty", pauses: [], seed: 1)
        let noPackets = try simulate(trace: empty, scenario: .healthy, seed: 1,
                                     transport: .datagram, policy: .fixed, budget: budget)
        try require(noPackets.playedFrames == 0 && noPackets.unavailableSourcePercent == 100 &&
                    noPackets.maxPresentationMilliseconds == nil, "no-input control reported playback")
        var results: [Result] = []
        for scenario in (ablation && !timing && !capacity ? [.isolatedLoss, .weakWifi] : Scenario.allCases) {
            for seed in (capacity ? UInt64(25)...32 : timing ? UInt64(17)...24 : sensitivity ? UInt64(9)...16 : UInt64(1)...8) {
                let trace = NetworkTrace.make(scenario, seed: seed)
                for (target, maximum) in [(50.0, 100.0), (80.0, 160.0), (120.0, 240.0)] {
                    let budget = try PlayoutBudget(targetMilliseconds: target, maximumMilliseconds: maximum,
                                                   outputReserveMilliseconds: 11)
                    for transport in (capacity ? [.datagram, .hol, .corrected] : timing || sensitivity || components ? [.corrected] : ablation ? [.legacy, .corrected] : Transport.allCases) {
                        for experiment in experiments {
                          for policy in (ablation ? [experiment == .fixedConsumer ? .fixed : .adaptive] : Policy.allCases) {
                            for interval in (timing || capacity ? [25] : sensitivity ? [25, 50] : [50]) {
                              for delay in (capacity ? [10] : sensitivity || timing ? [0, 10, 25] : [0]) {
                               for lead in (timing ? [0, 15, 30, 45] : [0]) {
                                for rate in (capacity ? [0.0, 3.5, 6.0] : [0.0]) {
                                results.append(try simulate(trace: trace, scenario: scenario, seed: seed,
                                    transport: transport, policy: policy, budget: budget, experiment: experiment,
                                    feedbackIntervalMilliseconds: interval, restartDelayMilliseconds: delay,
                                    recoveryLeadMilliseconds: lead, sendMegabitsPerSecond: rate))
                                }
                               }
                              }
                            }
                          }
                        }
                    }
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("offline_transport_checks_passed cases=\(results.count) simulated_seconds=\(results.count * 30)")
    }
}
