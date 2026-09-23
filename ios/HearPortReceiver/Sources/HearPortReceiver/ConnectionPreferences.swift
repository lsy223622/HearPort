import Foundation

public enum ConnectionPreferences {
    public static let lastHostKey = "hearport.lastHost"

    public static func defaultAuthMode(hasRememberedCredential: Bool) -> AuthMode {
        hasRememberedCredential ? .remembered : .pair
    }
}
