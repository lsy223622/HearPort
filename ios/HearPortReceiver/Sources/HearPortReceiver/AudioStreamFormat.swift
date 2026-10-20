import Foundation

public struct AudioStreamFormat: Codable, Equatable, Sendable {
    public let opus: Bool
    public let bitrate: Int
    public let frameCount: Int
    public let lookaheadFrames: Int

    public static let pcm = try! AudioStreamFormat(opus: false)

    public init(opus: Bool, bitrate: Int = 256_000, frameCount: Int = 240,
                lookaheadFrames: Int = 0) throws {
        guard !opus || ([192_000, 256_000].contains(bitrate) &&
              [120, 240, 480].contains(frameCount) && (0...960).contains(lookaheadFrames)) else {
            throw ControlMessageError.invalidMessage
        }
        self.opus = opus
        self.bitrate = opus ? bitrate : 0
        self.frameCount = opus ? frameCount : 120
        self.lookaheadFrames = opus ? lookaheadFrames : 0
    }

    public var label: String {
        opus ? "Opus · \(bitrate / 1000) kb/s · \(Double(frameCount) / 48) ms" : "PCM · 2.5 ms"
    }

    func fits(_ budget: PlayoutBudget) -> Bool {
        !opus || Double(frameCount + max(120, lookaheadFrames)) / 48 + 2 +
            budget.outputReserveMilliseconds < budget.maximumMilliseconds
    }

    static func load(usb: Bool, defaults: UserDefaults = .standard) -> AudioStreamFormat {
        let prefix = usb ? "hearport.usbAudio" : "hearport.networkAudio"
        let codec = defaults.string(forKey: prefix + ".codec") ?? (usb ? "pcm" : "opus")
        let bitrate = defaults.object(forKey: prefix + ".bitrate") as? Int ?? 256_000
        let frames = defaults.object(forKey: prefix + ".frames") as? Int ?? 240
        let defaultFormat = try! AudioStreamFormat(opus: !usb)
        return (try? AudioStreamFormat(opus: codec == "opus", bitrate: bitrate, frameCount: frames)) ?? defaultFormat
    }
}
