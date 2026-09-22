import Foundation

public struct JitterBufferConfiguration: Equatable, Sendable {
    public static let supportedTargetPacketCounts = [4, 8, 16, 32, 64, 128]
    public static let defaultTargetPackets = 8

    public let targetPackets: Int
    public let targetLatencyMilliseconds: Int

    public init(targetPackets: Int) {
        let normalized = Self.supportedTargetPacketCounts.contains(targetPackets)
            ? targetPackets
            : Self.defaultTargetPackets
        self.targetPackets = normalized
        targetLatencyMilliseconds = normalized * AudioDatagram.framesPerPacket * 1_000 / 48_000
    }

    public static let balanced = Self(targetPackets: defaultTargetPackets)
}
