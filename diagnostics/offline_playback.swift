import Foundation
import XCTest
import HearPortAtomics
@testable import HearPortReceiver

private struct PlaybackResult: Codable {
    let implementation, inputFingerprint: String
    let scenario, content: String
    let adaptive: Bool
    let seed, callbackFrames, uncertaintyMilliseconds: Int
    let targetMilliseconds, maximumMilliseconds, outputClockPPM: Double
    let pumpJitterMilliseconds, callbackPhaseMicroseconds: Int
    let concealedPreparedFrames, underflowAfterStartFrames, latePackets, expiredOutputFrames: Int
    let skippedSourceFrames: Int
    let requestedCorrectionMean, realizedCorrection: Double
    let firstOutputMilliseconds, maximumPresentationMilliseconds: Double
    let maximumSourceAgeBoundMilliseconds, maximumTargetMilliseconds: Double
    let sourceCursor, renderedFrames: UInt64
    let originalSourceSpan, concealedSourceSpan, expiredSourceSpan: UInt64
    let longestUnderflowMilliseconds, longestNearSilenceMilliseconds: Double
    let recovery: [RecoveryResult]
    let maximumStereoError, outputPeak: Float
}

private struct RecoveryResult: Codable {
    let releaseMilliseconds: Double
    var eligibleAt: UInt64?
    var eligibleSource: UInt64?
    var originalRecoveryDelayMilliseconds: Double?
}

private struct Packet {
    let sequence: UInt32
    let captured, arrived: UInt64
}

