import Foundation
import HearPortOpusBridge

protocol CompressionOpusFrameDecoding: AnyObject {
    func decode(packet: Data?, frameCount: Int) -> [Float]?
}

final class NativeCompressionOpusDecoder: CompressionOpusFrameDecoding {
    private let decoder: UnsafeMutableRawPointer

    init() throws {
        var error: Int32 = 0
        guard let decoder = hp_opus_decoder_create(&error) else {
            throw CompressionMusicDecoderError.opusDecoderCreation(error)
        }
        self.decoder = decoder
    }

    deinit { hp_opus_decoder_destroy(decoder) }

    func decode(packet: Data?, frameCount: Int) -> [Float]? {
        guard (120...5760).contains(frameCount), frameCount.isMultiple(of: 120) else { return nil }
        var samples = [Float](repeating: 0, count: frameCount * 2)
        let decoded = samples.withUnsafeMutableBufferPointer { output -> Int32 in
            guard let destination = output.baseAddress else { return -1 }
            guard let packet else {
                return hp_opus_decode(decoder, nil, 0, destination, Int32(frameCount))
            }
            return packet.withUnsafeBytes { bytes in
                hp_opus_decode(decoder, bytes.bindMemory(to: UInt8.self).baseAddress,
                               Int32(packet.count), destination, Int32(frameCount))
            }
        }
        guard decoded == Int32(frameCount), samples.allSatisfy(\.isFinite) else { return nil }
        return samples
    }
}

enum CompressionMusicDecoderError: Error {
    case opusDecoderCreation(Int32)
}

struct CompressionMusicSummary: Equatable {
    let packets: Int
    let received: Int
    let decodedAdmittedFrames: Int
    let sourceFramesPrepared: Int
    let missingFrames: Int
    let longestMissingSourceFrames: Int
    let decoderMissingFrames: Int
    let playoutExpiredOutputFrames: Int
    let playoutSourceFrames: Int
    let complete: Bool
    let latePackets: Int
    let invalidPackets: Int
    let decodeFailures: Int
    let plcFrames: Int
    let wireBytes: Int
    let decodeCount: Int
    let decodeInitNanoseconds: UInt64
    let firstDecodeElapsedNanoseconds: UInt64?
    let decodeP50Nanoseconds: UInt64?
    let decodeP95Nanoseconds: UInt64?
    let decodeP99Nanoseconds: UInt64?
    let decodeMaximumNanoseconds: UInt64
}

final class CompressionMusicDecoder {
    private struct PendingPacket {
        let record: TimedAudioRecord
        let captureAt: UInt64
        let uncertainty: UInt64
        let receivedAt: UInt64
    }

    private static let sampleLimit = 1_024
    private static let decodeLeadMilliseconds = 2.0
    private static let packetsPerAdvance = 64

    private let round: MusicTestRound
    private let streamID: UInt32
    private let budget: PlayoutBudget
    private let diagnostics: HearPortDiagnostics
    private let startedAt: UInt64
    private let monotonicNow: () -> UInt64
    private let currentTargetMilliseconds: () -> Double
    private let onDecoded: (TimedAudioRecord) -> Bool
    private let recordSummary: ([String: String]) -> Void
    private let lock = NSLock()
    private let opusDecoder: CompressionOpusFrameDecoding?
    private let decodeInitNanoseconds: UInt64
    private var timer: DispatchSourceTimer?
    private var pending: [UInt32: PendingPacket] = [:]
    private var seenStatelessPackets = Set<UInt32>()
    private var expectedSequence: UInt32
    private var captureAnchor: UInt64?
    private var captureAnchorUncertainty: UInt64 = 0
    private var finished = false
    private var packets = 0
    private var receivedPackets = 0
    private var decodedAdmittedFrames = 0
    private var latePackets = 0
    private var invalidPackets = 0
    private var decodeFailures = 0
    private var plcFrames = 0
    private var wireBytes = 0
    private var decodeCount = 0
    private var decodeTotalNanoseconds: UInt64 = 0
    private var decodeMaximumNanoseconds: UInt64 = 0
    private var decodeSamples: [UInt64] = []
    private var firstDecodeElapsedNanoseconds: UInt64?

