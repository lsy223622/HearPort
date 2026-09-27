public enum AudioTransportMode: String, Sendable {
    case datagram
    case reliable

    public func bufferTargetPackets(selected: Int) -> Int {
        JitterBufferConfiguration(targetPackets: selected).targetPackets
    }
}
