import Foundation
import XCTest
@testable import HearPortReceiver

final class ConnectionAutomationTests: XCTestCase {
    func testManualPauseAndRejectionSurviveRecoveryEvents() {
        var intent = ConnectionRecoveryIntent()
        XCTAssertTrue(intent.shouldResume(automatic: true, remembered: true))
        intent.pause()
        XCTAssertFalse(intent.shouldResume(automatic: true, remembered: true))
        intent.request()
        XCTAssertTrue(intent.shouldResume(automatic: false, remembered: true))
        intent.reject()
        XCTAssertFalse(intent.shouldResume(automatic: true, remembered: true))
        intent.request()
        XCTAssertFalse(intent.shouldResume(automatic: true, remembered: false))
    }

    func testRouteRestrictionNeverFallsBackToOtherRoute() {
        XCTAssertTrue(AutomationRoute.automatic.includes(.usb))
        XCTAssertTrue(AutomationRoute.automatic.includes(.network))
        XCTAssertFalse(AutomationRoute.usb.includes(.network))
        XCTAssertFalse(AutomationRoute.network.includes(.usb))
    }

    func testURLAllowsOnlyKnownCommandsAndRoutes() {
        XCTAssertEqual(AutomationCommand(url: URL(string: "hearport://connect?route=usb")!), .connect(.usb))
        XCTAssertEqual(AutomationCommand(url: URL(string: "hearport://connect")!), .connect(.automatic))
        XCTAssertEqual(AutomationCommand(url: URL(string: "hearport://status")!), .status)
        XCTAssertEqual(AutomationCommand(url: URL(string: "hearport://disconnect")!), .disconnect)
        for url in ["https://connect", "hearport://connect?host=evil", "hearport://connect?route=bad",
                    "hearport://connect?route=usb&route=network", "hearport://disconnect?route=usb",
                    "hearport://user@connect", "hearport://connect/path", "hearport://connect#fragment"] {
            XCTAssertNil(AutomationCommand(url: URL(string: url)!), url)
        }
    }
}
