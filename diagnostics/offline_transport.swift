import Foundation

private let captureStart: UInt64 = 1_000_000_000
private let packetInterval: UInt64 = 2_500_000
private let packetCount = 12_000
private let totalFrames = packetCount * 120

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
    let captured, arrived, retryDelay: UInt64
    let lost: Bool
}

private struct NetworkTrace {
    let packets: [NetworkPacket]
    let fingerprint: String

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
                arrived: arrived, retryDelay: retryDelay, lost: lost))
            for value in [UInt64(sequence), captured, arrived, retryDelay, lost ? 1 : 0] {
                fingerprint = (fingerprint ^ value) &* 0x100000001b3
            }
        }
        return NetworkTrace(packets: packets, fingerprint: String(fingerprint, radix: 16))
    }

    func deliveries(reliable: Bool) -> [NetworkPacket] {
        var lastArrival: UInt64 = 0
        var result: [NetworkPacket] = []
        for packet in packets {
            if packet.lost && !reliable { continue }
            let candidate = packet.arrived + (packet.lost ? packet.retryDelay : 0)
            let arrived = reliable ? max(candidate, lastArrival) : candidate
            lastArrival = arrived
            result.append(NetworkPacket(sequence: packet.sequence, captured: packet.captured,
                arrived: arrived, retryDelay: packet.retryDelay, lost: packet.lost))
        }
        return result.sorted { lhs, rhs in
            lhs.arrived == rhs.arrived ? lhs.sequence < rhs.sequence : lhs.arrived < rhs.arrived
        }
    }
}

private enum Policy: String, CaseIterable {
    case fixed, speedOnly = "speed_only", bufferOnly = "buffer_only", adaptive
    var controller: Int { self == .fixed ? 0 : (self == .speedOnly ? 1 : 2) }
    var correctionPercent: Int { self == .fixed || self == .bufferOnly ? 0 : 5 }
}

private struct Result: Codable, Equatable {
    let scenario, transport, policy, inputFingerprint: String
    let seed: UInt64
    let targetMilliseconds, maximumMilliseconds: Double
    let lostPackets, playedFrames, concealedFrames, unfinishedFrames: Int
    let skippedFrames: UInt64
    let unavailableSourcePercent: Double
    let firstConsumptionMilliseconds: Double?
    let p50PresentationMilliseconds, p99PresentationMilliseconds, maxPresentationMilliseconds: Double?
    let slowTicks, fastTicks, resyncTicks, maxConcealTickRunMilliseconds: Int
    let minimumCorrection, maximumCorrection: Double
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "OfflineTransport", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func simulate(trace: NetworkTrace, scenario: Scenario, seed: UInt64,
                      reliable: Bool, policy: Policy, budget: PlayoutBudget) throws -> Result {
    let round = CoordinatedProbePlan.Round(payloadBytes: 992, packetsPerSecond: 400,
        burstPackets: 1, variant: 1, reliable: reliable, repeatIndex: 1,
        controller: policy.controller, repair: 0, correctionPercent: policy.correctionPercent)
    var consumer = ProbeConsumer(round: round, budget: budget, firstSequence: 0, sourceFrame: 0)
    let deliveries = trace.deliveries(reliable: reliable)
    let payload = Data(repeating: 0, count: 960)
    var index = 0, played = 0, concealed = 0, slow = 0, fast = 0, resync = 0
    var skipped: UInt64 = 0
    var firstConsumption: Double?
    var latencies: [Double] = []
    var correctionMinimum = 0.0, correctionMaximum = 0.0
    var concealRun = 0, longestConcealRun = 0
    for now in stride(from: captureStart, through: captureStart + 32_000_000_000, by: 5_000_000) {
        while index < deliveries.count && deliveries[index].arrived <= now {
            let packet = deliveries[index]
            let record = try TimedAudioRecord(streamID: 7, generation: 1,
                sequence: UInt32(packet.sequence), frameCount: 120, kind: .probe,
                capturedAt: packet.captured, sourceFrame: UInt64(packet.sequence * 120), payload: payload)
            consumer.receive(record, capturedAt: packet.captured, uncertainty: 0, now: packet.arrived)
            index += 1
        }
        let consumed = consumer.tick(now: now)
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
    let unfinished = totalFrames - Int(consumer.playedSourceFrame ?? 0)
    try require(unfinished >= 0 && played + concealed + Int(skipped) + unfinished == totalFrames,
                "source frame accounting is not conserved")
    latencies.sort()
    func percentile(_ fraction: Double) -> Double? {
        latencies.isEmpty ? nil : latencies[Int(Double(latencies.count - 1) * fraction)]
    }
    return Result(scenario: scenario.rawValue, transport: reliable ? "reliable_hol_model" : "datagram",
        policy: policy.rawValue, inputFingerprint: trace.fingerprint, seed: seed,
        targetMilliseconds: budget.targetMilliseconds, maximumMilliseconds: budget.maximumMilliseconds,
        lostPackets: trace.packets.filter { $0.lost }.count, playedFrames: played,
        concealedFrames: concealed, unfinishedFrames: unfinished, skippedFrames: skipped,
        unavailableSourcePercent: Double(concealed + Int(skipped) + unfinished) / Double(totalFrames) * 100,
        firstConsumptionMilliseconds: firstConsumption,
        p50PresentationMilliseconds: percentile(0.5), p99PresentationMilliseconds: percentile(0.99),
        maxPresentationMilliseconds: latencies.last, slowTicks: slow, fastTicks: fast, resyncTicks: resync,
        maxConcealTickRunMilliseconds: longestConcealRun,
        minimumCorrection: correctionMinimum, maximumCorrection: correctionMaximum)
}

@main
private struct OfflineTransport {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw NSError(domain: "Usage: offline-transport report.json", code: 2) }
        let healthy = NetworkTrace.make(.healthy, seed: 1)
        try require(healthy.fingerprint == NetworkTrace.make(.healthy, seed: 1).fingerprint,
                    "network generation is not reproducible")
        let budget = try PlayoutBudget(targetMilliseconds: 50, maximumMilliseconds: 100,
                                       outputReserveMilliseconds: 11)
        let baseline = try simulate(trace: healthy, scenario: .healthy, seed: 1,
                                    reliable: false, policy: .fixed, budget: budget)
        try require(baseline.playedFrames == totalFrames && baseline.unavailableSourcePercent == 0,
                    "healthy control did not play every source frame")
        try require(baseline == simulate(trace: healthy, scenario: .healthy, seed: 1,
                    reliable: false, policy: .fixed, budget: budget), "simulation is not reproducible")
        let empty = NetworkTrace(packets: [], fingerprint: "empty")
        let noPackets = try simulate(trace: empty, scenario: .healthy, seed: 1,
                                     reliable: false, policy: .fixed, budget: budget)
        try require(noPackets.playedFrames == 0 && noPackets.unavailableSourcePercent == 100 &&
                    noPackets.maxPresentationMilliseconds == nil, "no-input control reported playback")
        var results: [Result] = []
        for scenario in Scenario.allCases {
            for seed in UInt64(1)...8 {
                let trace = NetworkTrace.make(scenario, seed: seed)
                for (target, maximum) in [(50.0, 100.0), (80.0, 160.0), (120.0, 240.0)] {
                    let budget = try PlayoutBudget(targetMilliseconds: target, maximumMilliseconds: maximum,
                                                   outputReserveMilliseconds: 11)
                    for reliable in [false, true] {
                        for policy in Policy.allCases {
                            results.append(try simulate(trace: trace, scenario: scenario, seed: seed,
                                reliable: reliable, policy: policy, budget: budget))
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
