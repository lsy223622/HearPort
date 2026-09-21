import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

#if canImport(Security)
import Security
#endif

public enum PairingSecurityError: Error, Equatable {
    case invalidPin
    case invalidLength
    case randomGenerationFailed
    case providerUnavailable
    case providerFailure(Int32)
}

public enum Spake2Role: UInt8 {
    case windowsPartyA = 1
    case receiverPartyB = 2
}

public struct RememberedCredential: Equatable {
    public let peerID: Data
    public let pairSecret: Data
    public let windowsSPKISHA256: Data

    public init(peerID: Data, pairSecret: Data, windowsSPKISHA256: Data) throws {
        guard peerID.count == 16, pairSecret.count == 32, windowsSPKISHA256.count == 32 else {
            throw PairingSecurityError.invalidLength
        }
        self.peerID = peerID
        self.pairSecret = pairSecret
        self.windowsSPKISHA256 = windowsSPKISHA256
    }
}

public struct PairingSecurity {
    public static let spake2PointBytes = 65
    public static let spake2SessionKeyBytes = 16

    private static let pinDomain = Data("HearPort-SPAKE2-v1".utf8)
    private static let authDomain = Data("HearPort-Auth-v1".utf8)
    private static let windowsIdentityPrefix = Data("HearPort-Windows-v1".utf8)
    private static let receiverIdentity = Data("HearPort-Receiver-v1".utf8)
    private static let p256OrderMinusOne: [UInt8] = [
        0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84,
        0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x50
    ]

    public static func validatePIN(_ pin: String) -> Bool {
        let bytes = Array(pin.utf8)
        return bytes.count == 6 && bytes.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    public static func pinScalar(_ pin: String) throws -> Data {
        guard validatePIN(pin) else { throw PairingSecurityError.invalidPin }
        var message = pinDomain
        message.append(0)
        message.append(contentsOf: pin.utf8)
        #if canImport(CryptoKit)
        let digest = Array(SHA256.hash(data: message))
        #else
        throw PairingSecurityError.providerUnavailable
        #endif
        var scalar = digest
        if scalar.lexicographicallyPrecedes(p256OrderMinusOne) == false {
            subtractBigEndian(&scalar, p256OrderMinusOne)
        }
        addOneBigEndian(&scalar)
        return Data(scalar)
    }

    public static func windowsSPKIHash(_ derSubjectPublicKeyInfo: Data) throws -> Data {
        guard !derSubjectPublicKeyInfo.isEmpty else { throw PairingSecurityError.invalidLength }
        #if canImport(CryptoKit)
        return Data(SHA256.hash(data: derSubjectPublicKeyInfo))
        #else
        throw PairingSecurityError.providerUnavailable
        #endif
    }

    public static func identityA(windowsSPKISHA256: Data) throws -> Data {
        guard windowsSPKISHA256.count == 32 else { throw PairingSecurityError.invalidLength }
        var result = windowsIdentityPrefix
        result.append(0)
        result.append(windowsSPKISHA256)
        return result
    }

    public static func identityB() -> Data {
        receiverIdentity
    }

    public static func defaultSpake2Provider() -> any Spake2Provider {
        #if HEARPORT_SPAKE2_PROVIDER
        return RustSpake2Provider()
        #else
        return UnavailableSpake2Provider()
        #endif
    }

    public static func rememberedAuthMAC(
        pairSecret: Data,
        nonce: Data,
        windowsSPKISHA256: Data
    ) throws -> Data {
        guard pairSecret.count == 32, nonce.count == 32, windowsSPKISHA256.count == 32 else {
            throw PairingSecurityError.invalidLength
        }
        #if canImport(CryptoKit)
        var message = authDomain
        message.append(nonce)
        message.append(windowsSPKISHA256)
        let key = SymmetricKey(data: pairSecret)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        #else
        throw PairingSecurityError.providerUnavailable
        #endif
    }

    public static func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for (lhs, rhs) in zip(left, right) {
            difference |= lhs ^ rhs
        }
        return difference == 0
    }

