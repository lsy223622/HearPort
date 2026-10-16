import Foundation
import XCTest
@testable import HearPortReceiver
final class ReceiverConnectionCoordinatorTests: XCTestCase {
    func testAuthenticatedUSBOnlyPreemptsSamePCAndIgnoresOldClose() {
        var policy = ConnectionSelectionPolicy(); policy.wantsConnection = true
        let network = UUID(), usb = UUID()
        XCTAssertTrue(policy.promote(network, path: .network, identity: Data([1])))
        XCTAssertFalse(policy.promote(usb, path: .usb, identity: Data([2])))
        XCTAssertEqual(policy.active, network)
        XCTAssertTrue(policy.promote(usb, path: .usb, identity: Data([1])))
        XCTAssertFalse(policy.closed(network)); XCTAssertEqual(policy.active, usb)
        XCTAssertFalse(policy.promote(UUID(), path: .network, identity: Data([1])))
    }
    func testPinnedFailureAndUserStopSuppressReconnect() {
        var policy = ConnectionSelectionPolicy(); policy.wantsConnection = true
        let id = UUID(); XCTAssertTrue(policy.promote(id, path: .network, identity: Data([1])))
        policy.pinned = true
        XCTAssertFalse(policy.promote(UUID(), path: .usb, identity: Data([1])))
        XCTAssertTrue(policy.closed(id)); XCTAssertFalse(policy.wantsConnection)
        policy.stop(); XCTAssertFalse(policy.promote(UUID(), path: .usb, identity: Data([1])))
    }
}
