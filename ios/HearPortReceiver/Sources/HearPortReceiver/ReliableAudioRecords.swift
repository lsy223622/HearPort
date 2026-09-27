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
