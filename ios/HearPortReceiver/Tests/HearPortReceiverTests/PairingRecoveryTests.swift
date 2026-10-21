import Foundation
import XCTest
@testable import HearPortReceiver

final class PairingRecoveryTests: XCTestCase {
    func testOnlyExplicitRememberedAuthenticationRejectionStopsRetries() {
        XCTAssertTrue(PairingRecovery.stopsRetrying(mode: .remembered, peerError: .authFailed))
        let otherErrors: [ErrorCode?] = [nil, .protocolError, .streamState, .internalError, .pairingClosed, .audioUnavailable]
        for code in otherErrors {
            XCTAssertFalse(PairingRecovery.stopsRetrying(mode: .remembered, peerError: code))
        }
        XCTAssertFalse(PairingRecovery.stopsRetrying(mode: .pair, peerError: .authFailed))
        XCTAssertFalse(PairingRecovery.stopsRetrying(mode: .oneTime, peerError: .authFailed))
    }

    func testRevocationRequiresAnAuthenticatedExplicitNoticeForTheSamePairing() throws {
        let old = try RememberedCredential(peerID: Data(repeating: 1, count: 16),
            pairSecret: Data(repeating: 2, count: 32), windowsSPKISHA256: Data(repeating: 3, count: 32))
        XCTAssertTrue(PairingRecovery.removesCredential(reason: 3, authenticated: true, session: old, stored: old))
        for reason in [UInt32(0), 1, 2, 4] {
            XCTAssertFalse(PairingRecovery.removesCredential(reason: reason, authenticated: true, session: old, stored: old))
        }
        XCTAssertFalse(PairingRecovery.removesCredential(reason: 3, authenticated: false, session: old, stored: old))
        XCTAssertFalse(PairingRecovery.removesCredential(reason: 3, authenticated: true, session: nil, stored: old))
        XCTAssertFalse(PairingRecovery.removesCredential(reason: 3, authenticated: true, session: old, stored: nil))
        let changed = [
            try RememberedCredential(peerID: Data(repeating: 4, count: 16), pairSecret: old.pairSecret, windowsSPKISHA256: old.windowsSPKISHA256),
            try RememberedCredential(peerID: old.peerID, pairSecret: Data(repeating: 4, count: 32), windowsSPKISHA256: old.windowsSPKISHA256),
            try RememberedCredential(peerID: old.peerID, pairSecret: old.pairSecret, windowsSPKISHA256: Data(repeating: 4, count: 32))
        ]
        for newer in changed {
            XCTAssertFalse(PairingRecovery.removesCredential(reason: 3, authenticated: true, session: old, stored: newer))
        }
    }
}
