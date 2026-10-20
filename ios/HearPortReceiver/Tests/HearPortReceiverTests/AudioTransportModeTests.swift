import XCTest
@testable import HearPortReceiver

final class AudioTransportModeTests: XCTestCase {
    func testRoutePreferencesAreIndependentAndUSBReliableByDefault() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AudioTransportMode.load(usb: true, defaults: defaults), .reliable)
        XCTAssertEqual(AudioTransportMode.load(usb: false, defaults: defaults), .datagram)
        defaults.set("reliable", forKey: "hearport.audioTransportMode")
        defaults.set("datagram", forKey: "hearport.usbAudio.transport")
        XCTAssertEqual(AudioTransportMode.load(usb: false, defaults: defaults), .reliable)
        XCTAssertEqual(AudioTransportMode.load(usb: true, defaults: defaults), .datagram)
    }

    func testBothModesHonorSelectedBufferTarget() {
        XCTAssertEqual(AudioTransportMode.reliable.bufferTargetPackets(selected: 128), 128)
        XCTAssertEqual(AudioTransportMode.reliable.bufferTargetPackets(selected: 32), 32)
        XCTAssertEqual(AudioTransportMode.datagram.bufferTargetPackets(selected: 128), 128)
        XCTAssertEqual(AudioTransportMode.datagram.bufferTargetPackets(selected: 32), 32)
    }
}
