import Foundation

public enum JitterInsertResult: Equatable, Sendable {
    case inserted
    case duplicate
    case late
    case wrongStream
    case capacityExceeded
}

public enum JitterMode: Equatable, Sendable {
    case startup
    case running
    case silentRebuffer
}

public struct JitterStats: Equatable, Sendable {
    public fileprivate(set) var insertedPackets = 0
    public fileprivate(set) var duplicatePackets = 0
    public fileprivate(set) var latePackets = 0
    public fileprivate(set) var wrongStreamPackets = 0
    public fileprivate(set) var lostPackets = 0
    public fileprivate(set) var capacityDrops = 0
    public fileprivate(set) var trimmedPackets = 0
}

public struct JitterBuffer {
    public private(set) var streamID: UInt32
    public private(set) var mode: JitterMode = .startup
    public private(set) var stats = JitterStats()

    public let targetPackets: Int
    public let maximumPackets: Int
    private var packets: [UInt32: AudioDatagram] = [:]
    private var nextSequence: UInt32?
    private var unreportedTrimmedSequences: [UInt32] = []

    public init(streamID: UInt32, targetPackets: Int = 4, maximumPackets: Int = 256) {
        precondition(streamID != 0)
        precondition(targetPackets > 0)
        precondition(maximumPackets >= targetPackets)
        self.streamID = streamID
        self.targetPackets = targetPackets
        self.maximumPackets = maximumPackets
    }

    public init(streamID: UInt32,
                configuration: JitterBufferConfiguration,
                maximumPackets: Int = 256) {
        precondition(streamID != 0)
        precondition(maximumPackets >= configuration.targetPackets)
        self.streamID = streamID
        self.targetPackets = configuration.targetPackets
        self.maximumPackets = maximumPackets
    }

    public var fillPackets: Int { packets.count }
    public var expectedSequence: UInt32? { nextSequence }

    public var hasFuturePacket: Bool {
        guard let expected = nextSequence else { return false }
        return packets.keys.contains {
            $0 != expected && !SequenceNumber.isBefore($0, expected)
        }
    }

    public mutating func reset(streamID: UInt32) {
        precondition(streamID != 0)
        self.streamID = streamID
        mode = .startup
        packets.removeAll(keepingCapacity: true)
        nextSequence = nil
        unreportedTrimmedSequences.removeAll(keepingCapacity: true)
        stats = JitterStats()
    }

    mutating func takeTrimmedSequences() -> [UInt32] {
        let sequences = unreportedTrimmedSequences
        unreportedTrimmedSequences.removeAll(keepingCapacity: true)
        return sequences
    }

    public mutating func insert(_ packet: AudioDatagram) -> JitterInsertResult {
        guard packet.streamID == streamID else {
            stats.wrongStreamPackets += 1
            return .wrongStream
        }
        if let expected = nextSequence, SequenceNumber.isBefore(packet.sequence, expected) {
            stats.latePackets += 1
            return .late
        }
        if packets[packet.sequence] != nil {
            stats.duplicatePackets += 1
            return .duplicate
        }
        guard packets.count < maximumPackets || mode == .running else {
            stats.capacityDrops += 1
            return .capacityExceeded
        }
        if nextSequence == nil {
            nextSequence = packet.sequence
        }
        packets[packet.sequence] = packet
        stats.insertedPackets += 1
        trimToTarget()
        return .inserted
    }

    @discardableResult
    public mutating func startIfReady() -> Bool {
        guard mode != .running, nextSequence != nil,
              packets.count >= targetPackets else { return false }
        mode = .running
        trimToTarget()
        return true
    }

    public mutating func consumeNext() -> AudioDatagram? {
        guard mode == .running, let expected = nextSequence else { return nil }
        guard let packet = packets.removeValue(forKey: expected) else { return nil }
        nextSequence = SequenceNumber.next(expected)
        return packet
    }

    public mutating func concealMissing() -> Data? {
        guard mode == .running, let expected = nextSequence else { return nil }
        packets.removeValue(forKey: expected)
        nextSequence = SequenceNumber.next(expected)
        stats.lostPackets += 1
        return Data(repeating: 0, count: AudioDatagram.pcmByteCount)
    }

    public mutating func enterSilentRebuffer() {
        packets.removeAll(keepingCapacity: true)
        nextSequence = nil
        mode = .silentRebuffer
    }

    private mutating func trimToTarget() {
        guard mode == .running, packets.count > targetPackets else { return }
        guard let expected = nextSequence else { return }

        while packets.count > targetPackets {
            guard let oldestSequence = packets.keys.min(by: {
                ($0 &- expected) < ($1 &- expected)
            }) else { break }
            packets.removeValue(forKey: oldestSequence)
            unreportedTrimmedSequences.append(oldestSequence)
            stats.trimmedPackets += 1
        }
        nextSequence = packets.keys.min {
            ($0 &- expected) < ($1 &- expected)
        }
    }
}
