import Foundation

public struct JitterBufferConfiguration: Equatable, Sendable {
    public static let supportedStartupPacketCounts = [4, 8, 16, 32, 64, 128]
    public static let defaultStartupPackets = 8

    public let startupPackets: Int
    public let startupLatencyMilliseconds: Int

    public init(startupPackets: Int) {
        let normalized = Self.supportedStartupPacketCounts.contains(startupPackets)
            ? startupPackets
            : Self.defaultStartupPackets
        self.startupPackets = normalized
        startupLatencyMilliseconds = normalized * AudioDatagram.framesPerPacket * 1_000 / 48_000
    }

    public static let balanced = Self(startupPackets: defaultStartupPackets)
}
