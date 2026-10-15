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

struct MusicPredictionMeasurement: Codable, Sendable {
    let phase: String
    let queueMilliseconds, computeMilliseconds, totalMilliseconds: Double
    let checksum: Double
}

struct MusicPredictionBenchmarkCase: Codable, Sendable {
    let frames: Int
    let usesFuture: Bool
    let measurements: [MusicPredictionMeasurement]
}

struct MusicPredictionBenchmarkReport: Codable, Sendable {
    let setupMilliseconds: Double
    let operatingSystem: String
    let processorCount, thermalStateAtStart, thermalStateAtEnd: Int
    let cases: [MusicPredictionBenchmarkCase]
}

enum MusicPredictionBenchmark {
    static func run() async throws -> MusicPredictionBenchmarkReport {
        let setupStart = DispatchTime.now().uptimeNanoseconds
        let thermalStart = ProcessInfo.processInfo.thermalState.rawValue
        var input: [Float] = []
        var random: UInt64 = 7
        for frame in 0..<5760 {
            random = random &* 6364136223846793005 &+ 1
            let noise = Double(random >> 40) / Double(1 << 24) - 0.5
            let t = Double(frame) / 48_000
            input.append(Float(0.3 * sin(2 * .pi * 220 * t) + 0.1 * sin(2 * .pi * 523.25 * t) + 0.01 * noise))
            input.append(Float(0.2 * cos(2 * .pi * 330 * t) - 0.01 * noise))
        }
        let history = Array(input.prefix(9600))
        let future = Array(input.suffix(1920))
        let queue = DispatchQueue(label: "HearPort.MusicPredictionBenchmark", qos: .userInitiated)
        let setup = Double(DispatchTime.now().uptimeNanoseconds - setupStart) / 1e6
        var cases: [MusicPredictionBenchmarkCase] = []
        for usesFuture in [false, true] {
            for frames in [120, 480] {
                var measurements: [MusicPredictionMeasurement] = []
                var committed = history
                for iteration in 0..<281 {
                    try Task.checkCancellation()
                    let phase = iteration == 0 ? "first" : (iteration <= 200 ? "warm" : "consecutive")
                    let context = iteration <= 200 ? history : committed
                    let result = await measure(queue: queue, history: context, future: future,
                                               frames: frames, usesFuture: usesFuture, phase: phase)
                    measurements.append(result.0)
                    if iteration > 200 {
                        committed = Array((committed + result.1).suffix(9600))
                    }
                }
                for (idle, count) in [(100, 5), (1000, 3)] {
                    for _ in 0..<count {
                        try await Task.sleep(nanoseconds: UInt64(idle) * 1_000_000)
                        let result = await measure(queue: queue, history: history, future: future,
                                                   frames: frames, usesFuture: usesFuture, phase: "idle\(idle)")
                        measurements.append(result.0)
                    }
                }
                cases.append(MusicPredictionBenchmarkCase(frames: frames, usesFuture: usesFuture,
                                                          measurements: measurements))
            }
        }
        return MusicPredictionBenchmarkReport(setupMilliseconds: setup,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            processorCount: ProcessInfo.processInfo.processorCount,
            thermalStateAtStart: thermalStart, thermalStateAtEnd: ProcessInfo.processInfo.thermalState.rawValue,
            cases: cases)
    }

    private static func measure(queue: DispatchQueue, history: [Float], future: [Float],
                                frames: Int, usesFuture: Bool, phase: String) async -> (MusicPredictionMeasurement, [Float]) {
        let submitted = DispatchTime.now().uptimeNanoseconds
        let result: (MusicPredictionMeasurement, [Float]) = await withCheckedContinuation { continuation in
            queue.async {
                let started = DispatchTime.now().uptimeNanoseconds
                let output = usesFuture ? predictAvailableFutureAR(history, future: future, frames: frames) :
                    predictAR(history, frames: frames)
                let finished = DispatchTime.now().uptimeNanoseconds
                let timing = MusicPredictionMeasurement(phase: phase,
                    queueMilliseconds: Double(started - submitted) / 1e6,
                    computeMilliseconds: Double(finished - started) / 1e6,
                    totalMilliseconds: Double(finished - submitted) / 1e6,
                    checksum: output.reduce(0) { $0 + Double($1) })
                continuation.resume(returning: (timing, output))
            }
        }
        return (MusicPredictionMeasurement(phase: phase,
            queueMilliseconds: result.0.queueMilliseconds, computeMilliseconds: result.0.computeMilliseconds,
            totalMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - submitted) / 1e6,
            checksum: result.0.checksum), result.1)
    }
}