final class OfflinePlaybackTests: XCTestCase {
    private func payload(_ first: Int, content: String) -> Data {
        var data = Data(capacity: 960)
        for frame in first..<(first + 120) {
            let time = Double(frame) / 48_000
            var hash = UInt64(frame) &+ 0x9e3779b97f4a7c15
            hash = (hash ^ (hash >> 30)) &* 0xbf58476d1ce4e5b9
            hash = (hash ^ (hash >> 27)) &* 0x94d049bb133111eb
            let noise = Float((hash ^ (hash >> 31)) >> 40) / Float(1 << 23) - 1
            let value: Float
            if content == "tone" { value = Float(sin(time * 2 * .pi * 440)) * 0.4 }
            else if content == "noise" { value = noise * 0.4 }
            else {
                let envelope = exp(-Double(frame % 12_000) / 800)
                value = Float(sin(time * 2 * .pi * 220) + 0.4 * sin(time * 2 * .pi * 523.25)) * 0.2 + noise * Float(envelope) * 0.2
            }
            for sample in [value, -value] {
                var bits = sample.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    private func run(scenario: String, content: String, adaptive: Bool, seed: Int,
                     callback: Int, uncertainty: Int,
                     target: Double = 50, maximum: Double = 100, outputClockPPM: Double = 0,
                     seconds: Int = 12,
                     pumpJitterMilliseconds: Int = 0, callbackPhaseMicroseconds: Int = 0) throws -> PlaybackResult {
        let base: UInt64 = 1_000_000_000
        let count = seconds * 400
        var packets: [Packet] = []
        var lastArrival: UInt64 = 0
        let stallMilliseconds = Int(scenario.suffix(3)) ?? 0
        let stallPackets = stallMilliseconds * 2 / 5
        let stalledRanges = stallPackets > 0 ? [1_600..<(1_600 + stallPackets), 3_200..<(3_200 + stallPackets)] : []
        let releases = stalledRanges.map { base + UInt64($0.upperBound) * 2_500_000 + 5_000_000 }
        for sequence in 0..<count {
            let captured = base + UInt64(sequence) * 2_500_000
            var arrived = captured + 5_000_000 + UInt64((sequence * 17 + seed * 13) % 7) * 500_000
            if scenario == "burst" || scenario == "hol" {
                let position = sequence % 400
                if (160..<180).contains(position) {
                    arrived = base + UInt64(sequence - position + 180) * 2_500_000 + 5_000_000
                }
            }
            if scenario == "loss", sequence % 997 == 500 { continue }
            if scenario == "hol" {
                if sequence % 997 == 500 { arrived += 100_000_000 }
                arrived = max(lastArrival, arrived); lastArrival = arrived
            }
            if let range = stalledRanges.first(where: { $0.contains(sequence) }) {
                if scenario.hasPrefix("drop") || scenario.hasPrefix("restart") { continue }
                arrived = base + UInt64(range.upperBound) * 2_500_000 + 5_000_000
            }
            if scenario.hasPrefix("restartbursty") {
                for range in stalledRanges {
                    if (40..<56).contains(sequence - range.upperBound) {
                        arrived = base + UInt64(range.upperBound + 56) * 2_500_000 + 5_000_000
                    }
                }
            }
            packets.append(Packet(sequence: UInt32(sequence), captured: captured, arrived: arrived))
        }
        packets.sort { $0.arrived == $1.arrived ? $0.sequence < $1.sequence : $0.arrived < $1.arrived }
        var fingerprint: UInt64 = 14_695_981_039_346_656_037
        for p in packets {
            for value in [UInt64(p.sequence), p.captured, p.arrived] {
                fingerprint = (fingerprint ^ value) &* 1_099_511_628_211
            }
        }
        offlineNow = base
        offlineLastRendered = 0; offlineConcealedFrames = 0; offlineSkippedFrames = 0
        offlineMaximumShift = 0
        hearport_offline_reset_age()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = HearPortDiagnostics(directory: directory)
        diagnostics.level = .error
        let receiver = HearPortReceiver(diagnostics: diagnostics)
        XCTAssertTrue(receiver.beginAuthentication(authMode: .oneTime, peerID: Data()))
        XCTAssertTrue(receiver.markAuthenticated())
        XCTAssertTrue(receiver.beginStream(7))
        XCTAssertTrue(receiver.acknowledgeStartStream(7))
        receiver.offlineConfigure(try PlayoutBudget(targetMilliseconds: target,
            maximumMilliseconds: maximum, outputReserveMilliseconds: 11), adaptive: adaptive)
        var index = 0, callbacks = 0, pumpCount = 0, pump = base, clock = base
        let renderBase = base + UInt64(callbackPhaseMicroseconds) * 1_000
        var render = renderBase
        var first: UInt64?, underflow = 0, corrections: [Double] = []
        var renderedFrames: UInt64 = 0
        var stereoError: Float = 0, peak: Float = 0
        var nonfiniteSamples = 0, maximumTarget = target
        var silenceRun = 0, longestSilence = 0, underflowRun = 0, longestUnderflow = 0
        var recovery = releases.map { RecoveryResult(releaseMilliseconds: Double($0 - base) / 1e6) }
        var generation: UInt32 = 1
        var restartIndex = 0
        var drift = DriftController(nominalRatio: 1)
        var resampler = StreamingStereoResampler()
        let finish = base + UInt64(seconds) * 1_000_000_000
        while true {
            let restart = scenario.hasPrefix("restart") && restartIndex < releases.count ? releases[restartIndex] : UInt64.max
            let next = min(index < packets.count ? packets[index].arrived : .max, pump, render, clock, restart)
            if next >= finish { break }
            offlineNow = next
            if next == restart {
                generation += 1; restartIndex += 1
                XCTAssertTrue(receiver.beginReliableGeneration(7, generation: generation))
            }
            if next == clock {
                let rtt = UInt64(uncertainty) * 2_000_000
                XCTAssertTrue(receiver.observeClock(localSent: next - rtt,
                    remoteReceived: next - rtt / 2, remoteSent: next - rtt / 2, localReceived: next))
                clock += 2_000_000_000
            }
            while index < packets.count && packets[index].arrived == next {
                let p = packets[index]
                for i in recovery.indices where next >= releases[i] && recovery[i].eligibleAt == nil {
                    let allowance = maximum - 11 - Double(receiver.clockUncertainty) / 1e6 - Double(callback) / 48 - 6
                    if Double(next - p.captured) / 1e6 < allowance {
                        recovery[i].eligibleAt = next
                        recovery[i].eligibleSource = UInt64(p.sequence) * 120
                    }
                }
                _ = receiver.receiveTimedRecord(try TimedAudioRecord(streamID: 7, generation: generation,
                    sequence: p.sequence, frameCount: 120, kind: .audio, capturedAt: p.captured,
                    sourceFrame: UInt64(p.sequence) * 120, payload: payload(Int(p.sequence) * 120, content: content)))
                index += 1
            }
            if next == pump {
                receiver.offlinePump()
                corrections.append(receiver.dynamicCorrection)
                maximumTarget = max(maximumTarget, receiver.offlineTargetMilliseconds)
                pumpCount += 1
                pump = base + UInt64(pumpCount) * 5_000_000 + UInt64(pumpCount % 2 * pumpJitterMilliseconds) * 1_000_000
            }
            if next == render {
                let ratio = drift.update(fillError: Double(receiver.renderFillFrames - receiver.jitterTargetFrames),
                    validAudio: receiver.isRenderActive && !receiver.isConcealing && abs(receiver.dynamicCorrection) <= 0.001)
                let required = max(1, resampler.requiredInputFrames(outputFrameCount: callback, ratio: ratio))
                let samples = receiver.renderFrames(required)
                let output = resampler.process(samples, outputFrameCount: callback, ratio: ratio)
                XCTAssertEqual(output.count, callback * 2)
                nonfiniteSamples += output.filter { !$0.isFinite }.count
                for frame in 0..<callback {
                    stereoError = max(stereoError, abs(output[frame * 2] + output[frame * 2 + 1]))
                    peak = max(peak, abs(output[frame * 2]), abs(output[frame * 2 + 1]))
                }
                renderedFrames += UInt64(offlineLastRendered)
                if first == nil && offlineLastRendered > 0 { first = next }
                if first != nil {
                    let missing = required - offlineLastRendered
                    underflow += missing
                    underflowRun = offlineLastRendered == 0 ? underflowRun + missing : missing
                    longestUnderflow = max(longestUnderflow, underflowRun)
                    for frame in 0..<callback {
                        silenceRun = max(abs(output[frame * 2]), abs(output[frame * 2 + 1])) < 0.0001 ? silenceRun + 1 : 0
                        longestSilence = max(longestSilence, silenceRun)
                    }
                }
                let originalSource = hearport_offline_original_source()
                if originalSource != UInt64.max {
                    for i in recovery.indices where recovery[i].originalRecoveryDelayMilliseconds == nil {
                        if let eligible = recovery[i].eligibleAt, let source = recovery[i].eligibleSource,
                           originalSource > source {
                            recovery[i].originalRecoveryDelayMilliseconds = Double(next - eligible) / 1e6
                        }
                    }
                }
                callbacks += 1
                render = renderBase + UInt64(Double(callbacks * callback) * 1e9 / (48_000 * (1 + outputClockPPM / 1e6)))
            }
        }
        let counts = receiver.offlineStretchCounts
        let implementation = ProcessInfo.processInfo.environment["HEARPORT_PLAYBACK_REFERENCE"] ?? "working"
        let result = PlaybackResult(implementation: implementation, inputFingerprint: String(fingerprint, radix: 16),
            scenario: scenario, content: content, adaptive: adaptive,
            seed: seed, callbackFrames: callback, uncertaintyMilliseconds: uncertainty,
            targetMilliseconds: target, maximumMilliseconds: maximum, outputClockPPM: outputClockPPM,
            pumpJitterMilliseconds: pumpJitterMilliseconds, callbackPhaseMicroseconds: callbackPhaseMicroseconds,
            concealedPreparedFrames: offlineConcealedFrames, underflowAfterStartFrames: underflow,
            latePackets: Int(receiver.jitterStats?.latePackets ?? 0), expiredOutputFrames: Int(receiver.offlineExpired),
            skippedSourceFrames: offlineSkippedFrames,
            requestedCorrectionMean: corrections.reduce(0, +) / Double(corrections.count),
            realizedCorrection: counts.1 > 0 ? Double(counts.0) / Double(counts.1) - 1 : 0,
            firstOutputMilliseconds: first.map { Double($0 - base) / 1e6 } ?? -1,
            maximumPresentationMilliseconds: Double(hearport_offline_maximum_age()) / 1e6 + 11,
            maximumSourceAgeBoundMilliseconds: Double(hearport_offline_maximum_age()) / 1e6 + 11 + Double(offlineMaximumShift + 1) / 48,
            maximumTargetMilliseconds: maximumTarget,
            sourceCursor: receiver.offlineSourceCursor ?? 0, renderedFrames: renderedFrames,
            originalSourceSpan: hearport_offline_original_span(),
            concealedSourceSpan: hearport_offline_concealed_span(), expiredSourceSpan: hearport_offline_expired_span(),
            longestUnderflowMilliseconds: Double(longestUnderflow) / 48,
            longestNearSilenceMilliseconds: Double(longestSilence) / 48, recovery: recovery,
            maximumStereoError: stereoError, outputPeak: peak)
        XCTAssertTrue(peak.isFinite)
        XCTAssertEqual(nonfiniteSamples, 0)
        XCTAssertLessThanOrEqual(peak, 0.5)
        if implementation == "working" { XCTAssertLessThan(stereoError, 0.00001) }
        XCTAssertGreaterThanOrEqual(result.firstOutputMilliseconds, 0)
        if implementation == "working" { XCTAssertLessThan(result.maximumSourceAgeBoundMilliseconds, maximum) }
        if scenario == "healthy" {
            if implementation == "working", adaptive { XCTAssertEqual(result.concealedPreparedFrames, 0) }
            XCTAssertEqual(result.underflowAfterStartFrames, 0)
            if implementation == "working" { XCTAssertLessThanOrEqual(result.skippedSourceFrames, 120) }
        }
        return result
    }

    func testProductionPlaybackMatrix() throws {
        var results: [PlaybackResult] = []
        for scenario in ["healthy", "burst", "loss", "hol", "stall200", "stall300", "drop200", "drop300", "restart200", "restart300", "restartbursty200", "restartbursty300"] {
            for content in ["tone", "noise", "mixed"] {
                for uncertainty in [0, 15] {
                    for adaptive in [false, true] {
                        results.append(try run(scenario: scenario, content: content,
                            adaptive: adaptive, seed: 1, callback: 256, uncertainty: uncertainty))
                    }
                }
            }
        }
        for target in [30.0, 80.0] {
            for callback in [120, 480] {
                for scenario in ["healthy", "burst", "hol"] {
                    for adaptive in [false, true] {
                        results.append(try run(scenario: scenario, content: "mixed", adaptive: adaptive,
                            seed: 7, callback: callback, uncertainty: 15,
                            target: target, maximum: target * 2))
                    }
                }
            }
        }
        for ppm in [-500.0, 500.0] {
            for adaptive in [false, true] {
                results.append(try run(scenario: "healthy", content: "mixed", adaptive: adaptive,
                    seed: 7, callback: 256, uncertainty: 15,
                    outputClockPPM: ppm, seconds: 30))
            }
        }
        for callback in [256, 480] {
            for scenario in ["healthy", "hol"] {
                for adaptive in [false, true] {
                    results.append(try run(scenario: scenario, content: "mixed", adaptive: adaptive,
                        seed: 7, callback: callback, uncertainty: 15,
                        target: callback == 480 ? 30 : 50,
                        maximum: callback == 480 ? 60 : 100,
                        pumpJitterMilliseconds: 1, callbackPhaseMicroseconds: 2_100))
                }
            }
        }
        for maximum in [60.0, 80, 100, 120, 160, 200, 300] {
            for seed in [1, 7, 19] {
                if maximum == 100 && seed == 1 { continue }
                for scenario in ["healthy", "burst", "hol", "stall200", "drop300", "loss"] {
                    for adaptive in [false, true] {
                        results.append(try run(scenario: scenario, content: "mixed", adaptive: adaptive,
                            seed: seed, callback: 256, uncertainty: 15,
                            target: maximum / 2, maximum: maximum))
                    }
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let path = ProcessInfo.processInfo.environment["HEARPORT_PLAYBACK_RESULTS"] {
            try encoder.encode(results).write(to: URL(fileURLWithPath: path))
        }
        print("offline_playback_cases=\(results.count)")
    }
}
