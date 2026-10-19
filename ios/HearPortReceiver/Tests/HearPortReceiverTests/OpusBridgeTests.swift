import Foundation
import HearPortOpusBridge
import XCTest

final class OpusBridgeTests: XCTestCase {
    func testLowDelayStereoFrameRoundTripsAndSupportsPLC() throws {
        let frameCount = 960
        let input = (0..<(frameCount * 2)).map { index in
            Float(sin(Double(index / 2) * 2.0 * Double.pi * 440.0 / 48_000.0) * 0.2)
        }
        var packet = [UInt8](repeating: 0, count: 4_000)
        var decoded = [Float](repeating: 0, count: frameCount * 2)
        var error: Int32 = 0

        guard let encoder = hp_opus_encoder_create(128_000, &error) else {
            XCTFail("Opus encoder creation failed with code \(error)")
            return
        }
        defer { hp_opus_encoder_destroy(encoder) }
        guard let decoder = hp_opus_decoder_create(&error) else {
            XCTFail("Opus decoder creation failed with code \(error)")
            return
        }
        defer { hp_opus_decoder_destroy(decoder) }

        XCTAssertGreaterThanOrEqual(hp_opus_lookahead(encoder), 0)
        XCTAssertNotNil(hp_opus_version())

        let encodedBytes = input.withUnsafeBufferPointer { samples in
            packet.withUnsafeMutableBufferPointer { bytes in
                hp_opus_encode(encoder, samples.baseAddress, Int32(frameCount),
                               bytes.baseAddress, Int32(bytes.count))
            }
        }
        XCTAssertGreaterThan(encodedBytes, 0)

        let decodedFrames = packet.withUnsafeBufferPointer { bytes in
            decoded.withUnsafeMutableBufferPointer { samples in
                hp_opus_decode(decoder, bytes.baseAddress, encodedBytes,
                               samples.baseAddress, Int32(frameCount))
            }
        }
        XCTAssertEqual(decodedFrames, Int32(frameCount))
        XCTAssertTrue(decoded.contains { abs($0) > 0.0001 })

        let plcFrames = decoded.withUnsafeMutableBufferPointer { samples in
            hp_opus_decode(decoder, nil, 0, samples.baseAddress, Int32(frameCount))
        }
        XCTAssertEqual(plcFrames, Int32(frameCount))
    }
}
