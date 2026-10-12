import XCTest
@testable import HearPortReceiver

final class StreamingTimeStretchTests: XCTestCase {
    private func tone(_ first: Int, frames: Int) -> [Float] {
        (first..<(first + frames)).flatMap { frame -> [Float] in
            let value = Float(sin(Double(frame) * 2 * .pi * 440 / 48_000))
            return [value, -value]
        }
    }

    func testAccelerationAndSlowdownPreservePitchAndStereo() {
        for correction in [0.05, -0.05] {
            var stretch = StreamingTimeStretch()
            var output: [Float] = []
            for block in 0..<200 {
                output += stretch.process(tone(block * 720, frames: 720), correction: correction)
            }
            let ratio = Double(200 * 720) / Double(output.count / 2)
            XCTAssertEqual(ratio, 1 + correction, accuracy: 0.003)
            var crossings = 0
            for frame in 1..<(output.count / 2) {
                XCTAssertEqual(output[frame * 2], -output[frame * 2 + 1], accuracy: 0.00001)
                if output[(frame - 1) * 2] <= 0 && output[frame * 2] > 0 { crossings += 1 }
            }
            let frequency = Double(crossings) * 48_000 / Double(output.count / 2)
            XCTAssertEqual(frequency, 440, accuracy: 3)
        }
    }

    func testShortBlocksAndResetHaveNoHiddenPendingAudio() {
        var stretch = StreamingTimeStretch()
        let short = tone(0, frames: 120)
        XCTAssertEqual(stretch.process(short, correction: 0.05), short)
        _ = stretch.process(tone(120, frames: 720), correction: 0.05)
        stretch.reset()
        XCTAssertEqual(stretch.process(short, correction: 0), short)
    }

    func testMusicConcealmentDecaysAndRecoveryDoesNotClick() {
        var concealment = MusicConcealment()
        _ = concealment.accept(tone(0, frames: 720))
        let first = concealment.conceal(frames: 120)
        XCTAssertGreaterThan(first.map { abs($0) }.max() ?? 0, 0.1)
        for _ in 0..<20 { _ = concealment.conceal(frames: 120) }
        let tail = concealment.conceal(frames: 120)
        XCTAssertLessThan(tail.map { abs($0) }.max() ?? 1, 0.01)
        let recovered = concealment.accept(tone(4_000, frames: 120))
        XCTAssertLessThan(abs(recovered[0] - tail[tail.count - 2]), 0.05)
        concealment.reset()
        XCTAssertEqual(concealment.conceal(frames: 120), [Float](repeating: 0, count: 240))
    }
}
