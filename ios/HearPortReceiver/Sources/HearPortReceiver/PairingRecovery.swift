import Foundation

enum PairingRecovery {
    // Call only for control messages received through the remembered peer's
    // pinned TLS connection. Transport failures have no peer error code.
    static func stopsRetrying(mode: AuthMode, peerError: ErrorCode?) -> Bool {
        mode == .remembered && peerError == .authFailed
    }

    static func removesCredential(reason: UInt32, authenticated: Bool,
                                  session: RememberedCredential?, stored: RememberedCredential?) -> Bool {
        authenticated && reason == 3 && session != nil && session == stored
    }
}
