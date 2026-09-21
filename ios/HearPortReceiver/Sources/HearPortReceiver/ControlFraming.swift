import Foundation

public enum ControlFramingError: Error, Equatable {
    case emptyPayload
    case payloadTooLarge(Int)
    case decoderBufferExceeded
}

public enum ControlFraming {
    public static let maxPayloadBytes = 65_536

    public static func encode(_ payload: Data) throws -> Data {
        guard !payload.isEmpty else { throw ControlFramingError.emptyPayload }
        guard payload.count <= maxPayloadBytes else {
            throw ControlFramingError.payloadTooLarge(payload.count)
        }
        let length = UInt32(payload.count)
        var framed = Data([
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff)
        ])
        framed.append(payload)
        return framed
    }
}

public struct ControlFrameDecoder {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        guard buffer.count <= ControlFraming.maxPayloadBytes + 4 else {
            throw ControlFramingError.decoderBufferExceeded
        }

        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = (UInt32(buffer[0]) << 24) |
                (UInt32(buffer[1]) << 16) |
                (UInt32(buffer[2]) << 8) |
                UInt32(buffer[3])
            guard length != 0 else { throw ControlFramingError.emptyPayload }
            guard length <= ControlFraming.maxPayloadBytes else {
                throw ControlFramingError.payloadTooLarge(Int(length))
            }
            let frameLength = 4 + Int(length)
            guard buffer.count >= frameLength else { break }
            frames.append(buffer.subdata(in: 4..<frameLength))
            buffer.removeFirst(frameLength)
        }
        return frames
    }
}
