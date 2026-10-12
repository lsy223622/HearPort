import Foundation

public enum AudioDatagramError: Error, Equatable {
    case invalidLength(Int)
    case zeroStreamID
}

public enum AudioRecordKind: UInt16, Sendable { case audio, fec, retransmission, repeated, probe }

public struct TimedAudioRecord: Equatable, Sendable {
    public let streamID: UInt32
    public let generation: UInt32
    public let sequence: UInt32
    public let frameCount: UInt16
    public let kind: AudioRecordKind
    public let capturedAt: UInt64
    public let sourceFrame: UInt64
    public let payload: Data

    public init(streamID: UInt32, generation: UInt32, sequence: UInt32,
                frameCount: UInt16, kind: AudioRecordKind, capturedAt: UInt64,
                sourceFrame: UInt64, payload: Data) throws {
        let pcm = kind == .audio || kind == .retransmission || kind == .repeated
        guard streamID != 0, generation != 0, capturedAt != 0, frameCount != 0,
              !payload.isEmpty, payload.count <= 992,
              !pcm || (frameCount == 120 && payload.count == 960) else {
            throw AudioDatagramError.invalidLength(payload.count + 32)
        }
        self.streamID = streamID
        self.generation = generation
        self.sequence = sequence
        self.frameCount = frameCount
        self.kind = kind
        self.capturedAt = capturedAt
        self.sourceFrame = sourceFrame
        self.payload = payload
    }

    public init(encoded: Data) throws {
        guard encoded.count > 32, encoded.count <= 1024,
              let kind = AudioRecordKind(rawValue: UInt16(Self.read(encoded, 14, 2))) else {
            throw AudioDatagramError.invalidLength(encoded.count)
        }
        try self.init(streamID: UInt32(Self.read(encoded, 0, 4)),
            generation: UInt32(Self.read(encoded, 4, 4)), sequence: UInt32(Self.read(encoded, 8, 4)),
            frameCount: UInt16(Self.read(encoded, 12, 2)), kind: kind,
            capturedAt: Self.read(encoded, 16, 8), sourceFrame: Self.read(encoded, 24, 8),
            payload: encoded.subdata(in: 32..<encoded.count))
    }

    public var encoded: Data {
        var bytes = Data()
        for (value, count) in [(UInt64(streamID), 4), (UInt64(generation), 4),
            (UInt64(sequence), 4), (UInt64(frameCount), 2), (UInt64(kind.rawValue), 2),
            (capturedAt, 8), (sourceFrame, 8)] {
            for index in (0..<count).reversed() {
                bytes.append(UInt8(truncatingIfNeeded: value >> (index * 8)))
            }
        }
        bytes.append(payload)
        return bytes
    }

    private static func read(_ bytes: Data, _ offset: Int, _ count: Int) -> UInt64 {
        bytes[offset..<(offset + count)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
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
