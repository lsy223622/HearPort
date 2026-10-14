import Foundation

struct MusicTestRound: Equatable, Sendable {
    let index: Int
    let reliable: Bool
    let adaptive: Bool
    let seconds: Int
    let firstSequence: UInt32
    let generation: UInt32

    init(encoded: Data) throws {
        guard encoded.count == 16, encoded[0] == 3, (1...8).contains(encoded[1]),
              encoded[2] == 8, encoded[3] <= 3, encoded[6] == 0, encoded[7] == 0 else {
            throw ControlMessageError.invalidMessage
        }
        index = Int(encoded[1])
        reliable = (encoded[3] & 1) != 0
        adaptive = (encoded[3] & 2) != 0
        seconds = Int(encoded[4]) * 256 + Int(encoded[5])
        firstSequence = encoded[8..<12].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        generation = encoded[12..<16].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let policies: [UInt8] = [0, 2, 3, 1, 1, 3, 2, 0]
        guard (60...300).contains(seconds), generation != 0,
              encoded[3] == policies[index - 1],
              firstSequence == UInt32(index - 1) * UInt32(seconds) * 400 else {
            throw ControlMessageError.invalidMessage
        }
    }
}
