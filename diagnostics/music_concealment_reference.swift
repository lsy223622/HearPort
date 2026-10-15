import Foundation

@main
struct MusicConcealmentReference {
    static func main() throws {
        var model = MusicConcealment()
        var records: [[String: Any]] = []
        var position = 0
        for burst in [1, 4, 80, 2] {
            for _ in 0..<30 {
                var input: [Float] = []
                for frame in position..<(position + 120) {
                    let t = Double(frame) / 48_000
                    input.append(Float(0.3 * sin(2 * .pi * 220 * t) + 0.1 * sin(2 * .pi * 523.25 * t)))
                    input.append(Float(0.2 * cos(2 * .pi * 330 * t)))
                }
                position += 120
                records.append(["action": "accept", "input": input, "output": model.accept(input)])
            }
            for _ in 0..<burst {
                records.append(["action": "conceal", "frames": 120, "output": model.conceal(frames: 120)])
                position += 120
            }
        }
        let data = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
