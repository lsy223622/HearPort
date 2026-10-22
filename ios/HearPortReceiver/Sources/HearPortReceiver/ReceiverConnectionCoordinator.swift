import Foundation

public enum ConnectionPath: String, Sendable { case network, usb }
struct ConnectionSelectionPolicy {
    var wantsConnection = false
    var active: UUID?
    var path: ConnectionPath?
    var identity: Data?
    var pinned = false
    mutating func promote(_ id: UUID, path: ConnectionPath, identity: Data) -> Bool {
        guard wantsConnection else { return false }
        if active == id { return true }
        guard active == nil || (!pinned && self.path == .network && path == .usb && self.identity == identity) else { return false }
        active = id; self.path = path; self.identity = identity; return true
    }
    mutating func closed(_ id: UUID) -> Bool {
        guard active == id else { return false }
        active = nil; path = nil; identity = nil
        if pinned { wantsConnection = false }
        return true
    }
    mutating func resumeAfterTest() { pinned = false; wantsConnection = true }
    mutating func stop() { wantsConnection = false; active = nil; path = nil; identity = nil; pinned = false }
    func acceptsStop(from peer: Data) -> Bool { wantsConnection && !peer.isEmpty && identity == peer }
}

struct ConnectionAttemptHistory {
    private var attempted: [String: Date] = [:]
    private var blocked: [String: Date] = [:]
    mutating func started(_ id: String, at: Date) { attempted[id] = at }
    mutating func failed(_ id: String, until: Date) { blocked[id] = until }
    func usable(_ id: String, at: Date) -> Bool { blocked[id, default: .distantPast] <= at }
    func choose(_ ids: [String], at: Date) -> String? {
        ids.filter { usable($0, at: at) }.min { attempted[$0, default: .distantPast] < attempted[$1, default: .distantPast] }
    }
}

#if canImport(Network) && canImport(Combine)
import Network
import Combine

public struct ConnectionEndpoint: Identifiable {
    public let id: String
    public let path: ConnectionPath
    public let host: String
    public let port: UInt16
    public let endpoint: NWEndpoint
    public let identity: String?
    public let networkAddress: String?
    public init(host: String, port: UInt16 = 52137) {
        self.id = "network:\(host):\(port)"; self.path = .network; self.host = host; self.port = port
        endpoint = .hostPort(host: .init(host), port: .init(rawValue: port)!)
        identity = nil; networkAddress = host
    }
    init(usbPort: UInt16, identity: String? = nil) {
        id = "usb:\(usbPort)"; path = .usb; host = "USB"; port = usbPort
        endpoint = .hostPort(host: "127.0.0.1", port: .init(rawValue: usbPort)!)
        self.identity = computerIdentity(identity); networkAddress = nil
    }
    init(service: NWEndpoint, identity: String? = nil, networkAddress: String? = nil) {
        endpoint = service; path = .network; port = 52137
        self.identity = computerIdentity(identity); self.networkAddress = networkAddress
        if case let .service(name, type, domain, _) = service { host = name; id = "service:\(name):\(type):\(domain)" }
        else { host = service.debugDescription; id = "service:\(host)" }
    }
}

@MainActor public final class ReceiverConnectionCoordinator: ObservableObject {
    @Published public private(set) var endpoints: [ConnectionEndpoint] = []
    @Published public private(set) var computers: [ComputerConnectionTarget] = []
    @Published public private(set) var usbStatus = "Waiting for USB iPad"
    public var onRequest: ((UUID, ConnectionEndpoint) -> Void)?
    public var onCancel: ((UUID) -> Void)?
    public var onSearching: (() -> Void)?
    private var browser: NWBrowser?
    private let tunnel: USBPacketTunnel
    private var usbEndpoint: ConnectionEndpoint?
    private var networks: [ConnectionEndpoint] = []
    private var fallback: ConnectionEndpoint?
    private var rememberedName: String?
    private var rememberedIdentity: String?
    private var selectedIdentity: String?
    private var selectedRouteID: String?
    private var resolvers: [String: NWConnection] = [:]
    var rememberedComputerName: String? { rememberedName }
    private var policy = ConnectionSelectionPolicy()
    private var pending: [UUID: ConnectionEndpoint] = [:]
    private var activeEndpoint: ConnectionEndpoint?
    private var retry: DispatchWorkItem?
    private var retrySeconds: Double = 1
    private var history = ConnectionAttemptHistory()
    private var networkTestOnly = false
    private var routeRestriction = AutomationRoute.automatic
    private let pathMonitor = NWPathMonitor()
    private var lastNetworkStatus: NWPath.Status?
    public var onNetworkAvailable: (() -> Void)?
    public var hasUSB: Bool { usbEndpoint != nil }
    public var isWaiting: Bool { policy.wantsConnection && policy.active == nil }

