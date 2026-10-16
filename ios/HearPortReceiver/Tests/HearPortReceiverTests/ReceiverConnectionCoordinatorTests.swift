import Foundation
import XCTest
@testable import HearPortReceiver
final class ReceiverConnectionCoordinatorTests: XCTestCase {
    func testDiscoveryGetsAnAttemptAfterRememberedAddressFails() {
        var history = ConnectionAttemptHistory()
        history.started("old-ip", at: Date(timeIntervalSince1970: 1))
        history.failed("old-ip", until: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(history.choose(["old-ip", "bonjour"], at: Date(timeIntervalSince1970: 3)), "bonjour")
    }
    func testStopFromAuthenticatedPCSurvivesPathPromotion() {
        var policy = ConnectionSelectionPolicy(); policy.wantsConnection = true
        XCTAssertTrue(policy.promote(UUID(), path: .network, identity: Data([1])))
        XCTAssertTrue(policy.promote(UUID(), path: .usb, identity: Data([1])))
        XCTAssertTrue(policy.acceptsStop(from: Data([1])))
        XCTAssertFalse(policy.acceptsStop(from: Data([2])))
        XCTAssertFalse(policy.acceptsStop(from: Data()))
    }
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
