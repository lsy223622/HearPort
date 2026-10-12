import Foundation

public struct StreamingTimeStretch: Sendable {
    private var frameDebt = 0.0
    public private(set) var inputFrames: UInt64 = 0
    public private(set) var outputFrames: UInt64 = 0

    public init() {}
    public mutating func reset() { self = StreamingTimeStretch() }

    public mutating func process(_ stereo: [Float], correction: Double) -> [Float] {
        let frames = stereo.count / 2
        inputFrames += UInt64(frames)
        guard stereo.count.isMultiple(of: 2), correction.isFinite,
              abs(correction) > 0.001 else {
            outputFrames += UInt64(frames)
            return stereo
        }
        let bounded = min(0.1, max(-0.1, correction))
        if frameDebt * bounded < 0 { frameDebt = 0 }
        frameDebt = min(Double(max(720, frames)), max(-Double(max(720, frames)),
            frameDebt + Double(frames) * bounded / (1 + bounded)))
        guard frames >= 720 else { outputFrames += UInt64(frames); return stereo }
        let limit = min(frames / 6, Int(abs(frameDebt)))
        guard limit >= 48 else { outputFrames += UInt64(frames); return stereo }
        let middle = frames / 2
        let window = min(240, middle - limit)
        var selected = 0
        var best = 0.92
        for lag in 48...limit {
            var dot = 0.0, a2 = 0.0, b2 = 0.0
            for frame in 0..<window {
                for channel in 0..<2 {
                    let a = Double(stereo[(middle - lag + frame) * 2 + channel])
                    let b = Double(stereo[(middle + frame) * 2 + channel])
                    dot += a * b; a2 += a * a; b2 += b * b
                }
            }
            let score = a2 + b2 < 0.000001 ? 1 : dot / sqrt(max(1e-20, a2 * b2))
            if score >= best { best = score; selected = lag }
        }
        guard selected > 0 else { outputFrames += UInt64(frames); return stereo }
        let accelerate = bounded > 0
        let prefix = accelerate ? middle - selected : middle
        var output = Array(stereo.prefix(prefix * 2))
        output.reserveCapacity((frames + (accelerate ? -selected : selected)) * 2)
        for frame in 0..<selected {
            let weight = Float(frame + 1) / Float(selected + 1)
            let a = accelerate ? middle - selected + frame : middle + frame
            let b = accelerate ? middle + frame : middle - selected + frame
            for channel in 0..<2 {
                output.append(stereo[a * 2 + channel] * (1 - weight) +
                              stereo[b * 2 + channel] * weight)
            }
        }
        output += stereo[(accelerate ? middle + selected : middle) * 2..<stereo.count]
        frameDebt += accelerate ? -Double(selected) : Double(selected)
        outputFrames += UInt64(output.count / 2)
        return output
    }
}

public struct MusicConcealment: Sendable {
    private var history: [Float] = []
    private var period = 120
    private var missingFrames = 0
    private var last: [Float] = [0, 0]

    public init() {}
    public mutating func reset() { self = MusicConcealment() }

    public mutating func accept(_ stereo: [Float]) -> [Float] {
        var output = stereo
        if missingFrames > 0 {
            let fade = min(120, output.count / 2)
            for frame in 0..<fade {
                let weight = Float(frame + 1) / Float(fade)
                for channel in 0..<2 {
                    output[frame * 2 + channel] = last[channel] * (1 - weight) +
                        output[frame * 2 + channel] * weight
                }
            }
        }
        missingFrames = 0
        history += stereo
        if history.count > 1_920 { history.removeFirst(history.count - 1_920) }
        if output.count >= 2 { last = Array(output.suffix(2)) }
        return output
    }

    public mutating func conceal(frames: Int) -> [Float] {
        guard frames > 0 else { return [] }
        let available = history.count / 2
        guard available >= 96 else { return [Float](repeating: 0, count: frames * 2) }
        if missingFrames == 0 {
            var best = -Double.infinity
            for lag in 48...min(480, available / 2) {
                var error = 0.0
                for frame in 0..<min(120, available - lag) {
                    for channel in 0..<2 {
                        let a = Double(history[(available - 1 - frame) * 2 + channel])
                        let b = Double(history[(available - 1 - frame - lag) * 2 + channel])
                        error -= (a - b) * (a - b)
                    }
                }
                if error > best { best = error; period = lag }
            }
        }
        var output = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let position = available - period + (missingFrames + frame) % period
            let gain = Float(exp(-Double(missingFrames + frame) / 480))
            for channel in 0..<2 { output[frame * 2 + channel] = history[position * 2 + channel] * gain }
        }
        missingFrames += frames
        last = Array(output.suffix(2))
        return output
    }
}
