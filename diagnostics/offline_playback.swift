import Foundation
import XCTest
import HearPortAtomics
@testable import HearPortReceiver

private struct PlaybackResult: Codable {
    let scenario, content: String
    let adaptive: Bool
    let capacityBatch: Bool
    let seed, callbackFrames, uncertaintyMilliseconds: Int
    let concealedPreparedFrames, underflowAfterStartFrames, latePackets, expiredOutputFrames: Int
    let requestedCorrectionMean, realizedCorrection: Double
    let firstOutputMilliseconds, maximumPresentationMilliseconds: Double
    let sourceFramesConsumed: UInt64
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
                     callback: Int, uncertainty: Int, capacityBatch: Bool) throws -> PlaybackResult {
        let base: UInt64 = 1_000_000_000
        let count = 4_800
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
        offlineBatchCapacity = capacityBatch
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
        receiver.offlineConfigure(try PlayoutBudget(targetMilliseconds: 50,
            maximumMilliseconds: 100, outputReserveMilliseconds: 11), adaptive: adaptive)
        var index = 0, callbacks = 0, pump = base, render = base, clock = base
        var first: UInt64?, underflow = 0, corrections: [Double] = []
        var drift = DriftController(nominalRatio: 1)
        var resampler = StreamingStereoResampler()
        let finish = base + 12_000_000_000
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
                pump += 5_000_000
            }
            if next == render {
                let ratio = drift.update(fillError: Double(receiver.renderFillFrames - receiver.jitterTargetFrames),
                    validAudio: receiver.isRenderActive && !receiver.isConcealing && abs(receiver.dynamicCorrection) <= 0.001)
                let required = max(1, resampler.requiredInputFrames(outputFrameCount: callback, ratio: ratio))
                let samples = receiver.renderFrames(required)
                _ = resampler.process(samples, outputFrameCount: callback, ratio: ratio)
                if first == nil && offlineLastRendered > 0 { first = next }
                if first != nil { underflow += required - offlineLastRendered }
                callbacks += 1
                render = base + UInt64(Double(callbacks * callback) * 1e9 / 48_000)
            }
        }
        let counts = receiver.offlineStretchCounts
        let result = PlaybackResult(scenario: scenario, content: content, adaptive: adaptive,
            capacityBatch: capacityBatch,
            seed: seed, callbackFrames: callback, uncertaintyMilliseconds: uncertainty,
            concealedPreparedFrames: offlineConcealedFrames, underflowAfterStartFrames: underflow,
            latePackets: Int(receiver.jitterStats?.latePackets ?? 0), expiredOutputFrames: Int(receiver.offlineExpired),
            requestedCorrectionMean: corrections.reduce(0, +) / Double(corrections.count),
            realizedCorrection: counts.1 > 0 ? Double(counts.0) / Double(counts.1) - 1 : 0,
            firstOutputMilliseconds: first.map { Double($0 - base) / 1e6 } ?? -1,
            maximumPresentationMilliseconds: Double(hearport_offline_maximum_age()) / 1e6 + 11,
            sourceFramesConsumed: receiver.offlinePlayedSource ?? 0)
        XCTAssertGreaterThanOrEqual(result.firstOutputMilliseconds, 0)
        XCTAssertLessThan(result.maximumPresentationMilliseconds, 100.001)
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
                        for capacityBatch in adaptive ? [false, true] : [false] {
                            results.append(try run(scenario: scenario, content: content,
                                adaptive: adaptive, seed: 1, callback: 256, uncertainty: uncertainty,
                                capacityBatch: capacityBatch))
                        }
                    }
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let path = ProcessInfo.processInfo.environment["HEARPORT_PLAYBACK_RESULTS"] {
            try encoder.encode(results).write(to: URL(fileURLWithPath: path))
        }
        print("offline_playback_cases=\(results.count) simulated_seconds=\(results.count * 12)")
    }
}
