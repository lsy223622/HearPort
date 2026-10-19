import Foundation

enum MusicTestCodec: String, Sendable {
    case floatPCM = "float_pcm"
    case pcm16 = "pcm16"
    case opus = "opus"
}

struct MusicTestRound: Equatable, Sendable {
    let version: Int
    let index: Int
    let reliable: Bool
    let adaptive: Bool
    let seconds: Int
    let firstSequence: UInt32
    let generation: UInt32
    let profile: Int
    let repeatIndex: Int
    let frameCount: Int
    let bitrateKbps: Int
    let codecLookaheadFrames: Int

    var roundCount: Int { version == 4 ? 32 : 8 }
    var isCompressionTest: Bool { version == 4 }
    var codec: MusicTestCodec { profile == 0 ? .floatPCM : (profile == 1 ? .pcm16 : .opus) }
    var codecLabel: String {
        switch profile {
        case 0: return "Float PCM"
        case 1: return "PCM16"
        default: return "Opus \(bitrateKbps)"
        }
    }

    init(encoded: Data) throws {
        if encoded.count == 16, encoded[0] == 3 {
            self = try MusicTestRound(legacy: encoded)
            return
        }
        guard encoded.count == 24, encoded[0] == 4, (1...32).contains(encoded[1]),
              encoded[2] == 32, encoded[3] == 2 || encoded[3] == 3,
              (0...7).contains(Int(encoded[6])), (1...2).contains(Int(encoded[7])),
              encoded[22] == 0, encoded[23] == 0 else {
            throw ControlMessageError.invalidMessage
        }

        let index = Int(encoded[1])
        let seconds = Int(encoded[4]) * 256 + Int(encoded[5])
        let profile = Int(encoded[6])
        let frameCount = Int(Self.readUInt16(encoded, 16))
        let bitrate = Int(Self.readUInt16(encoded, 18))
        let lookahead = Int(Self.readUInt16(encoded, 20))
        let framesByProfile = [120, 120, 120, 240, 480, 120, 240, 480]
        let bitrateByProfile = [0, 0, 192, 192, 192, 256, 256, 256]
        let firstSequence = Self.readUInt32(encoded, 8)
        let generation = Self.readUInt32(encoded, 12)
        let expectedSequence = UInt64(index - 1) * UInt64(seconds) * 400

        guard (60...300).contains(seconds), generation != 0,
              frameCount == framesByProfile[profile], bitrate == bitrateByProfile[profile],
              (profile < 2 ? lookahead == 0 : lookahead <= 960),
              expectedSequence <= UInt64(UInt32.max),
              firstSequence == UInt32(expectedSequence) else {
            throw ControlMessageError.invalidMessage
        }

        version = 4
        self.index = index
        reliable = (encoded[3] & 1) != 0
        adaptive = true
        self.seconds = seconds
        self.firstSequence = firstSequence
        self.generation = generation
        self.profile = profile
        repeatIndex = Int(encoded[7])
        self.frameCount = frameCount
        bitrateKbps = bitrate
        codecLookaheadFrames = lookahead
    }

    private init(legacy encoded: Data) throws {
        guard (1...8).contains(encoded[1]), encoded[2] == 8, encoded[3] <= 3,
              encoded[6] == 0, encoded[7] == 0 else {
            throw ControlMessageError.invalidMessage
        }
        let index = Int(encoded[1])
        let seconds = Int(encoded[4]) * 256 + Int(encoded[5])
        let firstSequence = Self.readUInt32(encoded, 8)
        let generation = Self.readUInt32(encoded, 12)
        let policies: [UInt8] = [0, 2, 3, 1, 1, 3, 2, 0]
        guard (60...300).contains(seconds), generation != 0,
              encoded[3] == policies[index - 1],
              firstSequence == UInt32(index - 1) * UInt32(seconds) * 400 else {
            throw ControlMessageError.invalidMessage
        }
        version = 3
        self.index = index
        reliable = (encoded[3] & 1) != 0
        adaptive = (encoded[3] & 2) != 0
        self.seconds = seconds
        self.firstSequence = firstSequence
        self.generation = generation
        profile = 0
        repeatIndex = 1
        frameCount = 120
        bitrateKbps = 0
        codecLookaheadFrames = 0
    }

    private static func readUInt16(_ bytes: Data, _ offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func readUInt32(_ bytes: Data, _ offset: Int) -> UInt32 {
        bytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
