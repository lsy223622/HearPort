import Foundation

public enum AudioTransportMode: String, Sendable {
    case datagram
    case reliable

    static func load(usb: Bool, defaults: UserDefaults = .standard) -> AudioTransportMode {
        let key = usb ? "hearport.usbAudio.transport" : "hearport.audioTransportMode"
        return defaults.string(forKey: key).flatMap(Self.init(rawValue:)) ?? (usb ? .reliable : .datagram)
    }

    public func bufferTargetPackets(selected: Int) -> Int {
        JitterBufferConfiguration(targetPackets: selected).targetPackets
    }
}
