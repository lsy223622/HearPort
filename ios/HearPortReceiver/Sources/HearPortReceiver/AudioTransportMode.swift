public enum AudioTransportMode: String, Sendable {
    case datagram
    case reliable

    public func bufferTargetPackets(selected: Int) -> Int {
        switch self {
        case .datagram:
            return JitterBufferConfiguration(targetPackets: selected).targetPackets
        case .reliable:
            return 64
        }
    }
}