    public static func randomBytes(count: Int) throws -> Data {
        guard count >= 0 else { throw PairingSecurityError.invalidLength }
        if count == 0 { return Data() }
        var result = Data(count: count)
        #if canImport(Security)
        let status = result.withUnsafeMutableBytes { rawBuffer in
            SecRandomCopyBytes(kSecRandomDefault, count, rawBuffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw PairingSecurityError.randomGenerationFailed }
        return result
        #else
        throw PairingSecurityError.providerUnavailable
        #endif
    }

    private static func subtractBigEndian(_ value: inout [UInt8], _ modulus: [UInt8]) {
        var borrow: UInt16 = 0
        for index in stride(from: value.count - 1, through: 0, by: -1) {
            let minuend = UInt16(value[index])
            let subtrahend = UInt16(modulus[index]) + borrow
            value[index] = UInt8(truncatingIfNeeded: minuend &- subtrahend)
            borrow = minuend < subtrahend ? 1 : 0
        }
    }

    private static func addOneBigEndian(_ value: inout [UInt8]) {
        var carry: UInt16 = 1
        for index in stride(from: value.count - 1, through: 0, by: -1) {
            let sum = UInt16(value[index]) + carry
            value[index] = UInt8(truncatingIfNeeded: sum)
            carry = sum >> 8
        }
    }
}

public protocol Spake2Exchange {
    var publicPoint: Data { get }
    func finish(peerPoint: Data) throws -> Spake2Output
}

public protocol Spake2Provider {
    func begin(
        role: Spake2Role,
        scalar: Data,
        identityA: Data,
        identityB: Data
    ) throws -> any Spake2Exchange
}

public struct Spake2Output {
    public let sessionKey: Data
    public let confirmation: Data
    private let verifyPeer: (Data) -> Bool

    public init(sessionKey: Data, confirmation: Data, verifyPeer: @escaping (Data) -> Bool) throws {
        guard sessionKey.count == PairingSecurity.spake2SessionKeyBytes, confirmation.count == 32 else {
            throw PairingSecurityError.invalidLength
        }
        self.sessionKey = sessionKey
        self.confirmation = confirmation
        self.verifyPeer = verifyPeer
    }

    public func verifyPeerConfirmation(_ confirmation: Data) -> Bool {
        verifyPeer(confirmation)
    }
}

public struct UnavailableSpake2Provider: Spake2Provider {
    public init() {}

    public func begin(
        role: Spake2Role,
        scalar: Data,
        identityA: Data,
        identityB: Data
    ) throws -> any Spake2Exchange {
        throw PairingSecurityError.providerUnavailable
    }
}

public final class RememberedAuthSession {
    public let credential: RememberedCredential
    private var pendingNonce: Data?

    public init(credential: RememberedCredential) {
        self.credential = credential
    }

    public func issueChallenge(nonce: Data? = nil) throws -> Data {
        let candidate: Data
        if let nonce {
            candidate = nonce
        } else {
            candidate = try PairingSecurity.randomBytes(count: 32)
        }
        guard candidate.count == 32 else { throw PairingSecurityError.invalidLength }
        pendingNonce = candidate
        return candidate
    }

    public func verify(peerID: Data, mac: Data) -> Bool {
        let nonce = pendingNonce
        pendingNonce = nil
        guard let nonce, PairingSecurity.constantTimeEqual(peerID, credential.peerID) else {
            return false
        }
        guard let expected = try? PairingSecurity.rememberedAuthMAC(
            pairSecret: credential.pairSecret,
            nonce: nonce,
            windowsSPKISHA256: credential.windowsSPKISHA256
        ) else {
            return false
        }
        return PairingSecurity.constantTimeEqual(mac, expected)
    }
}

public final class PairingWindow {
    public let duration: TimeInterval
    public let maximumFailures: Int
    public private(set) var failureCount = 0
    private var openedAt: Date?

    public init(duration: TimeInterval = 120, maximumFailures: Int = 5) {
        self.duration = duration
        self.maximumFailures = maximumFailures
    }

    @discardableResult
    public func open(at now: Date = Date()) -> Bool {
        guard duration > 0, maximumFailures > 0 else { return false }
        openedAt = now
        failureCount = 0
        return true
    }

    public func close() {
        openedAt = nil
    }

    public func isOpen(at now: Date = Date()) -> Bool {
        guard let openedAt, now.timeIntervalSince(openedAt) < duration,
              failureCount < maximumFailures else {
            close()
            return false
        }
        return true
    }

