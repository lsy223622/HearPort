import Foundation

enum USBPacketError: Error { case invalidFrame }
func encodeUSBPacket(_ payload: Data) throws -> Data {
    guard !payload.isEmpty, payload.count <= 65535 else { throw USBPacketError.invalidFrame }
    return Data([72,80,85,81,1,0,UInt8(payload.count >> 8),UInt8(payload.count & 255)]) + payload
}
struct USBPacketDecoder {
    private var buffer: [UInt8] = []
    private(set) var peerIdentity: String?
    var complete: Bool { buffer.isEmpty }
    mutating func append(_ input: Data) throws -> [Data] {
        guard input.count <= 65536 else { throw USBPacketError.invalidFrame }
        buffer.append(contentsOf: input)
        var result: [Data] = [], offset = 0
        while buffer.count - offset >= 8 {
            guard Array(buffer[offset..<offset+5]) == [72,80,85,81,1], buffer[offset+5] <= 1 else { throw USBPacketError.invalidFrame }
            let length = Int(buffer[offset+6]) << 8 | Int(buffer[offset+7])
            guard length > 0 else { throw USBPacketError.invalidFrame }
            let isIdentity = buffer[offset+5] == 1
            guard !isIdentity || length == 64 else { throw USBPacketError.invalidFrame }
            guard buffer.count - offset >= length + 8 else { break }
            let payload = Data(buffer[offset+8..<offset+8+length])
            if isIdentity {
                guard let identity = computerIdentity(String(data: payload, encoding: .utf8)),
                      peerIdentity == nil || peerIdentity == identity else { throw USBPacketError.invalidFrame }
                peerIdentity = identity
            } else { result.append(payload) }
            offset += length + 8
        }
        if offset > 0 { buffer.removeFirst(offset) }
        return result
    }
}
struct USBPacketWriteQueue {
    private(set) var packets: [(data: Data, at: UInt64)] = []
    private(set) var bytes = 0
    mutating func push(_ data: Data, at: UInt64) -> Bool {
        guard !data.isEmpty, data.count <= 65535, bytes + data.count <= 65536, packets.count < 128 else { return false }
        packets.append((data, at)); bytes += data.count; return true
    }
    mutating func completed() {
        guard !packets.isEmpty else { return }
        bytes -= packets.removeFirst().data.count
    }
    func expired(at: UInt64, maximumNanoseconds: UInt64) -> Bool {
        guard let first = packets.first else { return false }
        return at >= first.at && at - first.at >= maximumNanoseconds
    }
}

