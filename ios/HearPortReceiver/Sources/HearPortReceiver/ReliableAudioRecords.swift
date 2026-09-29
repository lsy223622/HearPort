import Foundation

enum ReliableAudioRecordsError: Error {
    case invalidPreface
    case invalidRecord
    case incompleteRecord
}

struct ReliableAudioRecords {
    let expectedStreamID: UInt32
    private(set) var generation: UInt32?
    private var pending = Data()

    init(expectedStreamID: UInt32) {
        self.expectedStreamID = expectedStreamID
    }

    mutating func append(_ bytes: Data) throws -> [AudioDatagram] {
        pending.append(bytes)
        if generation == nil {
            guard pending.count >= 8 else { return [] }
            let streamID = Self.readUInt32(pending, at: 0)
            let value = Self.readUInt32(pending, at: 4)
            guard streamID == expectedStreamID, value != 0 else {
                throw ReliableAudioRecordsError.invalidPreface
            }
            generation = value
            pending.removeSubrange(0..<8)
        }

        var packets: [AudioDatagram] = []
        var consumed = 0
        while pending.count - consumed >= AudioDatagram.byteCount {
            let end = consumed + AudioDatagram.byteCount
            guard let packet = try? AudioDatagram(encoded: pending.subdata(in: consumed..<end)),
                  packet.streamID == expectedStreamID else {
                throw ReliableAudioRecordsError.invalidRecord
            }
            packets.append(packet)
            consumed = end
        }
        if consumed != 0 {
            pending.removeSubrange(0..<consumed)
        }
        return packets
    }

    func finish() throws {
        guard generation != nil, pending.isEmpty else {
            throw ReliableAudioRecordsError.incompleteRecord
        }
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) |
            (UInt32(data[offset + 1]) << 16) |
            (UInt32(data[offset + 2]) << 8) |
            UInt32(data[offset + 3])
    }
}

struct ReliableProbeRecords {
    let expectedStreamID: UInt32
    private(set) var generation: UInt32?
    private var pending = Data()

    init(expectedStreamID: UInt32) {
        self.expectedStreamID = expectedStreamID
    }

    mutating func append(_ bytes: Data) throws -> [Data] {
        pending.append(bytes)
        if generation == nil {
            guard pending.count >= 8 else { return [] }
            let streamID = pending.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let value = pending.dropFirst(4).prefix(4).reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            guard streamID == expectedStreamID, value != 0 else {
                throw ReliableAudioRecordsError.invalidPreface
            }
            generation = value
            pending.removeSubrange(0..<8)
        }
        var packets: [Data] = []
        var consumed = 0
        while pending.count - consumed >= 2 {
            let length = (Int(pending[consumed]) << 8) | Int(pending[consumed + 1])
            guard (8...968).contains(length) else {
                throw ReliableAudioRecordsError.invalidRecord
            }
            guard pending.count - consumed >= length + 2 else { break }
            let packet = pending.subdata(in: consumed + 2..<consumed + 2 + length)
            let streamID = packet.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard streamID == expectedStreamID else {
                throw ReliableAudioRecordsError.invalidRecord
            }
            packets.append(packet)
            consumed += length + 2
        }
        if consumed != 0 { pending.removeSubrange(0..<consumed) }
        return packets
    }

    func finish() throws {
        guard generation != nil, pending.isEmpty else {
            throw ReliableAudioRecordsError.incompleteRecord
        }
    }
}