    @discardableResult
    public func recordFailure(at now: Date = Date()) -> Bool {
        guard isOpen(at: now) else { return false }
        failureCount += 1
        if failureCount >= maximumFailures {
            close()
            return false
        }
        return true
    }
}

#if HEARPORT_SPAKE2_PROVIDER
@_silgen_name("hearport_spake2_begin")
private func hearportSpake2Begin(
    _ role: UInt8,
    _ scalar: UnsafePointer<UInt8>,
    _ identityA: UnsafePointer<UInt8>?,
    _ identityALength: Int,
    _ identityB: UnsafePointer<UInt8>?,
    _ identityBLength: Int,
    _ publicPoint: UnsafeMutablePointer<UInt8>,
    _ session: UnsafeMutablePointer<OpaquePointer?>
) -> Int32

@_silgen_name("hearport_spake2_finish")
private func hearportSpake2Finish(
    _ session: OpaquePointer,
    _ peerPoint: UnsafePointer<UInt8>,
    _ peerPointLength: Int,
    _ output: UnsafeMutablePointer<OpaquePointer?>,
    _ confirmation: UnsafeMutablePointer<UInt8>
) -> Int32

@_silgen_name("hearport_spake2_verify_confirmation")
private func hearportSpake2VerifyConfirmation(
    _ output: OpaquePointer,
    _ confirmation: UnsafePointer<UInt8>
) -> Int32

@_silgen_name("hearport_spake2_copy_session_key")
private func hearportSpake2CopySessionKey(
    _ output: OpaquePointer,
    _ sessionKey: UnsafeMutablePointer<UInt8>
) -> Int32

@_silgen_name("hearport_spake2_session_free")
private func hearportSpake2SessionFree(_ session: OpaquePointer)

@_silgen_name("hearport_spake2_output_free")
private func hearportSpake2OutputFree(_ output: OpaquePointer)

public final class RustSpake2Provider: Spake2Provider {
    public init() {}

    public func begin(
        role: Spake2Role,
        scalar: Data,
        identityA: Data,
        identityB: Data
    ) throws -> any Spake2Exchange {
        guard scalar.count == 32 else { throw PairingSecurityError.invalidLength }
        var publicPoint = Data(count: PairingSecurity.spake2PointBytes)
        var session: OpaquePointer?
        let status = scalar.withUnsafeBytes { scalarBuffer in
            identityA.withUnsafeBytes { identityABuffer in
                identityB.withUnsafeBytes { identityBBuffer in
                    publicPoint.withUnsafeMutableBytes { pointBuffer in
                        hearportSpake2Begin(
                            role.rawValue,
                            scalarBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            identityABuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            identityA.count,
                            identityBBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            identityB.count,
                            pointBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            &session
                        )
                    }
                }
            }
        }
        guard status == 0, let session else { throw PairingSecurityError.providerFailure(status) }
        return RustSpake2Exchange(session: session, publicPoint: publicPoint)
    }
}

private final class RustSpake2Exchange: Spake2Exchange {
    private var session: OpaquePointer?
    let publicPoint: Data

    init(session: OpaquePointer, publicPoint: Data) {
        self.session = session
        self.publicPoint = publicPoint
    }

    deinit {
        if let session { hearportSpake2SessionFree(session) }
    }

    func finish(peerPoint: Data) throws -> Spake2Output {
        guard peerPoint.count == PairingSecurity.spake2PointBytes,
              let session else { throw PairingSecurityError.invalidLength }
        self.session = nil
        var output: OpaquePointer?
        var confirmation = Data(count: 32)
        let status = peerPoint.withUnsafeBytes { peerBuffer in
            confirmation.withUnsafeMutableBytes { confirmationBuffer in
                hearportSpake2Finish(
                    session,
                    peerBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    peerPoint.count,
                    &output,
                    confirmationBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                )
            }
        }
        guard status == 0, let output else { throw PairingSecurityError.providerFailure(status) }
        var sessionKey = Data(count: PairingSecurity.spake2SessionKeyBytes)
        let keyStatus = sessionKey.withUnsafeMutableBytes { keyBuffer in
            hearportSpake2CopySessionKey(
                output,
                keyBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
            )
        }
        guard keyStatus == 0 else {
            hearportSpake2OutputFree(output)
            throw PairingSecurityError.providerFailure(keyStatus)
        }
        let rustOutput = try RustSpake2Output(
            output: output,
            sessionKey: sessionKey,
            confirmation: confirmation
        )
        return try Spake2Output(
            sessionKey: rustOutput.sessionKey,
            confirmation: rustOutput.confirmation,
            verifyPeer: { [rustOutput] peerConfirmation in
                rustOutput.verify(peerConfirmation)
            }
        )
    }
}

private final class RustSpake2Output {
    let output: OpaquePointer
    let sessionKey: Data
    let confirmation: Data

    init(output: OpaquePointer, sessionKey: Data, confirmation: Data) throws {
        self.output = output
        self.sessionKey = sessionKey
        self.confirmation = confirmation
    }

    func verify(_ confirmation: Data) -> Bool {
        guard confirmation.count == 32 else { return false }
        return confirmation.withUnsafeBytes { confirmationBuffer in
            hearportSpake2VerifyConfirmation(
                output,
                confirmationBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
            ) == 0
        }
    }

    deinit {
        hearportSpake2OutputFree(output)
    }
}
#endif
