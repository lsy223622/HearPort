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
    mutating func stop() { wantsConnection = false; active = nil; path = nil; identity = nil; pinned = false }
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
    public init(host: String, port: UInt16 = 52137) {
        self.id = "network:\(host):\(port)"; self.path = .network; self.host = host; self.port = port
        endpoint = .hostPort(host: .init(host), port: .init(rawValue: port)!)
    }
    init(usbPort: UInt16) {
        id = "usb:\(usbPort)"; path = .usb; host = "USB"; port = usbPort
        endpoint = .hostPort(host: "127.0.0.1", port: .init(rawValue: usbPort)!)
    }
    init(service: NWEndpoint) {
        endpoint = service; path = .network; port = 52137
        if case let .service(name, _, _, _) = service { host = name; id = "service:\(name)" }
        else { host = service.debugDescription; id = "service:\(host)" }
    }
}

@MainActor public final class ReceiverConnectionCoordinator: ObservableObject {
    @Published public private(set) var endpoints: [ConnectionEndpoint] = []
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
    private var policy = ConnectionSelectionPolicy()
    private var pending: [UUID: ConnectionEndpoint] = [:]
    private var activeEndpoint: ConnectionEndpoint?
    private var retry: DispatchWorkItem?
    private var retrySeconds: Double = 1
    private var cooldown: [String: Date] = [:]
    private var networkTestOnly = false
    public var hasUSB: Bool { usbEndpoint != nil }
    public var isWaiting: Bool { policy.wantsConnection && policy.active == nil }

    public init(diagnostics: HearPortDiagnostics = .shared) { tunnel = USBPacketTunnel(diagnostics: diagnostics) }
    public func start() {
        guard browser == nil else { return }
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
        tunnel.start()
        let browser = NWBrowser(for: .bonjour(type: "_hearport._udp", domain: "local."), using: .udp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.map { ConnectionEndpoint(service: $0.endpoint) }.sorted { $0.id < $1.id }
            DispatchQueue.main.async {
                guard let self else { return }
                var seen = Set<String>()
                self.networks = found.filter { seen.insert($0.id).inserted }.prefix(8).map { $0 }
                self.publish(); self.attempt()
            }
        }
        browser.start(queue: DispatchQueue(label: "com.hearport.discovery"))
    }
    public func setRememberedIdentity(_ hash: Data?) {
        rememberedName = hash.map { "HearPort-" + $0.prefix(6).map { String(format: "%02x", $0) }.joined() }
    }
    public func connect(manualHost: String, selected: ConnectionEndpoint? = nil) {
        stop()
        fallback = selected?.path == .network ? selected : (manualHost.isEmpty ? nil : ConnectionEndpoint(host: manualHost))
        policy.wantsConnection = true; cooldown = [:]; networkTestOnly = false; retrySeconds = 1
        attempt()
    }
    public func authenticated(_ id: UUID, identity: Data, features: UInt32) -> Bool {
        guard let endpoint = pending[id], policy.wantsConnection else { return false }
        let networkTest = (features & (ControlFeature.networkProbe | ControlFeature.environmentCalibration)) != 0
        if endpoint.path == .usb && networkTest {
            networkTestOnly = true; pending.removeValue(forKey: id); onCancel?(id); attempt(); return false
        }
        let previous = policy.active
        guard policy.promote(id, path: endpoint.path, identity: identity) else {
            pending.removeValue(forKey: id); onCancel?(id); return false
        }
        pending.removeValue(forKey: id); activeEndpoint = endpoint; retrySeconds = 1
        policy.pinned = networkTest || (features & (ControlFeature.musicTest | ControlFeature.timedDiagnostics)) != 0
        if let previous, previous != id { onCancel?(previous) }
        DispatchQueue.main.async { [weak self] in self?.attempt() }
        return true
    }
    public func pinActive() { policy.pinned = true }
    public func completed() { policy.wantsConnection = false; retry?.cancel(); retry = nil; cancelPending() }
    public func stop() {
        let old = policy.active
        policy.stop(); activeEndpoint = nil
        retry?.cancel(); retry = nil; cancelPending()
        if let old { onCancel?(old) }
    }
    public func ended(_ id: UUID) {
        if let candidate = pending.removeValue(forKey: id) {
            cooldown[candidate.id] = Date().addingTimeInterval(retrySeconds); onCancel?(id)
        } else if policy.closed(id) { activeEndpoint = nil }
        else { return }
        scheduleRetry()
    }
    public func setMaximumLatency(_ ms: Int) { tunnel.setMaximumLatency(milliseconds: ms) }
    private func cancelPending() {
        let ids = Array(pending.keys); pending.removeAll()
        for id in ids { onCancel?(id) }
    }
    private func publish() { endpoints = (usbEndpoint.map { [$0] } ?? []) + networks }
    private func attempt() {
        guard policy.wantsConnection, pending.isEmpty, !policy.pinned else { return }
        let usable: (ConnectionEndpoint) -> Bool = { self.cooldown[$0.id, default: .distantPast] <= Date() }
        var endpoint: ConnectionEndpoint?
        if !networkTestOnly, let usbEndpoint, policy.path != .usb, usable(usbEndpoint) { endpoint = usbEndpoint }
        if endpoint == nil && policy.active == nil {
            if let fallback, usable(fallback) { endpoint = fallback }
            else { endpoint = networks.first { (rememberedName == nil || $0.host == rememberedName) && usable($0) } }
        }
        guard let endpoint else {
            if policy.active == nil { onSearching?(); scheduleRetry() }
            return
        }
        retry?.cancel(); retry = nil
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
    deinit { browser?.cancel(); tunnel.stop(); retry?.cancel() }
}
#endif
