import Foundation

struct CalibrationBudget: Codable, Hashable, Sendable {
    let target: Int
    let maximum: Int
}

struct CalibrationChoice: Codable, Equatable, Sendable {
    var profileMask: Int
    let reliable: Bool
    let budget: CalibrationBudget
    let outputReserve: Int
}

func calibrationBudgets(maximum: Int, outputReserve: Int) -> [CalibrationBudget] {
    guard maximum <= 2000, maximum > outputReserve, outputReserve >= 0 else { return [] }
    let caps = Set([40,60,80,100,120,160,200,300,500,750,1000,1500,2000,maximum]).sorted()
    var result: [CalibrationBudget] = []
    for cap in caps where cap <= maximum && cap >= 5 {
        for numerator in [cap * 2, cap * 3, (cap - 5) * 4] {
            let target = ((numerator + 19) / 20) * 5
            let value = CalibrationBudget(target: target, maximum: cap)
            if target > outputReserve && target + 5 <= cap && result.last != value { result.append(value) }
        }
    }
    return result
}

struct CalibrationMessage: Equatable, Sendable {
    enum Kind: UInt8, Sendable { case setup, round, ack, analyze, selection, progress, request, complete }
    var goal = 0
    var format: AudioStreamFormat = .pcm
    var kind: Kind
    var planID: UInt32
    var phase = 0, index = 0, count = 0, profileMask = 0
    var reliable = false
    var seconds = 30, outputReserve = 0, completed = 0, total = 0
    var budget = CalibrationBudget(target: 0, maximum: 0)
    var firstSequence: UInt32 = 0
    var generation: UInt32 = 0
    var firstSourceFrame: UInt64 = 0
    var choices: [CalibrationChoice] = []

    init(kind: Kind, planID: UInt32) { self.kind = kind; self.planID = planID }

    init(encoded: Data) throws {
        var r = CalibrationReader(bytes: Array(encoded))
        let version = try r.take(1)
        guard [4,5].contains(version), let kind = Kind(rawValue: UInt8(try r.take(1))) else {
            throw ControlMessageError.invalidMessage
        }
        self.init(kind: kind, planID: UInt32(try r.take(4)))
        if version == 5 { goal = Int(try r.take(1)); guard [1,2,4].contains(goal) else { throw ControlMessageError.invalidMessage } }
        guard planID != 0, goal != 0 || kind != .complete else { throw ControlMessageError.invalidMessage }
        switch kind {
        case .setup, .request:
            seconds = Int(try r.take(2)); budget = CalibrationBudget(target: 0, maximum: Int(try r.take(2)))
            guard (goal == 0 ? [30,60,120] : [15,30,60,120]).contains(seconds), (goal == 0 || seconds <= 60), (20...2000).contains(budget.maximum) else {
                throw ControlMessageError.invalidMessage
            }
        case .round:
            phase = Int(try r.take(1)); index = Int(try r.take(1)); count = Int(try r.take(1)); profileMask = Int(try r.take(1))
            let mode = try r.take(1), reserved = try r.take(1)
            reliable = mode != 0
            seconds = Int(try r.take(2))
            budget = CalibrationBudget(target: Int(try r.take(2)), maximum: Int(try r.take(2)))
            outputReserve = Int(try r.take(2)); firstSequence = UInt32(try r.take(4))
            generation = UInt32(try r.take(4)); firstSourceFrame = try r.take(8)
            guard phase <= 1, (1...(goal == 0 ? 10 : 16)).contains(count), (1...count).contains(index), mode <= 1, reserved == 0,
                  generation != 0, (goal == 0 ? [30,60,120] : [15,30,60,120]).contains(seconds), validCalibrationBudget(budget, reserve: outputReserve),
                  firstSourceFrame == UInt64(firstSequence) * 120,
                  UInt64(firstSequence) + UInt64(seconds * 400) <= UInt64(UInt32.max),
                  (goal != 0 ? profileMask == goal : (phase == 0 ? profileMask == 0 : (1...7).contains(profileMask))) else {
                throw ControlMessageError.invalidMessage
            }
        case .ack:
            phase = Int(try r.take(1)); index = Int(try r.take(1))
            guard phase <= 1, (1...(goal == 0 ? 10 : 16)).contains(index) else { throw ControlMessageError.invalidMessage }
        case .complete, .analyze: break
        case .selection:
            let count = Int(try r.take(2))
            guard count <= 3 else { throw ControlMessageError.invalidMessage }
            var seen = 0
            for _ in 0..<count {
                let mask = Int(try r.take(1)), mode = try r.take(1)
                let value = CalibrationBudget(target: Int(try r.take(2)), maximum: Int(try r.take(2)))
                let reserve = Int(try r.take(2))
                guard (1...7).contains(mask), seen & mask == 0, mode <= 1,
                      validCalibrationBudget(value, reserve: reserve) else { throw ControlMessageError.invalidMessage }
                seen |= mask
                choices.append(CalibrationChoice(profileMask: mask, reliable: mode != 0, budget: value, outputReserve: reserve))
            }
        case .progress:
            completed = Int(try r.take(2)); total = Int(try r.take(2))
            guard (1...256).contains(total), completed <= total else { throw ControlMessageError.invalidMessage }
        }
        if goal != 0 && (kind == .round || kind == .selection) {
            let codec = try r.take(1), bitrate = Int(try r.take(4)), frames = Int(try r.take(2))
            guard codec <= 1, codec != 0 || (bitrate == 0 && frames == 120) else { throw ControlMessageError.invalidMessage }
            if kind == .selection { phase = Int(try r.take(1)); guard phase <= 1 else { throw ControlMessageError.invalidMessage } }
            format = try AudioStreamFormat(opus: codec != 0, bitrate: bitrate, frameCount: frames)
            if kind == .selection { guard choices.count <= 1, choices.allSatisfy({ $0.profileMask == goal }) else { throw ControlMessageError.invalidMessage } }
        }
        guard r.at == r.bytes.count else { throw ControlMessageError.invalidMessage }
    }

