import Foundation

public struct ProbeFrame {
    public enum Kind: UInt8 { case data = 1, ping, pong, finish, summary, hello }
    public let kind: Kind
    public let sequence: UInt32
    public let timestamp: UInt64
    public let payload: Data
    public init(kind: Kind, sequence: UInt32, timestamp: UInt64, payload: Data = Data()) {
        self.kind = kind; self.sequence = sequence; self.timestamp = timestamp; self.payload = payload
    }
    public func encoded() throws -> Data {
        guard payload.count <= 65_536 else { throw ProbeFrameError.invalidHeader }
        var bytes: [UInt8] = [0x48,0x50,0x55,0x31,1,kind.rawValue,0,0]
        func put(_ value: UInt64, _ count: Int) {
            for i in (0..<count).reversed() { bytes.append(UInt8(truncatingIfNeeded: value >> (i * 8))) }
        }
        put(UInt64(sequence),4); put(UInt64(payload.count),4); put(timestamp,8)
        put(UInt64(crc32(payload)),4); put(0,4)
        return Data(bytes) + payload
    }
}

public enum ProbeFrameError: Error { case invalidHeader, checksum }

public struct ProbeFrameDecoder {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [ProbeFrame] {
        buffer.append(data)
        var frames: [ProbeFrame] = []
        while buffer.count >= 32 {
            let header = Array(buffer.prefix(32))
            func get(_ offset: Int, _ count: Int) -> UInt64 {
                header[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
            }
            guard Array(header[0..<5]) == [0x48,0x50,0x55,0x31,1], let kind = ProbeFrame.Kind(rawValue: header[5]),
                  get(6,2) == 0, get(28,4) == 0, get(12,4) <= 65_536 else { throw ProbeFrameError.invalidHeader }
            let count = Int(get(12,4))
            guard buffer.count >= 32 + count else { break }
            let body = Data(buffer.dropFirst(32).prefix(count))
            guard crc32(body) == UInt32(get(24,4)) else { throw ProbeFrameError.checksum }
            frames.append(ProbeFrame(kind: kind, sequence: UInt32(get(8,4)), timestamp: get(16,8), payload: body))
            buffer = Data(buffer.dropFirst(32 + count))
        }
        return frames
    }
}

private let crcTable: [UInt32] = (0..<256).map { n in
    var value = UInt32(n)
    for _ in 0..<8 { value = value & 1 == 0 ? value >> 1 : (value >> 1) ^ 0xedb88320 }
    return value
}
private func crc32(_ data: Data) -> UInt32 {
    var value: UInt32 = 0xffffffff
    for byte in data { value = crcTable[Int((value ^ UInt32(byte)) & 255)] ^ (value >> 8) }
    return value ^ 0xffffffff
}
