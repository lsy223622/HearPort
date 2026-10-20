import Foundation

/// Converts bounded, ordered Opus records into the existing 120-frame PCM timeline.
final class LiveAudioDecoder {
    private struct Packet {
        let record: TimedAudioRecord
        let captured: UInt64
        let uncertainty: UInt64
    }
    private let format: AudioStreamFormat
    private let streamID: UInt32
    private let budget: PlayoutBudget
    private var decoder: CompressionOpusFrameDecoding
    private let makeDecoder: () throws -> CompressionOpusFrameDecoding
    private let output: (TimedAudioRecord) -> Void
    private let now: () -> UInt64
    private let lock = NSLock()
    private var pending: [UInt32: Packet] = [:]
    private var expected: UInt32 = 0
    private var stopped = false
    private var timer: DispatchSourceTimer?
    private let capacity: Int

    init(format: AudioStreamFormat, streamID: UInt32, budget: PlayoutBudget,
         decoder: CompressionOpusFrameDecoding? = nil, startsTimer: Bool = true,
         now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         output: @escaping (TimedAudioRecord) -> Void) throws {
        self.format = format; self.streamID = streamID; self.budget = budget
        self.decoder = try decoder ?? NativeCompressionOpusDecoder()
        self.makeDecoder = { try decoder ?? NativeCompressionOpusDecoder() }
        self.output = output; self.now = now
        capacity = Int(ceil(budget.maximumMilliseconds * 48 / Double(format.frameCount))) + 8
        if startsTimer {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.hearport.live-opus"))
            timer.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5),
                           leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.advance() }
            self.timer = timer; timer.resume()
        }
    }

    deinit { timer?.cancel() }

    func valid(_ record: TimedAudioRecord) -> Bool {
        record.streamID == streamID && record.generation == 1 && record.kind == .opus &&
            record.frameCount == format.frameCount &&
            record.sequence.isMultiple(of: UInt32(format.frameCount / 120)) &&
            record.sourceFrame.isMultiple(of: 120) &&
            UInt32(truncatingIfNeeded: record.sourceFrame / 120) == record.sequence
    }

    func receive(_ record: TimedAudioRecord, captured: UInt64, uncertainty: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, valid(record),
              !SequenceNumber.isBefore(record.sequence, expected), pending[record.sequence] == nil,
              pending.count < capacity else { return }
        if record.sequence &- expected > UInt32(capacity * format.frameCount / 120) {
            guard let replacement = try? makeDecoder() else { return }
            decoder = replacement; pending.removeAll(); expected = record.sequence
        }
        pending[record.sequence] = Packet(record: record, captured: captured, uncertainty: uncertainty)
        advanceLocked()
    }

    func advance() { lock.lock(); defer { lock.unlock() }; advanceLocked() }

    func stop() {
        lock.lock(); stopped = true; pending.removeAll(); timer?.cancel(); timer = nil; lock.unlock()
    }

    private func advanceLocked() {
        guard !stopped else { return }
        let step = UInt32(format.frameCount / 120)
        for _ in 0..<64 {
            if let packet = pending.removeValue(forKey: expected) {
                let deadline = budget.prepareDeadline(capturedAt: packet.captured,
                    processingMilliseconds: 2, uncertaintyNanoseconds: packet.uncertainty)
                if now() >= deadline {
                    _ = decoder.decode(packet: nil, frameCount: format.frameCount)
                } else if let samples = decoder.decode(packet: packet.record.payload, frameCount: format.frameCount),
                          samples.count == format.frameCount * 2, now() < deadline {
                    for slice in 0..<Int(step) {
                        let begin = slice * 240
                        var pcm = Data(); pcm.reserveCapacity(960)
                        for sample in samples[begin..<(begin + 240)] {
                            var bits = sample.bitPattern.littleEndian
                            withUnsafeBytes(of: &bits) { pcm.append(contentsOf: $0) }
                        }
                        if let record = try? TimedAudioRecord(streamID: streamID, generation: 1,
                            sequence: packet.record.sequence &+ UInt32(slice), frameCount: 120,
                            kind: .audio, capturedAt: packet.record.capturedAt + UInt64(slice) * 2_500_000,
                            sourceFrame: packet.record.sourceFrame + UInt64(slice) * 120, payload: pcm) {
                            output(record)
                        }
                    }
                }
                expected &+= step
                continue
            }
            // A future packet proves a gap. Silence alone must not advance the source clock.
            guard let next = pending.values.min(by: {
                ($0.record.sequence &- expected) < ($1.record.sequence &- expected)
            }) else { return }
            let offset = UInt64(next.record.sequence &- expected) * 2_500_000
            guard next.captured >= offset else { return }
            let capture = next.captured - offset
            let wait = max(0, budget.targetMilliseconds - budget.outputReserveMilliseconds - 2)
            guard now() >= capture + UInt64(wait * 1_000_000) else { return }
            _ = decoder.decode(packet: nil, frameCount: format.frameCount)
            expected &+= step
        }
    }
}
