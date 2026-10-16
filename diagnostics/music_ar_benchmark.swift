import Foundation
import Accelerate

func predictAR(_ stereo: [Float], frames: Int, order: Int = 256) -> [Float] {
    var output = [Float](repeating: 0, count: frames * 2)
    for channel in 0..<2 {
        var history = stride(from: channel, to: stereo.count, by: 2).map { Double(stereo[$0]) }
        if history.count < order + 1 {
            history.insert(contentsOf: repeatElement(0, count: order + 1 - history.count), at: 0)
        }
        var correlation = [Double](repeating: 0, count: order + 1)
        history.withUnsafeBufferPointer { source in
            for lag in 0...order {
                vDSP_dotprD(source.baseAddress!, 1, source.baseAddress! + lag, 1,
                            &correlation[lag], vDSP_Length(history.count - lag))
            }
        }
        correlation[0] += 0.001
        var coefficients = [Double](repeating: 0, count: order + 1)
        var error = correlation[0]
        for degree in 1...order {
            var residual = correlation[degree]
            if degree > 1 {
                for j in 1..<degree { residual -= coefficients[j] * correlation[degree - j] }
            }
            let reflection = residual / error
            let previous = coefficients
            if degree > 1 {
                for j in 1..<degree { coefficients[j] = previous[j] - reflection * previous[degree - j] }
            }
            coefficients[degree] = reflection
            error *= 1 - reflection * reflection
        }
        var past = Array(history.suffix(order))
        var cursor = 0
        for frame in 0..<frames {
            var value = 0.0
            for j in 1...order { value += coefficients[j] * past[(cursor + order - j) % order] }
            past[cursor] = value
            cursor = (cursor + 1) % order
            output[frame * 2 + channel] = Float(value)
        }
        if (0..<frames).contains(where: { !output[$0 * 2 + channel].isFinite || abs(output[$0 * 2 + channel]) > 1.5 }) {
            for frame in 0..<frames { output[frame * 2 + channel] = 0 }
        }
    }
    return output
}

func predictAvailableFutureAR(_ stereo: [Float], future: [Float], frames: Int) -> [Float] {
    var output = predictAR(stereo, frames: frames)
    guard future.count >= 512 else { return output }
    var reversed: [Float] = []
    for frame in stride(from: future.count / 2 - 1, through: 0, by: -1) {
        reversed.append(contentsOf: future[(frame * 2)..<(frame * 2 + 2)])
    }
    let backward = predictAR(reversed, frames: frames)
    for frame in 0..<frames {
        let weight = frames > 1 ? Float(frame) / Float(frames - 1) : 0
        for channel in 0..<2 {
            output[frame * 2 + channel] = output[frame * 2 + channel] * (1 - weight) +
                backward[(frames - 1 - frame) * 2 + channel] * weight
        }
    }
    return output
}

@main
struct MusicARBenchmark {
    static func main() throws {
        var input: [Float] = []
        var random: UInt64 = 7
        for frame in 0..<4800 {
            random = random &* 6364136223846793005 &+ 1
            let noise = Double(random >> 40) / Double(1 << 24) - 0.5
            let t = Double(frame) / 48_000
            input.append(Float(0.3 * sin(2 * .pi * 220 * t) + 0.1 * sin(2 * .pi * 523.25 * t) + 0.01 * noise))
            input.append(Float(0.2 * cos(2 * .pi * 330 * t) - 0.01 * noise))
        }
        var fixtures: [[String: Any]] = []
        for length in [0, 96, 256, 4800] {
            for frames in [120, 480] {
                let history = Array(input.prefix(length * 2))
                fixtures.append(["input": history, "frames": frames,
                                 "output": predictAR(history, frames: frames)])
            }
        }
        var timings: [[String: Any]] = []
        var bidirectionalFixtures: [[String: Any]] = []
        for length in [0, 96, 256, 960] {
            for frames in [120, 480] {
                let future = Array(input.suffix(length * 2))
                bidirectionalFixtures.append(["input": input, "future": future, "frames": frames,
                    "output": predictAvailableFutureAR(input, future: future, frames: frames)])
            }
        }
        for frames in [120, 480] {
            var elapsed: [Double] = []
            var checksum = 0.0
            for _ in 0..<250 {
                let started = DispatchTime.now().uptimeNanoseconds
                let output = predictAR(input, frames: frames)
                elapsed.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6)
                checksum += output.reduce(0) { $0 + Double($1) }
            }
            let warm = elapsed.dropFirst(10).sorted()
            timings.append(["frames": frames, "firstMilliseconds": elapsed[0],
                            "warmP50Milliseconds": warm[warm.count / 2],
                            "warmP99Milliseconds": warm[Int(Double(warm.count - 1) * 0.99)],
                            "warmMaximumMilliseconds": warm.last!, "checksum": checksum])
        }
        let result: [String: Any] = ["scope": "macOS native AR CPU only, not iPad end-to-end",
                                      "fixtures": fixtures, "bidirectionalFixtures": bidirectionalFixtures,
                                      "timing": timings]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
