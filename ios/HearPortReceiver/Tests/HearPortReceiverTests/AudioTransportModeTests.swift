import XCTest
@testable import HearPortReceiver

final class AudioTransportModeTests: XCTestCase {
    func testStabilityUses160MillisecondTargetWithoutChangingDatagramChoice() {
        XCTAssertEqual(AudioTransportMode.reliable.bufferTargetPackets(selected: 128), 64)
        XCTAssertEqual(AudioTransportMode.datagram.bufferTargetPackets(selected: 128), 128)
        XCTAssertEqual(AudioTransportMode.datagram.bufferTargetPackets(selected: 32), 32)
    }
}
