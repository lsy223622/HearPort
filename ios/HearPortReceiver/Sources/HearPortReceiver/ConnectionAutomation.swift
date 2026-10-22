import Foundation

public enum AutomationRoute: String, CaseIterable, Sendable {
    case automatic, network, usb
    func includes(_ path: ConnectionPath) -> Bool { self == .automatic || rawValue == path.rawValue }
}

struct ConnectionRecoveryIntent {
    private var requested = false
    private var paused = false
    mutating func request() { requested = true; paused = false }
    mutating func pause() { requested = false; paused = true }
    mutating func reject() { pause() }
    func shouldResume(automatic: Bool, remembered: Bool) -> Bool {
        remembered && !paused && (requested || automatic)
    }
}

public enum AutomationCommand: Equatable {
    case connect(AutomationRoute), disconnect, status
    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "hearport", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/" else { return nil }
        let items = parts.queryItems ?? []
        switch parts.host?.lowercased() {
        case "connect":
            guard items.count <= 1, items.allSatisfy({ $0.name == "route" }),
                  let route = AutomationRoute(rawValue: items.first?.value ?? "automatic") else { return nil }
            self = .connect(route)
        case "disconnect": guard items.isEmpty else { return nil }; self = .disconnect
        case "status": guard items.isEmpty else { return nil }; self = .status
        default: return nil
        }
    }
}
