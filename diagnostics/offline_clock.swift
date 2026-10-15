import Foundation

private struct Result: Encodable {
    let scenario: String
    let seed: Int
    let clockRate: Double
    let samplesAccepted, samplesRejected, mappedPackets, unmappedPackets: Int
    let uncoveredErrors, unexpectedGaps: Int
    let maximumErrorMilliseconds, maximumUncertaintyMilliseconds: Double
}

@main
private struct OfflineClock {
    static func main() throws {
        let scenarios = ["healthy", "rtt_step", "rtt_high", "asymmetric", "spikes", "outage", "invalid_rtt",
                         "forward_only", "reverse_only", "drift_reversal", "server_processing", "probe_schedule_jitter"]
        var results: [Result] = []
        for scenario in scenarios {
            for seed in 0..<8 {
                for rate in [0.998, 1.0, 1.002] {
                    let base: UInt64 = 5_000_000_000
                    func remote(_ local: UInt64) -> UInt64 {
                        let elapsed = Double(local - base)
                        if scenario == "drift_reversal", elapsed > 60e9 {
                            return UInt64((12e9 + 60e9 / rate + (elapsed - 60e9) / (2 - rate)).rounded())
                        }
                        return UInt64((12e9 + elapsed / rate).rounded())
                    }
                    var clock = ClockMapping()
                    var accepted = 0, rejected = 0, mapped = 0, unmapped = 0
                    var uncovered = 0, gaps = 0
                    var maximumError = 0.0, maximumUncertainty = 0.0
                    var sampleIndex = 0
                    // 180 seconds of audio arriving every 2.5 ms, with clock probes every 2 seconds.
                    for tick in 0..<72_000 {
                        let elapsed = UInt64(tick) * 2_500_000
                        let now = base + elapsed
                        let second = sampleIndex * 2
                        let jitter = UInt64((sampleIndex * 17 + seed * 13) % 7) * 100_000
                        var forward: UInt64 = 1_000_000 + jitter
                        var back: UInt64 = 1_000_000 + jitter
                        let processing: UInt64 = scenario == "server_processing" ? 20_000_000 : 0
                        if scenario == "forward_only" { forward = 20_000_000 + jitter; back = 0 }
                        if scenario == "reverse_only" || scenario == "server_processing" { forward = 0; back = 20_000_000 + jitter }
                        if second >= 10 {
                            if scenario == "rtt_step" || scenario == "probe_schedule_jitter" { forward += 9_000_000; back += 9_000_000 }
                            if scenario == "rtt_high" { forward += 39_000_000; back += 39_000_000 }
                            if scenario == "asymmetric" { forward += 30_000_000 }
                            if scenario == "spikes", sampleIndex % 7 == 0 { back += 150_000_000 }
                            if scenario == "invalid_rtt" { back += 600_000_000 }
                        }
                        let scheduleDelay: UInt64 = scenario == "probe_schedule_jitter" && second == 8 ? 100_000_000 : 0
                        let sent = base + UInt64(second) * 1_000_000_000 + scheduleDelay
                        let received = sent + forward + processing + back
                        if now >= received {
                            if !(scenario == "outage" && second >= 10 && second < 50) {
                                if clock.observe(localSent: sent, remoteReceived: remote(sent + forward),
                                    remoteSent: remote(sent + forward + processing), localReceived: received) {
                                    accepted += 1
                                } else { rejected += 1 }
                            }
                            sampleIndex += 1
                        }
                        guard elapsed >= 50_000_000 else { continue }
                        let capture = now - 6_000_000
                        guard let estimated = clock.map(remoteNanoseconds: remote(capture), at: now) else {
                            unmapped += 1
                            if scenario != "outage" && scenario != "invalid_rtt" { gaps += 1 }
                            continue
                        }
                        mapped += 1
                        let error = abs(Double(estimated) - Double(capture))
                        let uncertainty = clock.uncertainty(at: now, remoteNanoseconds: remote(capture))
                        maximumError = max(maximumError, error / 1e6)
                        maximumUncertainty = max(maximumUncertainty, Double(uncertainty) / 1e6)
                        // Mapping error must fit the uncertainty charged to the playback deadline.
                        if error > Double(uncertainty) + 2 { uncovered += 1 }
                    }
                    results.append(Result(scenario: scenario, seed: seed, clockRate: rate,
                        samplesAccepted: accepted, samplesRejected: rejected,
                        mappedPackets: mapped, unmappedPackets: unmapped,
                        uncoveredErrors: uncovered, unexpectedGaps: gaps,
                        maximumErrorMilliseconds: maximumError,
                        maximumUncertaintyMilliseconds: maximumUncertainty))
                }
            }
        }
        var queued = ClockMapping()
        _ = queued.observe(localSent: 1_000_000_000, remoteReceived: 1_001_000_000,
                           remoteSent: 1_001_000_000, localReceived: 1_002_000_000)
        let queuedValid = queued.map(remoteNanoseconds: 1_001_000_000, at: 1_001_900_000) != nil
            && queued.uncertainty(at: 1_001_900_000) != .max
        let failed = results.filter { $0.uncoveredErrors > 0 || $0.unexpectedGaps > 0 }.count
        if CommandLine.arguments.count > 1 {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(results).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("offline_clock_checks cases=\(results.count) simulated_seconds=\(results.count * 180) failed_cases=\(failed) queued_arrival_valid=\(queuedValid)")
        if failed > 0 || !queuedValid { exit(1) }
    }
}
