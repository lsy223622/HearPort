import XCTest
@testable import HearPortReceiver

final class AudioTransportModeTests: XCTestCase {
    func testBothModesHonorSelectedBufferTarget() {
        XCTAssertEqual(AudioTransportMode.reliable.bufferTargetPackets(selected: 128), 128)
        XCTAssertEqual(AudioTransportMode.reliable.bufferTargetPackets(selected: 32), 32)
        XCTAssertEqual(AudioTransportMode.datagram.bufferTargetPackets(selected: 128), 128)
        XCTAssertEqual(AudioTransportMode.datagram.bufferTargetPackets(selected: 32), 32)
    }
}
