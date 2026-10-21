import Foundation

struct PlaybackLatencyPreferences: Equatable {
    var target: Int
    var maximum: Int

    static let networkTargetKey = "hearport.networkAudio.targetLatencyMs"
    static let networkMaximumKey = "hearport.networkAudio.maximumLatencyMs"
    static let usbTargetKey = "hearport.usbAudio.targetLatencyMs"
    static let usbMaximumKey = "hearport.usbAudio.maximumLatencyMs"

    static func migrate(in defaults: UserDefaults = .standard) {
        // The previous shared budget belongs to the user's network configuration.
        for (oldKey, newKey) in [("hearport.targetLatencyMs", networkTargetKey),
                                 ("hearport.maximumLatencyMs", networkMaximumKey)] {
            if defaults.object(forKey: newKey) == nil, let value = defaults.object(forKey: oldKey) {
                defaults.set(value, forKey: newKey)
            }
            defaults.removeObject(forKey: oldKey)
        }
    }

    static func load(usb: Bool, defaults: UserDefaults = .standard) -> Self {
        migrate(in: defaults)
        return Self(target: defaults.object(forKey: usb ? usbTargetKey : networkTargetKey) as? Int ?? 50,
                    maximum: defaults.object(forKey: usb ? usbMaximumKey : networkMaximumKey) as? Int ?? 100)
    }
}
