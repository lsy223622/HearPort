import Foundation

public struct RepairWindow: Sendable {
    private struct Entry: Sendable { let record: TimedAudioRecord; let deadline: UInt64 }
    private var records: [UInt32: Entry] = [:]
    private var parities: [UInt32: Entry] = [:]
    private var gaps: [UInt32: (firstSeen: UInt64, requested: Bool, deadline: UInt64)] = [:]
    private var streamID: UInt32 = 0
    private var generation: UInt32 = 0

    public init() {}
    public mutating func reset() { self = RepairWindow() }

    public mutating func discard(before sequence: UInt32) {
        gaps = gaps.filter { !SequenceNumber.isBefore($0.key, sequence) }
    }

    public mutating func received(sequence: UInt32) { gaps.removeValue(forKey: sequence) }

    public mutating func ingest(_ record: TimedAudioRecord, deadline: UInt64,
                                now: UInt64) -> [TimedAudioRecord] {
        records = records.filter { $0.value.deadline > now }
        parities = parities.filter { $0.value.deadline > now }
        gaps = gaps.filter { $0.value.deadline > now }
        guard deadline > now else { return [] }
        if streamID != record.streamID || generation != record.generation {
            if streamID == record.streamID, generation != 0,
               SequenceNumber.isBefore(record.generation, generation) { return [] }
            reset(); streamID = record.streamID; generation = record.generation
        }
        if record.kind == .fec {
            guard record.frameCount == 4, record.sequence.isMultiple(of: 4) else { return [] }
            parities[record.sequence] = Entry(record: record, deadline: deadline)
            if parities.count > 64, let oldest = parities.min(by: { $0.value.deadline < $1.value.deadline }) {
                parities.removeValue(forKey: oldest.key)
            }
        } else {
            if records[record.sequence] == nil {
                records[record.sequence] = Entry(record: record, deadline: deadline)
            }
            gaps.removeValue(forKey: record.sequence)
            if records.count > 256, let oldest = records.min(by: { $0.value.deadline < $1.value.deadline }) {
                records.removeValue(forKey: oldest.key)
            }
        }
        let first = record.sequence & ~3
        guard let parity = parities[first] else { return [] }
        var missing: UInt32?
        var bytes = parity.record.payload
        for offset in 0..<4 {
            let sequence = first &+ UInt32(offset)
            guard let item = records[sequence] else {
                if missing != nil { return [] }
                missing = sequence; continue
            }
            let encoded = item.record.encoded
            guard encoded.count == bytes.count else { return [] }
            for index in 0..<bytes.count { bytes[index] ^= encoded[index] }
        }
        guard let missing, let original = try? TimedAudioRecord(encoded: bytes),
              original.sequence == missing, original.streamID == streamID,
              original.generation == generation, original.kind == .audio || original.kind == .probe,
              let restored = try? TimedAudioRecord(streamID: streamID, generation: generation,
                sequence: missing, frameCount: original.frameCount, kind: .retransmission,
                capturedAt: original.capturedAt, sourceFrame: original.sourceFrame, payload: original.payload)
        else { return [] }
        records[missing] = Entry(record: original, deadline: parity.deadline)
        gaps.removeValue(forKey: missing)
        parities.removeValue(forKey: first)
        return [restored]
    }

    public mutating func shouldRequest(sequence: UInt32, now: UInt64, deadline: UInt64,
                                      roundTripNanoseconds: UInt64) -> Bool {
        guard records[sequence] == nil, deadline > now,
              deadline - now > roundTripNanoseconds + 2_500_000 else { return false }
        if gaps[sequence] == nil {
            if gaps.count >= 256 { gaps = gaps.filter { $0.value.deadline > now } }
            guard gaps.count < 256 else { return false }
            gaps[sequence] = (now, false, deadline)
            return false
        }
        guard let gap = gaps[sequence], !gap.requested, now >= gap.firstSeen,
              now - gap.firstSeen >= max(2_500_000, roundTripNanoseconds / 2) else { return false }
        gaps[sequence] = (gap.firstSeen, true, deadline)
        return true
    }
}
