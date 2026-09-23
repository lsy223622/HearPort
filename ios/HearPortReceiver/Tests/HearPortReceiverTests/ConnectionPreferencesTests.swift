import Foundation
import XCTest
@testable import HearPortReceiver

final class ConnectionPreferencesTests: XCTestCase {
    func testLastHostPersistsAcrossUserDefaultsInstancesAndAllowsEmptyValue() throws {
        let suiteName = "HearPort.ConnectionPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let reloadedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(defaults.string(forKey: ConnectionPreferences.lastHostKey))

        defaults.set("192.0.2.17", forKey: ConnectionPreferences.lastHostKey)
        XCTAssertEqual(reloadedDefaults.string(forKey: ConnectionPreferences.lastHostKey), "192.0.2.17")

        defaults.set("", forKey: ConnectionPreferences.lastHostKey)
        XCTAssertEqual(reloadedDefaults.string(forKey: ConnectionPreferences.lastHostKey), "")
    }

    func testDefaultAuthModeUsesRememberedCredentialsOnlyWhenAvailable() {
        XCTAssertEqual(ConnectionPreferences.defaultAuthMode(hasRememberedCredential: true), .remembered)
        XCTAssertEqual(ConnectionPreferences.defaultAuthMode(hasRememberedCredential: false), .pair)
    }
}
