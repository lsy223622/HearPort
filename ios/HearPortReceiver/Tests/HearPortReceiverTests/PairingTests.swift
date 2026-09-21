import Foundation
import XCTest
@testable import HearPortReceiver

final class PairingTests: XCTestCase {
    private func hex(_ value: String) -> Data {
        var output = Data()
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            output.append(UInt8(value[index..<next], radix: 16)!)
            index = next
        }
        return output
    }

    func testPinScalarAndIdentityVectors() throws {
        XCTAssertTrue(PairingSecurity.validatePIN("000001"))
        XCTAssertFalse(PairingSecurity.validatePIN("12345"))
        XCTAssertFalse(PairingSecurity.validatePIN("12a456"))
        XCTAssertEqual(
            try PairingSecurity.pinScalar("000001"),
            hex("953b4ede8ce205547f1e941484ea9c4171029c3b305327f36ee8837a7ba70884")
        )

        let spkiHash = hex("8173a3931015a47eecca3be51c063ef6c715eb0dd72447a182551ec099986e99")
        XCTAssertEqual(
            try PairingSecurity.identityA(windowsSPKISHA256: spkiHash),
            hex("48656172506f72742d57696e646f77732d7631008173a3931015a47eecca3be51c063ef6c715eb0dd72447a182551ec099986e99")
        )
        XCTAssertEqual(PairingSecurity.identityB(), Data("HearPort-Receiver-v1".utf8))
    }

    func testRememberedAuthVectorAndNonceReplay() throws {
        let spkiHash = hex("8173a3931015a47eecca3be51c063ef6c715eb0dd72447a182551ec099986e99")
        let credential = try RememberedCredential(
            peerID: hex("00112233445566778899aabbccddeeff"),
            pairSecret: hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
            windowsSPKISHA256: spkiHash
        )
        let nonce = hex("ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100")
        let mac = try PairingSecurity.rememberedAuthMAC(
            pairSecret: credential.pairSecret,
            nonce: nonce,
            windowsSPKISHA256: credential.windowsSPKISHA256
        )
        XCTAssertEqual(mac, hex("d5b46316593d5739bf0fc756270a58c5c99039d9ab1c89a22eb57ae4fba105f8"))

        let session = RememberedAuthSession(credential: credential)
        _ = try session.issueChallenge(nonce: nonce)
        XCTAssertTrue(session.verify(peerID: credential.peerID, mac: mac))
        XCTAssertFalse(session.verify(peerID: credential.peerID, mac: mac))
    }

    func testPairingWindowClosesOnFifthFailureAndProviderFailsClosed() throws {
        let window = PairingWindow(duration: 120, maximumFailures: 5)
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(window.open(at: start))
        for offset in 1...4 {
            XCTAssertTrue(window.recordFailure(at: start.addingTimeInterval(TimeInterval(offset))))
        }
        XCTAssertFalse(window.recordFailure(at: start.addingTimeInterval(5)))
        XCTAssertFalse(window.isOpen(at: start.addingTimeInterval(5)))

        let provider = UnavailableSpake2Provider()
        XCTAssertThrowsError(
            try provider.begin(
                role: .receiverPartyB,
                scalar: Data(repeating: 1, count: 32),
                identityA: Data(),
                identityB: Data()
            )
        ) { error in
            XCTAssertEqual(error as? PairingSecurityError, .providerUnavailable)
        }
    }
}
