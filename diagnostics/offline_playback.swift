import Foundation
import XCTest
import HearPortAtomics
@testable import HearPortReceiver

private struct PlaybackResult: Codable {
    let scenario, content: String
    let adaptive: Bool
    let batchMode: Int
    let observeLate: Bool
    let seed, callbackFrames, uncertaintyMilliseconds: Int
    let targetMilliseconds, maximumMilliseconds, outputClockPPM: Double
    let concealedPreparedFrames, underflowAfterStartFrames, latePackets, expiredOutputFrames: Int
    let requestedCorrectionMean, realizedCorrection: Double
    let firstOutputMilliseconds, maximumPresentationMilliseconds: Double
    let maximumSourceAgeBoundMilliseconds, maximumTargetMilliseconds: Double
    let sourceCursor, renderedFrames: UInt64
    let maximumStereoError, outputPeak: Float
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
                     callback: Int, uncertainty: Int, batchMode: Int, observeLate: Bool = false,
                     target: Double = 50, maximum: Double = 100, outputClockPPM: Double = 0,
                     seconds: Int = 12) throws -> PlaybackResult {
        let base: UInt64 = 1_000_000_000
        let count = seconds * 400
        var packets: [Packet] = []
        var lastArrival: UInt64 = 0
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
            packets.append(Packet(sequence: UInt32(sequence), captured: captured, arrived: arrived))
        }
        packets.sort { $0.arrived == $1.arrived ? $0.sequence < $1.sequence : $0.arrived < $1.arrived }
        offlineNow = base
        offlineLastRendered = 0; offlineConcealedFrames = 0
        offlineBatchMode = batchMode
        offlineObserveLate = observeLate; offlineMaximumShift = 0
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
        var index = 0, callbacks = 0, pump = base, render = base, clock = base
        var first: UInt64?, underflow = 0, corrections: [Double] = []
        var renderedFrames: UInt64 = 0
        var stereoError: Float = 0, peak: Float = 0
        var nonfiniteSamples = 0, maximumTarget = target
        var drift = DriftController(nominalRatio: 1)
        var resampler = StreamingStereoResampler()
        let finish = base + UInt64(seconds) * 1_000_000_000
        while true {
            let next = min(index < packets.count ? packets[index].arrived : .max, pump, render, clock)
            if next >= finish { break }
            offlineNow = next
            if next == clock {
                let rtt = UInt64(uncertainty) * 2_000_000
                XCTAssertTrue(receiver.observeClock(localSent: next - rtt,
                    remoteReceived: next - rtt / 2, remoteSent: next - rtt / 2, localReceived: next))
                clock += 2_000_000_000
            }
            while index < packets.count && packets[index].arrived == next {
                let p = packets[index]
                _ = receiver.receiveTimedRecord(try TimedAudioRecord(streamID: 7, generation: 1,
                    sequence: p.sequence, frameCount: 120, kind: .audio, capturedAt: p.captured,
                    sourceFrame: UInt64(p.sequence) * 120, payload: payload(Int(p.sequence) * 120, content: content)))
                index += 1
            }
            if next == pump {
                receiver.offlinePump()
                corrections.append(receiver.dynamicCorrection)
                maximumTarget = max(maximumTarget, receiver.offlineTargetMilliseconds)
                pump += 5_000_000
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
                if first != nil { underflow += required - offlineLastRendered }
                callbacks += 1
                render = base + UInt64(Double(callbacks * callback) * 1e9 / (48_000 * (1 + outputClockPPM / 1e6)))
            }
        }
        let counts = receiver.offlineStretchCounts
        let result = PlaybackResult(scenario: scenario, content: content, adaptive: adaptive,
            batchMode: batchMode, observeLate: observeLate,
            seed: seed, callbackFrames: callback, uncertaintyMilliseconds: uncertainty,
            targetMilliseconds: target, maximumMilliseconds: maximum, outputClockPPM: outputClockPPM,
            concealedPreparedFrames: offlineConcealedFrames, underflowAfterStartFrames: underflow,
            latePackets: Int(receiver.jitterStats?.latePackets ?? 0), expiredOutputFrames: Int(receiver.offlineExpired),
            requestedCorrectionMean: corrections.reduce(0, +) / Double(corrections.count),
            realizedCorrection: counts.1 > 0 ? Double(counts.0) / Double(counts.1) - 1 : 0,
            firstOutputMilliseconds: first.map { Double($0 - base) / 1e6 } ?? -1,
            maximumPresentationMilliseconds: Double(hearport_offline_maximum_age()) / 1e6 + 11,
            maximumSourceAgeBoundMilliseconds: Double(hearport_offline_maximum_age()) / 1e6 + 11 + Double(offlineMaximumShift + 1) / 48,
            maximumTargetMilliseconds: maximumTarget,
            sourceCursor: receiver.offlineSourceCursor ?? 0, renderedFrames: renderedFrames,
            maximumStereoError: stereoError, outputPeak: peak)
        XCTAssertTrue(peak.isFinite)
        XCTAssertEqual(nonfiniteSamples, 0)
        XCTAssertLessThanOrEqual(peak, 0.5)
        XCTAssertLessThan(stereoError, 0.00001)
        XCTAssertGreaterThanOrEqual(result.firstOutputMilliseconds, 0)
        XCTAssertLessThan(result.maximumSourceAgeBoundMilliseconds, maximum)
        if scenario == "healthy" {
            XCTAssertEqual(result.concealedPreparedFrames, 0)
            XCTAssertEqual(result.underflowAfterStartFrames, 0)
        }
        return result
    }

    func testProductionPlaybackMatrix() throws {
        var results: [PlaybackResult] = []
        for scenario in ["healthy", "burst", "loss", "hol"] {
            for content in ["tone", "noise", "mixed"] {
                for adaptive in [false, true] {
                    for uncertainty in [0, 15] {
                        for batchMode in adaptive ? [0, 2] : [0] {
                            for observeLate in adaptive ? [false, true] : [false] {
                                results.append(try run(scenario: scenario, content: content,
                                    adaptive: adaptive, seed: 1, callback: 256, uncertainty: uncertainty,
                                    batchMode: batchMode, observeLate: observeLate))
                            }
                        }
                    }
                }
            }
        }
        for target in [30.0, 80.0] {
            for callback in [120, 480] {
                for scenario in ["healthy", "burst", "hol"] {
                    for candidate in [false, true] {
                        results.append(try run(scenario: scenario, content: "mixed", adaptive: true,
                            seed: 7, callback: callback, uncertainty: 15, batchMode: candidate ? 2 : 0,
                            observeLate: candidate, target: target, maximum: target * 2))
                    }
                }
            }
        }
        for ppm in [-500.0, 500.0] {
            for candidate in [false, true] {
                results.append(try run(scenario: "healthy", content: "mixed", adaptive: true,
                    seed: 7, callback: 256, uncertainty: 15, batchMode: candidate ? 2 : 0,
                    observeLate: candidate, outputClockPPM: ppm, seconds: 30))
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
