import Foundation

public enum AudioDatagramError: Error, Equatable {
    case invalidLength(Int)
    case zeroStreamID
}

public struct AudioDatagram: Equatable, Sendable {
    public static let headerByteCount = 8
    public static let pcmByteCount = 960
    public static let byteCount = headerByteCount + pcmByteCount
    public static let framesPerPacket = 120

    public let streamID: UInt32
    public let sequence: UInt32
    public let pcm: Data

    public init(streamID: UInt32, sequence: UInt32, pcm: Data) throws {
        guard streamID != 0 else { throw AudioDatagramError.zeroStreamID }
        guard pcm.count == Self.pcmByteCount else {
            throw AudioDatagramError.invalidLength(Self.headerByteCount + pcm.count)
        }
        self.streamID = streamID
        self.sequence = sequence
        self.pcm = pcm
    }

    public init(encoded: Data) throws {
        guard encoded.count == Self.byteCount else {
            throw AudioDatagramError.invalidLength(encoded.count)
        }
        let streamID = Self.readUInt32BE(encoded, offset: 0)
        guard streamID != 0 else { throw AudioDatagramError.zeroStreamID }
        try self.init(
            streamID: streamID,
            sequence: Self.readUInt32BE(encoded, offset: 4),
            pcm: encoded.subdata(in: Self.headerByteCount..<Self.byteCount)
        )
    }

    public var encoded: Data {
        var result = Data(repeating: 0, count: Self.byteCount)
        Self.writeUInt32BE(streamID, into: &result, offset: 0)
        Self.writeUInt32BE(sequence, into: &result, offset: 4)
        result.replaceSubrange(Self.headerByteCount..<Self.byteCount, with: pcm)
        return result
    }

    private static func readUInt32BE(_ data: Data, offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) |
            (UInt32(data[offset + 1]) << 16) |
            (UInt32(data[offset + 2]) << 8) |
            UInt32(data[offset + 3])
    }

    private static func writeUInt32BE(_ value: UInt32, into data: inout Data,
                                      offset: Int) {
        data[offset] = UInt8((value >> 24) & 0xff)
        data[offset + 1] = UInt8((value >> 16) & 0xff)
        data[offset + 2] = UInt8((value >> 8) & 0xff)
        data[offset + 3] = UInt8(value & 0xff)
    }
}