    func encoded() throws -> Data {
        var b = Data([goal == 0 ? 4 : 5, kind.rawValue])
        func put(_ value: UInt64, _ size: Int) {
            for offset in (0..<size).reversed() { b.append(UInt8(truncatingIfNeeded: value >> (offset * 8))) }
        }
        func integer(_ value: Int, _ size: Int) throws {
            guard value >= 0, UInt64(value) < (UInt64(1) << (size * 8)) else { throw ControlMessageError.invalidMessage }
            put(UInt64(value), size)
        }
        put(UInt64(planID), 4)
        if goal != 0 { try integer(goal,1) }
        switch kind {
        case .setup, .request: try integer(seconds,2); try integer(budget.maximum,2)
        case .round:
            for value in [phase,index,count,profileMask,reliable ? 1 : 0,0] { try integer(value,1) }
            for value in [seconds,budget.target,budget.maximum,outputReserve] { try integer(value,2) }
            put(UInt64(firstSequence),4); put(UInt64(generation),4); put(firstSourceFrame,8)
        case .ack: try integer(phase,1); try integer(index,1)
        case .complete, .analyze: break
        case .selection:
            try integer(choices.count,2)
            for choice in choices {
                try integer(choice.profileMask,1); try integer(choice.reliable ? 1 : 0,1)
                try integer(choice.budget.target,2); try integer(choice.budget.maximum,2); try integer(choice.outputReserve,2)
            }
        case .progress: try integer(completed,2); try integer(total,2)
        }
        if goal != 0 && (kind == .round || kind == .selection) {
            try integer(format.opus ? 1 : 0,1); try integer(format.bitrate,4); try integer(format.frameCount,2)
            if kind == .selection { try integer(phase,1) }
        }
        _ = try CalibrationMessage(encoded: b)
        return b
    }
}

private func validCalibrationBudget(_ value: CalibrationBudget, reserve: Int) -> Bool {
    value.target > reserve && value.maximum <= 2000 && value.target + 5 <= value.maximum
}

private struct CalibrationReader {
    let bytes: [UInt8]
    var at = 0
    mutating func take(_ count: Int) throws -> UInt64 {
        guard at + count <= bytes.count else { throw ControlMessageError.invalidMessage }
        var value: UInt64 = 0
        for _ in 0..<count { value = (value << 8) | UInt64(bytes[at]); at += 1 }
        return value
    }
}