    init(round: MusicTestRound,
         streamID: UInt32,
         budget: PlayoutBudget,
         diagnostics: HearPortDiagnostics,
         roundStartedAt: UInt64 = DispatchTime.now().uptimeNanoseconds,
         opusDecoder injectedOpusDecoder: CompressionOpusFrameDecoding? = nil,
         startsTimer: Bool = true,
         monotonicNow: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         currentTargetMilliseconds: (() -> Double)? = nil,
         recordSummary: @escaping ([String: String]) -> Void = { _ in },
         onDecoded: @escaping (TimedAudioRecord) -> Bool) throws {
        self.round = round
        self.streamID = streamID
        self.budget = budget
        self.diagnostics = diagnostics
        startedAt = roundStartedAt
        self.monotonicNow = monotonicNow
        self.currentTargetMilliseconds = currentTargetMilliseconds ?? { budget.targetMilliseconds }
        self.onDecoded = onDecoded
        self.recordSummary = recordSummary
        expectedSequence = round.firstSequence
        decodeSamples.reserveCapacity(Self.sampleLimit)

        let creationStartedAt = DispatchTime.now().uptimeNanoseconds
        if round.codec == .opus {
            opusDecoder = try injectedOpusDecoder ?? NativeCompressionOpusDecoder()
            decodeInitNanoseconds = injectedOpusDecoder == nil
                ? DispatchTime.now().uptimeNanoseconds - creationStartedAt : 0
        } else {
            opusDecoder = nil
            decodeInitNanoseconds = 0
        }

        let fields = Self.roundFields(round: round, streamID: streamID, budget: budget)
        var startFields = fields
        startFields["event"] = "compression_round"
        startFields["decode_init_ns"] = "\(decodeInitNanoseconds)"
        if round.codec == .opus, let version = hp_opus_version() {
            startFields["codec_version"] = String(cString: version)
        }
        diagnostics.logAsync(.info, category: .audio, message: "compression_round", fields: startFields)

        if startsTimer {
            let timer = DispatchSource.makeTimerSource(
                queue: DispatchQueue(label: "com.hearport.receiver.compression-music-timer")
            )
            timer.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5),
                           leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.advance() }
            self.timer = timer
            timer.resume()
        }
    }

    deinit { timer?.cancel() }

    func receive(_ record: TimedAudioRecord,
                 mappedCapturedAt: UInt64?,
                 uncertainty: UInt64 = 0,
                 receivedAt: UInt64? = nil) {
        let now = receivedAt ?? monotonicNow()
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        packets += 1
        wireBytes += 32 + record.payload.count + (round.reliable ? 2 : 0)

        guard valid(record), let mappedCapturedAt else {
            invalidPackets += 1
            return
        }
        receivedPackets += 1
        if captureAnchor == nil {
            guard let anchor = Self.captureAnchor(for: record, firstSequence: round.firstSequence,
                                                  mappedCapture: mappedCapturedAt) else {
                invalidPackets += 1
                return
            }
            captureAnchor = anchor
            captureAnchorUncertainty = uncertainty
        }
        if SequenceNumber.isBefore(record.sequence, expectedSequence) {
            latePackets += 1
            return
        }
        if pending[record.sequence] != nil {
            invalidPackets += 1
            return
        }
        if round.codec != .opus {
            guard seenStatelessPackets.insert(record.sequence).inserted else {
                invalidPackets += 1
                return
            }
            decodeStatelessLocked(record, mappedCapture: mappedCapturedAt,
                                  uncertainty: uncertainty, receivedAt: now)
            return
        }
        let capacity = max(32, Int(ceil(budget.maximumMilliseconds /
            (Double(round.frameCount) / 48_000 * 1_000))) + 8)
        guard pending.count < capacity else {
            invalidPackets += 1
            return
        }
        pending[record.sequence] = PendingPacket(record: record, captureAt: mappedCapturedAt,
            uncertainty: uncertainty, receivedAt: now)
        advanceLocked(at: now)
    }

    func advance(at now: UInt64? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        advanceLocked(at: now ?? monotonicNow())
    }

    @discardableResult
    func finish(at now: UInt64? = nil,
                reason: String,
                sourceFramesPrepared: Int = 0,
                longestMissingSourceFrames: Int = 0,
                playoutExpiredOutputFrames: Int = 0,
                playoutSourceFrames: Int = 0) -> CompressionMusicSummary? {
        lock.lock()
        guard !finished else { lock.unlock(); return nil }
        let finishedAt = now ?? monotonicNow()
        finished = true
        timer?.cancel()
        timer = nil
        pending.removeAll(keepingCapacity: false)
        let ordered = decodeSamples.sorted()
        let expectedFrames = round.seconds * 48_000
        let decoderMissingFrames = max(0, expectedFrames - decodedAdmittedFrames)
        let elapsed = finishedAt >= startedAt ? finishedAt - startedAt : 0
        let completionThreshold = UInt64(round.seconds) * 1_000_000_000 +
            UInt64(budget.maximumMilliseconds * 1_000_000)
        let complete = elapsed >= completionThreshold &&
            (reason == "next_round" || reason == "diagnostics_end")
        let preparedSourceFrames = min(expectedFrames, max(0, sourceFramesPrepared))
        let summary = CompressionMusicSummary(
            packets: expectedFrames / round.frameCount,
            received: receivedPackets,
            decodedAdmittedFrames: decodedAdmittedFrames,
            sourceFramesPrepared: preparedSourceFrames,
            missingFrames: expectedFrames - preparedSourceFrames,
            longestMissingSourceFrames: min(expectedFrames - preparedSourceFrames,
                                            max(0, longestMissingSourceFrames)),
            decoderMissingFrames: decoderMissingFrames,
            playoutExpiredOutputFrames: max(0, playoutExpiredOutputFrames),
            playoutSourceFrames: max(0, playoutSourceFrames),
            complete: complete,
            latePackets: latePackets,
            invalidPackets: invalidPackets,
            decodeFailures: decodeFailures,
            plcFrames: plcFrames,
            wireBytes: wireBytes + (round.reliable ? 8 : 0),
            decodeCount: decodeCount,
            decodeInitNanoseconds: decodeInitNanoseconds,
            firstDecodeElapsedNanoseconds: firstDecodeElapsedNanoseconds,
            decodeP50Nanoseconds: Self.percentile(ordered, fraction: 0.50),
            decodeP95Nanoseconds: Self.percentile(ordered, fraction: 0.95),
            decodeP99Nanoseconds: Self.percentile(ordered, fraction: 0.99),
            decodeMaximumNanoseconds: decodeMaximumNanoseconds
        )
        lock.unlock()

        var fields = Self.roundFields(round: round, streamID: streamID, budget: budget)
        fields["event"] = "compression_summary"
        fields["reason"] = reason
        fields["packets"] = "\(summary.packets)"
        fields["received"] = "\(summary.received)"
        fields["decoded_admitted_frames"] = "\(summary.decodedAdmittedFrames)"
        fields["source_frames_prepared"] = "\(summary.sourceFramesPrepared)"
        fields["missing_frames"] = "\(summary.missingFrames)"
        fields["longest_missing_source_frames"] = "\(summary.longestMissingSourceFrames)"
        fields["longest_missing_ms"] = String(format: "%.3f", Double(summary.longestMissingSourceFrames) / 48)
        fields["missing_measurement_source"] = "source_preparation"
        fields["decoder_missing_frames"] = "\(summary.decoderMissingFrames)"
        fields["playout_expired_output_frames"] = "\(summary.playoutExpiredOutputFrames)"
        fields["playout_source_frames"] = "\(summary.playoutSourceFrames)"
        fields["complete"] = summary.complete ? "1" : "0"
        fields["elapsed_ns"] = "\(elapsed)"
        fields["late_packets"] = "\(summary.latePackets)"
        fields["invalid_packets"] = "\(summary.invalidPackets)"
        fields["decode_failures"] = "\(summary.decodeFailures)"
        fields["plc_frames"] = "\(summary.plcFrames)"
        fields["wire_bytes"] = "\(summary.wireBytes)"
        fields["decode_count"] = "\(summary.decodeCount)"
        fields["decode_ns"] = "\(decodeTotalNanoseconds)"
        fields["decode_init_ns"] = "\(summary.decodeInitNanoseconds)"
        fields["first_decode_after_ns"] = summary.firstDecodeElapsedNanoseconds.map(String.init) ?? "none"
        fields["decode_p50_ns"] = summary.decodeP50Nanoseconds.map(String.init) ?? "none"
        fields["decode_p95_ns"] = summary.decodeP95Nanoseconds.map(String.init) ?? "none"
        fields["decode_p99_ns"] = summary.decodeP99Nanoseconds.map(String.init) ?? "none"
        fields["decode_max_ns"] = "\(summary.decodeMaximumNanoseconds)"
        fields["decode_mean_ns"] = summary.decodeCount == 0 ? "none" :
            "\(decodeTotalNanoseconds / UInt64(summary.decodeCount))"
        diagnostics.logAsync(.info, category: .audio, message: "compression_summary", fields: fields)
        recordSummary(fields)
        return summary
    }

    func valid(_ record: TimedAudioRecord) -> Bool {
        let expectedKind: AudioRecordKind = round.profile == 0 ? .audio :
            (round.profile == 1 ? .pcm16 : .opus)
        let totalUnits = UInt32(round.seconds * 400)
        guard record.streamID == streamID, record.generation == round.generation,
              record.kind == expectedKind, record.frameCount == round.frameCount,
              !SequenceNumber.isBefore(record.sequence, round.firstSequence),
              record.sequence &- round.firstSequence < totalUnits,
              (record.sequence &- round.firstSequence).isMultiple(of: UInt32(round.frameCount / 120)),
              record.sourceFrame == UInt64(record.sequence) * 120 else { return false }
        return true
    }

    private func advanceLocked(at now: UInt64) {
        guard round.codec == .opus, let captureAnchor else { return }
        let packetSequenceStep = UInt32(round.frameCount / 120)
        for _ in 0..<Self.packetsPerAdvance {
            guard expectedSequence &- round.firstSequence < UInt32(round.seconds * 400) else { return }
            if let packet = pending.removeValue(forKey: expectedSequence) {
                let deadline = budget.prepareDeadline(capturedAt: packet.captureAt,
                    processingMilliseconds: Self.decodeLeadMilliseconds,
                    uncertaintyNanoseconds: packet.uncertainty)
                if packet.receivedAt >= deadline || now >= deadline {
                    latePackets += 1
                    concealCodecState(frames: round.frameCount)
                    expectedSequence &+= packetSequenceStep
                    continue
                }
                let decodeStarted = DispatchTime.now().uptimeNanoseconds
                let decoded = decode(packet.record.payload, frames: round.frameCount)
                let decodeElapsed = DispatchTime.now().uptimeNanoseconds - decodeStarted
                recordDecodeDuration(decodeElapsed)
                if firstDecodeElapsedNanoseconds == nil {
                    let firstNow = monotonicNow()
                    firstDecodeElapsedNanoseconds = firstNow >= startedAt ? firstNow - startedAt : 0
                }
                let completedAt = monotonicNow()
                if completedAt >= deadline {
                    latePackets += 1
                    expectedSequence &+= packetSequenceStep
                    continue
                }
                guard let decoded else {
                    decodeFailures += 1
                    expectedSequence &+= packetSequenceStep
                    continue
                }
                var acceptedFrames = 0
                for slice in 0..<(round.frameCount / 120) {
                    let sampleStart = slice * 240
                    let samples = Array(decoded[sampleStart..<(sampleStart + 240)])
                    guard let record = makePCMRecord(from: packet, slice: slice, samples: samples),
                          onDecoded(record) else { continue }
                    acceptedFrames += 120
                }
                decodedAdmittedFrames += acceptedFrames
                expectedSequence &+= packetSequenceStep
                continue
            }

            let offsetUnits = UInt64(expectedSequence &- round.firstSequence)
            let sourceFrames = offsetUnits * 120
            let expectedCapture = captureAnchor &+ sourceFrames * 1_000_000_000 / 48_000
            guard now >= Self.latestStart(captureAt: expectedCapture, budget: budget,
                targetMilliseconds: currentTargetMilliseconds()) else { return }
            concealCodecState(frames: round.frameCount)
            expectedSequence &+= packetSequenceStep
        }
    }

    private func decodeStatelessLocked(_ record: TimedAudioRecord,
                                       mappedCapture: UInt64,
                                       uncertainty: UInt64,
                                       receivedAt: UInt64) {
        let deadline = budget.prepareDeadline(capturedAt: mappedCapture,
            processingMilliseconds: Self.decodeLeadMilliseconds,
            uncertaintyNanoseconds: uncertainty)
        guard receivedAt < deadline else {
            latePackets += 1
            return
        }

        let packet = PendingPacket(record: record, captureAt: mappedCapture,
            uncertainty: uncertainty, receivedAt: receivedAt)
        let decodeStarted = DispatchTime.now().uptimeNanoseconds
        let decoded = decode(record.payload, frames: round.frameCount)
        let decodeElapsed = DispatchTime.now().uptimeNanoseconds - decodeStarted
        recordDecodeDuration(decodeElapsed)
        if firstDecodeElapsedNanoseconds == nil {
            let firstNow = monotonicNow()
            firstDecodeElapsedNanoseconds = firstNow >= startedAt ? firstNow - startedAt : 0
        }
        guard monotonicNow() < deadline else {
            latePackets += 1
            return
        }
        guard let decoded else {
            decodeFailures += 1
            return
        }

        var acceptedFrames = 0
        for slice in 0..<(round.frameCount / 120) {
            let sampleStart = slice * 240
            let samples = Array(decoded[sampleStart..<(sampleStart + 240)])
            guard let output = makePCMRecord(from: packet, slice: slice, samples: samples),
                  onDecoded(output) else { continue }
            acceptedFrames += 120
        }
        decodedAdmittedFrames += acceptedFrames
    }

    private func decode(_ payload: Data, frames: Int) -> [Float]? {
        switch round.codec {
        case .floatPCM:
            guard payload.count == 960 else { return nil }
            var samples = [Float]()
            samples.reserveCapacity(240)
            for offset in stride(from: 0, to: payload.count, by: 4) {
                let bits = UInt32(payload[offset]) | (UInt32(payload[offset + 1]) << 8) |
                    (UInt32(payload[offset + 2]) << 16) | (UInt32(payload[offset + 3]) << 24)
                let sample = Float(bitPattern: bits)
                guard sample.isFinite else { return nil }
                samples.append(sample)
            }
            return samples
        case .pcm16:
            guard payload.count == 480 else { return nil }
            var samples = [Float]()
            samples.reserveCapacity(240)
            for offset in stride(from: 0, to: payload.count, by: 2) {
                let bits = UInt16(payload[offset]) | (UInt16(payload[offset + 1]) << 8)
                samples.append(Float(Int16(bitPattern: bits)) / 32_768)
            }
            return samples
        case .opus:
            guard let decoded = opusDecoder?.decode(packet: payload, frameCount: frames),
                  decoded.count == frames * 2 else { return nil }
            return decoded
        }
    }

    private func concealCodecState(frames: Int) {
        guard round.codec == .opus else { return }
        _ = opusDecoder?.decode(packet: nil, frameCount: frames)
        plcFrames += frames
    }

    private func makePCMRecord(from packet: PendingPacket, slice: Int,
                               samples: [Float]) -> TimedAudioRecord? {
        guard samples.count == 240 else { return nil }
        var payload = Data(capacity: 960)
        for sample in samples {
            guard sample.isFinite else { return nil }
            let bits = sample.bitPattern
            payload.append(UInt8(truncatingIfNeeded: bits))
            payload.append(UInt8(truncatingIfNeeded: bits >> 8))
            payload.append(UInt8(truncatingIfNeeded: bits >> 16))
            payload.append(UInt8(truncatingIfNeeded: bits >> 24))
        }
        let offsetFrames = UInt64(slice * 120)
        let sequence = packet.record.sequence &+ UInt32(slice)
        let capturedAt = packet.record.capturedAt &+ offsetFrames * 1_000_000_000 / 48_000
        let sourceFrame = packet.record.sourceFrame + offsetFrames
        return try? TimedAudioRecord(streamID: streamID, generation: round.generation,
            sequence: sequence, frameCount: 120, kind: .audio, capturedAt: capturedAt,
            sourceFrame: sourceFrame, payload: payload)
    }

    private func recordDecodeDuration(_ duration: UInt64) {
        decodeCount += 1
        decodeTotalNanoseconds &+= duration
        decodeMaximumNanoseconds = max(decodeMaximumNanoseconds, duration)
        if decodeSamples.count < Self.sampleLimit {
            decodeSamples.append(duration)
        } else if let index = Int(exactly: UInt64.random(in: 0..<UInt64(decodeCount))),
                  index < Self.sampleLimit {
            decodeSamples[index] = duration
        }
    }

    private static func percentile(_ sorted: [UInt64], fraction: Double) -> UInt64? {
        guard !sorted.isEmpty else { return nil }
        let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1)
        return sorted[max(0, index)]
    }

    private static func captureAnchor(for record: TimedAudioRecord,
                                      firstSequence: UInt32,
                                      mappedCapture: UInt64) -> UInt64? {
        let offsetUnits = UInt64(record.sequence &- firstSequence)
        let offsetNanoseconds = offsetUnits * 120 * 1_000_000_000 / 48_000
        guard mappedCapture >= offsetNanoseconds else { return nil }
        return mappedCapture - offsetNanoseconds
    }

    private static func latestStart(captureAt: UInt64, budget: PlayoutBudget,
                                    targetMilliseconds: Double) -> UInt64 {
        let target = min(budget.maximumMilliseconds, max(budget.targetMilliseconds,
                                                         targetMilliseconds))
        let allowance = max(0, target - budget.outputReserveMilliseconds -
                            decodeLeadMilliseconds) * 1_000_000
        let (deadline, overflow) = captureAt.addingReportingOverflow(UInt64(allowance))
        return overflow ? .max : deadline
    }

    private static func roundFields(round: MusicTestRound, streamID: UInt32,
                                     budget: PlayoutBudget) -> [String: String] {
        ["source": "real", "side": "receiver", "stream_id": "\(streamID)",
         "round": "\(round.index)", "profile": "\(round.profile)",
         "repeat": "\(round.repeatIndex)", "transport": round.reliable ? "reliable_stream" : "datagram",
         "codec": round.codec.rawValue, "bitrate": "\(round.bitrateKbps * 1_000)",
         "bitrate_kbps": "\(round.bitrateKbps)",
         "frame_count": "\(round.frameCount)", "duration_seconds": "\(round.seconds)",
         "lookahead_frames": "\(round.codecLookaheadFrames)",
         "target_ms": String(format: "%.1f", budget.targetMilliseconds),
         "maximum_ms": String(format: "%.1f", budget.maximumMilliseconds)]
    }
}