    public init(diagnostics: HearPortDiagnostics = .shared) { tunnel = USBPacketTunnel(diagnostics: diagnostics) }
    init(tunnel: USBPacketTunnel) { self.tunnel = tunnel }
    public func start() {
        guard browser == nil else { return }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                let restored = path.status == .satisfied && self.lastNetworkStatus != .satisfied
                self.lastNetworkStatus = path.status
                if restored {
                    self.history = ConnectionAttemptHistory(); self.retrySeconds = 1
                    self.onNetworkAvailable?(); self.attempt()
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.hearport.path"))
        tunnel.onAvailable = { [weak self] port in DispatchQueue.main.async {
            guard let self else { return }
            self.usbEndpoint = ConnectionEndpoint(usbPort: port); self.usbStatus = "USB available"
            self.publish(); self.attempt()
        } }
        tunnel.onUnavailable = { [weak self] reason in DispatchQueue.main.async {
            guard let self else { return }
            let old = self.usbEndpoint; self.usbEndpoint = nil; self.usbStatus = reason
            self.publish()
            for (id, endpoint) in self.pending where endpoint.path == .usb { self.ended(id) }
            if self.activeEndpoint?.id == old?.id, let active = self.policy.active { self.onCancel?(active); self.ended(active) }
        } }
        tunnel.onPeerIdentity = { [weak self] port, identity in DispatchQueue.main.async {
            guard let self, self.usbEndpoint?.port == port else { return }
            self.usbEndpoint = ConnectionEndpoint(usbPort: port, identity: identity)
            self.publish(); self.attempt()
        } }
        tunnel.start()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_hearport._udp", domain: "local."), using: .udp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.map { result -> ConnectionEndpoint in
                var identity: String?
                if case let .bonjour(record) = result.metadata { identity = record.dictionary["id"] }
                return ConnectionEndpoint(service: result.endpoint, identity: identity)
            }.sorted { $0.id < $1.id }
            DispatchQueue.main.async {
                guard let self else { return }
                self.resolvers.values.forEach { $0.cancel() }; self.resolvers.removeAll()
                var seen = Set<String>()
                self.networks = found.filter { seen.insert($0.id).inserted }.prefix(8).map { $0 }
                self.publish(); self.attempt()
                self.resolveNetworkAddresses()
            }
        }
        browser.start(queue: DispatchQueue(label: "com.hearport.discovery"))
    }
    public func resumeUSBDiscovery() {
        guard browser != nil else { start(); return }
        tunnel.start()
        attempt()
    }
    public func recordUSBStatus(completion: @escaping () -> Void) { tunnel.recordStatus(completion: completion) }
    public func setRememberedIdentity(_ hash: Data?) {
        rememberedIdentity = hash.flatMap { $0.count == 32 ? $0.map { String(format: "%02x", $0) }.joined() : nil }
        rememberedName = hash.map { "HearPort-" + $0.prefix(6).map { String(format: "%02x", $0) }.joined() }
    }
    public func connect(manualHost: String, selected: ConnectionEndpoint? = nil, useRememberedIdentity: Bool = true,
                        route: AutomationRoute = .automatic) {
        stop()
        fallback = selected?.path == .network ? selected : (selected == nil && !manualHost.isEmpty ? ConnectionEndpoint(host: manualHost) : nil)
        selectedIdentity = selected?.identity ?? (useRememberedIdentity ? rememberedIdentity : nil)
        selectedRouteID = selected?.id ?? (selectedIdentity == nil ? fallback?.id : nil)
        routeRestriction = route
        policy.wantsConnection = true; history = ConnectionAttemptHistory(); networkTestOnly = false; retrySeconds = 1
        attempt()
    }
    public func authenticated(_ id: UUID, identity: Data, features: UInt32) -> Bool {
        guard let endpoint = pending[id], policy.wantsConnection else { return false }
        let authenticatedIdentity = identity.map { String(format: "%02x", $0) }.joined()
        if let expected = selectedIdentity, expected != authenticatedIdentity {
            ended(id); return false
        }
        let networkTest = (features & (ControlFeature.networkProbe | ControlFeature.environmentCalibration)) != 0
        if endpoint.path == .usb && networkTest {
            selectedIdentity = computerIdentity(authenticatedIdentity); selectedRouteID = nil
            networkTestOnly = true; pending.removeValue(forKey: id); onCancel?(id); recycleUSB(); attempt(); return false
        }
        let previous = policy.active
        guard policy.promote(id, path: endpoint.path, identity: identity) else {
            pending.removeValue(forKey: id); onCancel?(id); return false
        }
        pending.removeValue(forKey: id); activeEndpoint = endpoint; retrySeconds = 1
        selectedIdentity = computerIdentity(authenticatedIdentity); selectedRouteID = nil
        policy.pinned = networkTest || (features & (ControlFeature.musicTest | ControlFeature.timedDiagnostics)) != 0
        if let previous, previous != id { onCancel?(previous) }
        DispatchQueue.main.async { [weak self] in self?.attempt() }
        return true
    }
    public func pinActive() { policy.pinned = true }
    public func acceptsStop(from identity: Data) -> Bool { policy.acceptsStop(from: identity) }
    public func resumeAfterTest() {
        policy.resumeAfterTest()
        networkTestOnly = false
    }
    public func isRemembered(_ identity: String?) -> Bool {
        guard let identity = computerIdentity(identity) else { return false }
        return identity == rememberedIdentity
    }
    public func completed() { policy.wantsConnection = false; retry?.cancel(); retry = nil; cancelPending() }
    public func stop() {
        let old = policy.active
        let wasUSB = activeEndpoint?.path == .usb
        policy.stop(); activeEndpoint = nil
        retry?.cancel(); retry = nil; cancelPending()
        if let old { onCancel?(old) }
        if wasUSB { recycleUSB() }
    }
    public func ended(_ id: UUID) {
        if let candidate = pending.removeValue(forKey: id) {
            history.failed(candidate.path == .usb ? "usb" : candidate.id, until: Date().addingTimeInterval(retrySeconds)); onCancel?(id)
            if candidate.path == .usb { recycleUSB() }
        } else if policy.closed(id) {
            let wasUSB = activeEndpoint?.path == .usb; activeEndpoint = nil
            if wasUSB { recycleUSB() }
        }
        else { return }
        if isWaiting { onSearching?() }
        scheduleRetry()
    }
    public func setMaximumLatency(_ ms: Int) { tunnel.setMaximumLatency(milliseconds: ms) }
    private func cancelPending() {
        let hadUSB = pending.values.contains { $0.path == .usb }
        let ids = Array(pending.keys); pending.removeAll()
        for id in ids { onCancel?(id) }
        if hadUSB { recycleUSB() }
    }
    private func recycleUSB() { usbEndpoint = nil; publish(); tunnel.resetConnection() }
    private func publish() {
        endpoints = (usbEndpoint.map { [$0] } ?? []) + networks
        let groups = groupComputerRoutes(endpoints.map {
            ComputerDiscoveryRoute(id: $0.id, identity: $0.identity,
                title: $0.identity.map { "HearPort-" + $0.prefix(12) } ?? $0.host,
                path: $0.path, networkAddress: $0.networkAddress)
        })
        computers = groups.compactMap { group in
            guard let preferred = endpoints.first(where: { $0.id == group.preferredRouteID }) else { return nil }
            return ComputerConnectionTarget(id: group.id, identity: group.identity, title: group.title,
                hasUSB: group.hasUSB, hasNetwork: group.hasNetwork,
                networkAddress: group.networkAddress, preferredEndpoint: preferred)
        }
    }
    private func resolveNetworkAddresses() {
        for endpoint in networks where endpoint.networkAddress == nil {
            let connection = NWConnection(to: endpoint.endpoint, using: .udp)
            resolvers[endpoint.id] = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                DispatchQueue.main.async {
                    guard let self, let connection, self.resolvers[endpoint.id] === connection else { return }
                    switch state {
                    case .ready:
                        if let remote = connection.currentPath?.remoteEndpoint, case let .hostPort(host, _) = remote {
                            let address: String?
                            switch host {
                            case let .ipv4(value): address = value.debugDescription
                            case let .ipv6(value): address = value.debugDescription
                            default: address = nil
                            }
                            if let address, let index = self.networks.firstIndex(where: { $0.id == endpoint.id }) {
                                self.networks[index] = ConnectionEndpoint(service: endpoint.endpoint, identity: endpoint.identity, networkAddress: address)
                                self.publish()
                            }
                        }
                        self.resolvers.removeValue(forKey: endpoint.id); connection.cancel()
                    case .failed, .cancelled:
                        self.resolvers.removeValue(forKey: endpoint.id); connection.cancel()
                    default: break
                    }
                }
            }
            connection.start(queue: DispatchQueue.main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak connection] in
                guard let self, let connection, self.resolvers[endpoint.id] === connection else { return }
                self.resolvers.removeValue(forKey: endpoint.id); connection.cancel()
            }
        }
    }
    private func attempt() {
        guard policy.wantsConnection, pending.isEmpty, !policy.pinned else { return }
        let usable: (ConnectionEndpoint) -> Bool = { self.history.usable($0.path == .usb ? "usb" : $0.id, at: Date()) }
        let selection = ComputerRouteSelection(identity: selectedIdentity,
            routeID: selectedRouteID, fallbackRouteID: fallback?.id)
        let matches: (ConnectionEndpoint) -> Bool = { selection.includes(identity: $0.identity, routeID: $0.id) }
        var endpoint: ConnectionEndpoint?
        if routeRestriction.includes(.usb), !networkTestOnly, let usbEndpoint, policy.path != .usb, usable(usbEndpoint), matches(usbEndpoint) { endpoint = usbEndpoint }
        if routeRestriction.includes(.network), endpoint == nil && policy.active == nil {
            let candidates = ((fallback.map { [$0] } ?? []) + networks).filter(matches)
            if let selected = history.choose(candidates.map { $0.id }, at: Date()) { endpoint = candidates.first { $0.id == selected } }
        }
        guard let endpoint else {
            if policy.active == nil { onSearching?(); scheduleRetry() }
            else if !networkTestOnly, policy.path == .network, let usbEndpoint,
                    matches(usbEndpoint), !usable(usbEndpoint) { scheduleRetry() }
            return
        }
        retry?.cancel(); retry = nil
        history.started(endpoint.path == .usb ? "usb" : endpoint.id, at: Date())
        let id = UUID(); pending[id] = endpoint; onRequest?(id, endpoint)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.pending[id] != nil else { return }
            self.ended(id)
        }
    }
    private func scheduleRetry() {
        guard policy.wantsConnection else { return }
        retry?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.attempt() }; retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retrySeconds, execute: work)
        retrySeconds = min(10, retrySeconds * 2)
    }
    deinit { pathMonitor.cancel(); browser?.cancel(); resolvers.values.forEach { $0.cancel() }; tunnel.stop(); retry?.cancel() }
}
#endif
