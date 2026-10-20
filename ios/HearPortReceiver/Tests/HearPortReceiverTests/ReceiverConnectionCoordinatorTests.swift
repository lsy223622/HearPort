import Foundation
import XCTest
@testable import HearPortReceiver
final class ReceiverConnectionCoordinatorTests: XCTestCase {
    func testOnlyFullMatchingIdentitiesMergeUSBAndLAN() {
        let identity = String(repeating: "ab", count: 32)
        let routes = [
            ComputerDiscoveryRoute(id: "usb:1", identity: identity.uppercased(), title: "USB", path: .usb, networkAddress: nil),
            ComputerDiscoveryRoute(id: "service:one", identity: identity, title: "HearPort-one", path: .network, networkAddress: "192.168.1.10")
        ]
        let groups = groupComputerRoutes(routes)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.identity, identity)
        XCTAssertEqual(groups.first?.title, "HearPort-one")
        XCTAssertEqual(groups.first?.networkAddress, "192.168.1.10")
        XCTAssertEqual(groups.first?.preferredRouteID, "usb:1")
        XCTAssertEqual(groups.first?.hasUSB, true)
    }
    func testUnknownOrDifferentIdentitiesStaySeparate() {
        let prefix = String(repeating: "a", count: 12)
        let groups = groupComputerRoutes([
            ComputerDiscoveryRoute(id: "usb:1", identity: prefix + String(repeating: "b", count: 52), title: "USB", path: .usb, networkAddress: nil),
            ComputerDiscoveryRoute(id: "service:one", identity: prefix + String(repeating: "c", count: 52), title: "HearPort-one", path: .network, networkAddress: nil),
            ComputerDiscoveryRoute(id: "usb:2", identity: nil, title: "USB", path: .usb, networkAddress: nil),
            ComputerDiscoveryRoute(id: "service:two", identity: prefix, title: "HearPort-two", path: .network, networkAddress: nil)
        ])
        XCTAssertEqual(groups.count, 4)
        XCTAssertTrue(groups.allSatisfy { $0.networkAddress == nil })
        XCTAssertNil(groups.last?.identity)
        XCTAssertNil(computerIdentity(String(repeating: "g", count: 64)))
    }
    func testSelectedComputerExcludesAnotherComputersUSBAndUnknownRoutes() {
        let first = String(repeating: "a", count: 64), second = String(repeating: "b", count: 64)
        let selected = ComputerRouteSelection(identity: second, routeID: nil, fallbackRouteID: "remembered-ip")
        XCTAssertTrue(selected.includes(identity: second, routeID: "network:second"))
        XCTAssertTrue(selected.includes(identity: second, routeID: "usb:second"))
        XCTAssertFalse(selected.includes(identity: first, routeID: "usb:first"))
        XCTAssertFalse(selected.includes(identity: nil, routeID: "usb:unknown"))
        XCTAssertTrue(selected.includes(identity: nil, routeID: "remembered-ip"))
        let unidentified = ComputerRouteSelection(identity: nil, routeID: "service:chosen", fallbackRouteID: nil)
        XCTAssertTrue(unidentified.includes(identity: nil, routeID: "service:chosen"))
        XCTAssertFalse(unidentified.includes(identity: nil, routeID: "usb:unknown"))
    }
    func testUSBRemovalKeepsReconnectIntentUntilExplicitStop() {
        var policy = ConnectionSelectionPolicy(); policy.wantsConnection = true
        let usb = UUID()
        XCTAssertTrue(policy.promote(usb, path: .usb, identity: Data([1])))
        XCTAssertTrue(policy.closed(usb))
        XCTAssertTrue(policy.wantsConnection); XCTAssertNil(policy.active)
        XCTAssertTrue(policy.promote(UUID(), path: .network, identity: Data([1])))
        policy.stop(); XCTAssertFalse(policy.wantsConnection)
    }
    func testAutomaticTestCompletionRestoresReconnectAndUSBPromotion() {
        var policy = ConnectionSelectionPolicy(); policy.wantsConnection = true
        let test = UUID(), network = UUID(), usb = UUID()
        XCTAssertTrue(policy.promote(test, path: .network, identity: Data([1])))
        policy.pinned = true
        policy.resumeAfterTest()
        XCTAssertTrue(policy.closed(test))
        XCTAssertTrue(policy.wantsConnection)
        XCTAssertTrue(policy.promote(network, path: .network, identity: Data([1])))
        XCTAssertTrue(policy.promote(usb, path: .usb, identity: Data([1])))
        XCTAssertFalse(policy.closed(test))
        XCTAssertEqual(policy.active, usb)
        policy.stop()
        XCTAssertFalse(policy.wantsConnection)
    }

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

#if canImport(Network) && canImport(Combine)
import Network
extension ReceiverConnectionCoordinatorTests {
    @MainActor func testUSBIsRetriedAfterCooldownWhileNetworkKeepsPlaying() {
        let tunnel = USBPacketTunnel(diagnostics: .shared, makeTCPListener: { _ in
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            return try NWListener(using: parameters)
        })
        let coordinator = ReceiverConnectionCoordinator(tunnel: tunnel)
        let identity = Data(repeating: 0xab, count: 32)
        let identityText = String(repeating: "ab", count: 32)
        coordinator.setRememberedIdentity(identity)
        let network = expectation(description: "Network fallback authenticated")
        let retried = expectation(description: "USB retried after cooldown without another device event")
        var usbAttempts = 0
        coordinator.onRequest = { [weak coordinator] id, endpoint in
            guard let coordinator else { return }
            if endpoint.path == .network {
                XCTAssertTrue(coordinator.authenticated(id, identity: identity, features: 0))
                network.fulfill()
            } else {
                usbAttempts += 1
                if usbAttempts == 1 {
                    coordinator.ended(id)
                    tunnel.onAvailable?(61001)
                    tunnel.onPeerIdentity?(61001, identityText)
                } else { retried.fulfill() }
            }
        }
        coordinator.start()
        tunnel.onAvailable?(61000); tunnel.onPeerIdentity?(61000, identityText)
        DispatchQueue.main.async { coordinator.connect(manualHost: "127.0.0.1") }
        wait(for: [network, retried], timeout: 5)
        coordinator.stop()
        let stopped = expectation(description: "USB listener stopped")
        tunnel.stop { stopped.fulfill() }; wait(for: [stopped], timeout: 3)
        XCTAssertEqual(usbAttempts, 2)
    }
}
#endif
