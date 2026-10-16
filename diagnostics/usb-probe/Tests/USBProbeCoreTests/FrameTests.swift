import Foundation
import XCTest
@testable import USBProbeCore
final class FrameTests: XCTestCase {
    func testSharedFixtureSurvivesEveryByteBoundary() throws {
        let frame = try ProbeFrame(kind: .data, sequence: 7, timestamp: 123, payload: Data("123456789".utf8)).encoded()
        XCTAssertEqual(frame.map { String(format: "%02x", $0) }.joined(), "48505531010100000000000700000009000000000000007bcbf4392600000000313233343536373839")
        var decoder = ProbeFrameDecoder()
        var decoded: [ProbeFrame] = []
        for byte in frame { decoded += try decoder.append(Data([byte])) }
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.payload, Data("123456789".utf8))
    }
    func testConcatenationAndInvalidFrame() throws {
        let ping = try ProbeFrame(kind: .ping, sequence: 8, timestamp: 456).encoded()
        var decoder = ProbeFrameDecoder()
        XCTAssertEqual(try decoder.append(ping + ping).count, 2)
        var corrupt = try ProbeFrame(kind: .data, sequence: 0, timestamp: 0, payload: Data([1])).encoded()
        corrupt[corrupt.count - 1] ^= 1
        XCTAssertThrowsError(try decoder.append(corrupt))
        var oversized = ping
        oversized.replaceSubrange(12..<16, with: [0,1,0,1])
        var fresh = ProbeFrameDecoder()
        XCTAssertThrowsError(try fresh.append(oversized))
    }
}
