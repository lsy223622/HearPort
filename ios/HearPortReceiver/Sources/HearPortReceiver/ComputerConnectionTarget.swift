import Foundation

func computerIdentity(_ value: String?) -> String? {
    guard let value, value.utf8.count == 64,
          value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
    return value.lowercased()
}

struct ComputerDiscoveryRoute {
    let id: String
    let identity: String?
    let title: String
    let path: ConnectionPath
    let networkAddress: String?
}

struct ComputerDiscoveryGroup {
    let id: String
    let identity: String?
    let title: String
    let hasUSB: Bool
    let hasNetwork: Bool
    let networkAddress: String?
    let preferredRouteID: String
}

struct ComputerRouteSelection {
    let identity: String?
    let routeID: String?
    let fallbackRouteID: String?

    func includes(identity routeIdentity: String?, routeID candidateID: String) -> Bool {
        if let identity { return routeIdentity == identity || candidateID == fallbackRouteID }
        if let routeID { return candidateID == routeID }
        return true
    }
}

func groupComputerRoutes(_ routes: [ComputerDiscoveryRoute]) -> [ComputerDiscoveryGroup] {
    var order: [String] = []
    var groups: [String: [ComputerDiscoveryRoute]] = [:]
    for route in routes {
        let key = computerIdentity(route.identity).map { "computer:\($0)" } ?? route.id
        if groups[key] == nil { order.append(key) }
        groups[key, default: []].append(route)
    }
    return order.compactMap { key in
        guard let group = groups[key], let preferred = group.first(where: { $0.path == .usb }) ?? group.first else { return nil }
        return ComputerDiscoveryGroup(id: key, identity: computerIdentity(preferred.identity),
            title: group.first(where: { $0.path == .network })?.title ?? preferred.title,
            hasUSB: group.contains { $0.path == .usb },
            hasNetwork: group.contains { $0.path == .network },
            networkAddress: group.first(where: { $0.networkAddress != nil })?.networkAddress,
            preferredRouteID: preferred.id)
    }
}

#if canImport(Network) && canImport(Combine)
public struct ComputerConnectionTarget: Identifiable {
    public let id: String
    public let identity: String?
    public let title: String
    public let hasUSB: Bool
    public let hasNetwork: Bool
    public let networkAddress: String?
    public let preferredEndpoint: ConnectionEndpoint
}
#endif