#if canImport(Network)
import Network
public final class USBPacketTunnel {
    public var onAvailable: ((UInt16) -> Void)?
    public var onPeerIdentity: ((UInt16, String) -> Void)?
    public var onUnavailable: ((String) -> Void)?
    private let queue = DispatchQueue(label: "com.hearport.usb-tunnel", qos: .userInitiated)
    private var listener: NWListener?
    private var listenerRetry: DispatchWorkItem?
    private var listenerRetrySeconds: Double = 1
    private var wantsListener = false
    private var udpListener: NWListener?
    private var tcp: NWConnection?
    private var udp: NWConnection?
    private var decoder = USBPacketDecoder()
    private var toTCP = USBPacketWriteQueue(), toUDP = USBPacketWriteQueue()
    private var generation = UUID()
    private var maximum: UInt64 = 100_000_000
    private var timer: DispatchSourceTimer?
    private let diagnostics: HearPortDiagnostics
    private let makeTCPListener: (NWParameters) throws -> NWListener
    public convenience init(diagnostics: HearPortDiagnostics = .shared) {
        self.init(diagnostics: diagnostics, makeTCPListener: { try NWListener(using: $0) })
    }
    init(diagnostics: HearPortDiagnostics, makeTCPListener: @escaping (NWParameters) throws -> NWListener) {
        self.diagnostics = diagnostics; self.makeTCPListener = makeTCPListener
    }
    public func start() {
        queue.async { [weak self] in self?.wantsListener = true; self?.startOnQueue() }
    }
    public func stop(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            self?.wantsListener = false
            self?.listenerRetry?.cancel(); self?.listenerRetry = nil
            self?.listener?.cancel(); self?.listener = nil
            self?.close("USB listener stopped")
            completion?()
        }
    }
    public func setMaximumLatency(milliseconds: Int) {
        queue.async { [weak self] in self?.maximum = UInt64(max(1, min(60000, milliseconds))) * 1_000_000 }
    }
    public func resetConnection() {
        queue.async { [weak self] in self?.close("USB session ended") }
    }
    private func startOnQueue() {
        guard wantsListener, listener == nil else { return }
        listenerRetry?.cancel(); listenerRetry = nil
        do {
            let options = NWProtocolTCP.Options(); options.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: options)
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 52138)
            let server = try makeTCPListener(parameters)
            listener = server
            server.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            server.stateUpdateHandler = { [weak self, weak server] state in
                guard let self, let server, self.listener === server else { return }
                switch state {
                case .ready:
                    self.listenerRetrySeconds = 1
                    self.diagnostics.log(.info, category: .transport, message: "usb_listener_ready", fields: ["port": "52138"])
                case let .waiting(error):
                    self.diagnostics.log(.warning, category: .transport, message: "usb_listener_waiting", fields: ["error": "\(error)"])
                    if self.tcp == nil { self.onUnavailable?("USB listener unavailable") }
                case let .failed(error):
                    self.listenerFailed(error)
                default: break
                }
            }
            server.start(queue: queue)
        } catch { listenerFailed(error) }
    }
    private func listenerFailed(_ error: Error) {
        diagnostics.log(.error, category: .transport, message: "usb_listener_failed", fields: ["error": "\(error)"])
        listener?.cancel(); listener = nil
        let connected = tcp != nil
        close("USB listener unavailable")
        if !connected { onUnavailable?("USB listener unavailable") }
        guard wantsListener else { return }
        let retry = DispatchWorkItem { [weak self] in self?.startOnQueue() }
        listenerRetry = retry
        queue.asyncAfter(deadline: .now() + listenerRetrySeconds, execute: retry)
        listenerRetrySeconds = min(10, listenerRetrySeconds * 2)
    }
    private func accept(_ connection: NWConnection) {
        guard tcp == nil else { connection.cancel(); return }
        generation = UUID(); let id = generation
        tcp = connection; decoder = USBPacketDecoder()
        toTCP = USBPacketWriteQueue(); toUDP = USBPacketWriteQueue()
        do {
            let parameters = NWParameters.udp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let local = try NWListener(using: parameters)
            udpListener = local
            local.stateUpdateHandler = { [weak self, weak local] state in
                guard let self, self.generation == id else { return }
                if case .ready = state, let port = local?.port {
                    self.onAvailable?(port.rawValue)
                    if let identity = self.decoder.peerIdentity { self.onPeerIdentity?(port.rawValue, identity) }
                }
                if case .failed = state { self.close("USB local forwarding unavailable") }
            }
            local.newConnectionHandler = { [weak self] peer in
                guard let self, self.generation == id, self.udp == nil else { peer.cancel(); return }
                self.udp = peer; peer.start(queue: self.queue); self.receiveUDP(peer, id)
            }
            local.start(queue: queue)
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, self.generation == id else { return }
                switch state {
                case .ready: self.receiveTCP(connection, id)
                case .failed, .cancelled: self.close("USB disconnected")
                default: break
                }
            }
            connection.start(queue: queue)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
            timer.setEventHandler { [weak self] in
                guard let self, self.generation == id else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                if self.toTCP.expired(at: now, maximumNanoseconds: self.maximum) || self.toUDP.expired(at: now, maximumNanoseconds: self.maximum) {
                    self.close("USB queue deadline exceeded")
                }
            }
            self.timer = timer; timer.resume()
        } catch { close("USB local forwarding unavailable") }
    }
    private func receiveTCP(_ connection: NWConnection, _ id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, self.generation == id else { return }
            if let data, !data.isEmpty {
                do {
                    let oldIdentity = self.decoder.peerIdentity
                    for packet in try self.decoder.append(data) {
                        guard self.toUDP.push(packet, at: DispatchTime.now().uptimeNanoseconds) else { self.close("USB queue overflow"); return }
                        if self.toUDP.packets.count == 1 { self.sendUDP(id) }
                    }
                    if oldIdentity != self.decoder.peerIdentity, let identity = self.decoder.peerIdentity, let port = self.udpListener?.port {
                        self.onPeerIdentity?(port.rawValue, identity)
                    }
                } catch { self.close("USB invalid packet"); return }
            }
            if complete || error != nil { self.close(self.decoder.complete ? "USB disconnected" : "USB truncated packet"); return }
            self.receiveTCP(connection, id)
        }
    }
    private func receiveUDP(_ peer: NWConnection, _ id: UUID) {
        peer.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.generation == id else { return }
            if let data, !data.isEmpty {
                guard self.toTCP.push(data, at: DispatchTime.now().uptimeNanoseconds) else { self.close("USB queue overflow"); return }
                if self.toTCP.packets.count == 1 { self.sendTCP(id) }
            }
            if error != nil { self.close("USB UDP forwarding failed"); return }
            self.receiveUDP(peer, id)
        }
    }
    private func sendTCP(_ id: UUID) {
        guard let packet = toTCP.packets.first, let tcp else { return }
        guard let data = try? encodeUSBPacket(packet.data) else { close("USB invalid packet"); return }
        tcp.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, self.generation == id else { return }
            if error != nil { self.close("USB write failed"); return }
            self.toTCP.completed(); self.sendTCP(id)
        })
    }
    private func sendUDP(_ id: UUID) {
        guard let packet = toUDP.packets.first, let udp else { return }
        udp.send(content: packet.data, completion: .contentProcessed { [weak self] error in
            guard let self, self.generation == id else { return }
            if error != nil { self.close("USB UDP forwarding failed"); return }
            self.toUDP.completed(); self.sendUDP(id)
        })
    }
    private func close(_ reason: String) {
        let hadConnection = tcp != nil
        generation = UUID(); timer?.cancel(); timer = nil
        tcp?.cancel(); tcp = nil; udp?.cancel(); udp = nil
        udpListener?.cancel(); udpListener = nil
        decoder = USBPacketDecoder()
        toTCP = USBPacketWriteQueue(); toUDP = USBPacketWriteQueue()
        if hadConnection {
            diagnostics.log(.info, category: .transport, message: "usb_tunnel_closed", fields: ["reason": reason])
            onUnavailable?(reason)
        }
    }
    deinit { listenerRetry?.cancel(); listener?.cancel(); tcp?.cancel(); udp?.cancel(); udpListener?.cancel(); timer?.cancel() }
}
#endif
