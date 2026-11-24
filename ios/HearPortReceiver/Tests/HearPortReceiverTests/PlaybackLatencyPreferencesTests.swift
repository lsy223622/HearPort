import Foundation
import XCTest
@testable import HearPortReceiver

final class PlaybackLatencyPreferencesTests: XCTestCase {
    private func withDefaults(_ test: (UserDefaults) throws -> Void) rethrows {
        let name = "PlaybackLatencyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try test(defaults)
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

    func testOutOfRangePreferencesAreClampedToPlayoutBudgetBounds() throws {
        try withDefaults { defaults in
            let cases: [(Int, Int, Int, Int)] = [
                (-5, 5, 10, 20),
                (500, 200, 500, 500),
                (3000, 5000, 2000, 2000),
            ]
            for (rawTarget, rawMaximum, expectedTarget, expectedMaximum) in cases {
                defaults.set(rawTarget, forKey: PlaybackLatencyPreferences.networkTargetKey)
                defaults.set(rawMaximum, forKey: PlaybackLatencyPreferences.networkMaximumKey)
                let loaded = PlaybackLatencyPreferences.load(usb: false, defaults: defaults)
                XCTAssertEqual(loaded, PlaybackLatencyPreferences(target: expectedTarget, maximum: expectedMaximum))
                XCTAssertNoThrow(try PlayoutBudget(targetMilliseconds: Double(loaded.target),
                                                   maximumMilliseconds: Double(loaded.maximum),
                                                   outputReserveMilliseconds: 1))
            }
        }
    }
}
