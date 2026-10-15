import Foundation

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
