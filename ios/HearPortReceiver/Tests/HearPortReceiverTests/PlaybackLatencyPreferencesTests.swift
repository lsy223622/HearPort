import Foundation
import XCTest
@testable import HearPortReceiver

final class PlaybackLatencyPreferencesTests: XCTestCase {
    private func withDefaults(_ test: (UserDefaults) -> Void) {
        let name = "PlaybackLatencyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        test(defaults)
    }

    func testFreshRoutesUseOriginalBudget() {
        withDefaults { defaults in
            for usb in [false, true] {
                XCTAssertEqual(PlaybackLatencyPreferences.load(usb: usb, defaults: defaults),
                               PlaybackLatencyPreferences(target: 50, maximum: 100))
            }
        }
    }

    func testSharedRecommendationMigratesOnlyToNetworkAndPersists() {
        withDefaults { defaults in
            defaults.set(210, forKey: "hearport.targetLatencyMs")
            defaults.set(300, forKey: "hearport.maximumLatencyMs")
            XCTAssertEqual(PlaybackLatencyPreferences.load(usb: true, defaults: defaults),
                           PlaybackLatencyPreferences(target: 50, maximum: 100))
            for _ in 0..<2 {
                PlaybackLatencyPreferences.migrate(in: defaults)
                XCTAssertEqual(PlaybackLatencyPreferences.load(usb: false, defaults: defaults),
                               PlaybackLatencyPreferences(target: 210, maximum: 300))
            }
            XCTAssertNil(defaults.object(forKey: "hearport.targetLatencyMs"))
            XCTAssertNil(defaults.object(forKey: "hearport.maximumLatencyMs"))
        }
    }

    func testMigrationPreservesAlreadyConfiguredRoutes() {
        withDefaults { defaults in
            defaults.set(210, forKey: "hearport.targetLatencyMs")
            defaults.set(300, forKey: "hearport.maximumLatencyMs")
            defaults.set(60, forKey: PlaybackLatencyPreferences.networkTargetKey)
            defaults.set(125, forKey: PlaybackLatencyPreferences.networkMaximumKey)
            defaults.set(25, forKey: PlaybackLatencyPreferences.usbTargetKey)
            defaults.set(75, forKey: PlaybackLatencyPreferences.usbMaximumKey)
            for usb in [false, true, false, true] {
                XCTAssertEqual(PlaybackLatencyPreferences.load(usb: usb, defaults: defaults),
                               usb ? PlaybackLatencyPreferences(target: 25, maximum: 75) :
                                     PlaybackLatencyPreferences(target: 60, maximum: 125))
            }
        }
    }
}
