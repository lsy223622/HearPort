import Foundation

public final class HearPortReceiver {
    public let diagnostics: HearPortDiagnostics
    public let session = ReceiverSessionState()
    public let lifecycle: AudioLifecycleController
    public private(set) var invalidDatagrams = 0

    private var jitter: JitterBuffer?
    private var renderRing: RenderRingBuffer
    private let lock = NSLock()

    public init(startupPackets: Int = 8,
                renderCapacityFrames: Int = 4_800,
                diagnostics: HearPortDiagnostics = .shared) {
        precondition(startupPackets > 0)
        precondition(renderCapacityFrames > 0)
        self.diagnostics = diagnostics
        lifecycle = AudioLifecycleController(diagnostics: diagnostics)
        renderRing = RenderRingBuffer(capacityFrames: renderCapacityFrames)
        startupPacketTarget = startupPackets
        diagnostics.log(
            .info,
            category: .realtime,
            message: "receiver_initialized",
            fields: [
                "event": "receiver_initialized",
                "startup_packets": "\(startupPackets)",
                "render_capacity_frames": "\(renderCapacityFrames)"
            ]
        )
    }

    public var renderFillFrames: Int {
        guard lock.try() else { return 0 }
        defer { lock.unlock() }
        return renderRing.fillFrames
    }

    public var jitterStats: JitterStats? {
        lock.lock()
        defer { lock.unlock() }
        return jitter?.stats
    }

    private let startupPacketTarget: Int

    @discardableResult
    public func beginStream(_ streamID: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard session.beginStream(streamID) else {
            diagnostics.log(
                .warning,
                category: .realtime,
                message: "stream_begin_rejected",
                fields: ["event": "stream_begin_rejected", "stream_id": "\(streamID)"]
            )
            return false
        }
        jitter = JitterBuffer(streamID: streamID,
                              startupPackets: startupPacketTarget)
        renderRing.reset()
        diagnostics.log(
            .info,
            category: .realtime,
            message: "stream_begin_accepted",
            fields: [
                "event": "stream_begin_accepted",
                "stream_id": "\(streamID)",
                "startup_packets": "\(startupPacketTarget)"
            ]
        )
        return true
    }

    @discardableResult
    public func markAuthenticated() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let accepted = session.markAuthenticated()
        diagnostics.log(
            accepted ? .info : .warning,
            category: .pairing,
            message: accepted ? "authentication_accepted" : "authentication_rejected",
            fields: [
                "event": accepted ? "authentication_accepted" : "authentication_rejected",
                "phase": "\(session.phase)"
            ]
        )
        return accepted
    }

    @discardableResult
    public func acknowledgeStartStream(_ streamID: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let accepted = session.ackWritten(streamID)
        diagnostics.log(
            accepted ? .info : .warning,
            category: .control,
            message: accepted ? "start_stream_acknowledged" : "start_stream_ack_rejected",
            fields: [
                "event": accepted ? "start_stream_acknowledged" : "start_stream_ack_rejected",
                "stream_id": "\(streamID)",
                "phase": "\(session.phase)"
            ]
        )
        return accepted
    }

    @discardableResult
    public func receiveDatagram(_ data: Data) -> AudioDisposition? {
        lock.lock()
        defer { lock.unlock() }
        let packet: AudioDatagram
        do {
            packet = try AudioDatagram(encoded: data)
        } catch {
            invalidDatagrams += 1
            diagnostics.log(
                .warning,
                category: .audio,
                message: "datagram_rejected",
                fields: [
                    "event": "invalid_datagram",
                    "bytes": "\(data.count)",
                    "reason": "\(error)"
                ]
            )
            return nil
        }
        let disposition = session.acceptAudio(packet)
        guard disposition == .accepted,
              var buffer = jitter else {
            diagnostics.log(
                .debug,
                category: .audio,
                message: "datagram_discarded",
                fields: [
                    "event": "datagram_discarded",
                    "stream_id": "\(packet.streamID)",
                    "sequence": "\(packet.sequence)",
                    "audio_bytes": "\(packet.pcm.count)",
                    "disposition": "\(disposition)"
                ]
            )
            return disposition
        }
        let insertResult = buffer.insert(packet)
        let started = buffer.startIfReady()
        jitter = buffer
        diagnostics.log(
            .debug,
            category: .audio,
            message: "datagram_received",
            fields: [
                "event": "datagram_received",
                "stream_id": "\(packet.streamID)",
                "sequence": "\(packet.sequence)",
                "audio_bytes": "\(packet.pcm.count)",
                "jitter_result": "\(insertResult)",
                "jitter_mode": "\(buffer.mode)",
                "buffer_packets": "\(buffer.fillPackets)",
                "buffer_started": "\(started)"
            ]
        )
        return .accepted
    }

    public func handleAudioLifecycle(_ event: AudioLifecycleEvent) {
        lock.lock()
        defer { lock.unlock() }
        let previousState = lifecycle.state
        lifecycle.handle(event)
        switch event {
        case .interruptionBegan:
            renderRing.reset()
            jitter?.enterSilentRebuffer()
            session.enterInterruption()
        case .routeChanged:
            renderRing.reset()
            jitter?.enterSilentRebuffer()
            session.enterInterruption()
            session.recoverToRebuffer()
        case .interruptionEnded:
            session.recoverToRebuffer()
        case .audioAvailable:
            break
        }
        diagnostics.log(
            .info,
            category: .audio,
            message: "audio_lifecycle",
            fields: [
                "event": Self.diagnosticName(for: event),
                "previous_state": "\(previousState)",
                "state": "\(lifecycle.state)",
                "reset_generation": "\(lifecycle.resetGeneration)"
            ]
        )
    }

    public func enterSilentRebuffer() {
        lock.lock()
        defer { lock.unlock() }
        jitter?.enterSilentRebuffer()
        session.enterSilentRebuffer()
        lifecycle.enterSilentRebuffer()
        renderRing.reset()
        diagnostics.log(
            .info,
            category: .audio,
            message: "silent_rebuffer_entered",
            fields: [
                "event": "silent_rebuffer_entered",
                "phase": "\(session.phase)",
                "state": "\(lifecycle.state)"
            ]
        )
    }

    public func renderFrames(_ frameCount: Int) -> [Float] {
        guard frameCount > 0 else { return [] }
        guard lock.try() else {
            return Array(repeating: 0, count: frameCount * 2)
        }
        defer { lock.unlock() }
        let wasSilent = lifecycle.shouldRenderSilence
        pumpLocked(minimumFrames: frameCount)
        let output = renderRing.pop(frames: frameCount)
        if let buffer = jitter,
           renderRing.fillFrames == 0,
           buffer.fillPackets == 0,
           buffer.mode != .silentRebuffer {
            jitter?.enterSilentRebuffer()
            session.enterSilentRebuffer()
            lifecycle.enterSilentRebuffer()
        }
        if wasSilent || lifecycle.shouldRenderSilence {
            return wasSilent
                ? Array(repeating: 0, count: frameCount * 2)
                : output
        }
        return output
    }

    private func pumpLocked(minimumFrames: Int) {
        guard var buffer = jitter else { return }
        while renderRing.fillFrames < minimumFrames {
            if let packet = buffer.consumeNext() {
                renderRing.push(Self.decodePCM(packet.pcm))
            } else if buffer.hasFuturePacket,
                      let concealed = buffer.concealMissing() {
                renderRing.push(Self.decodePCM(concealed))
            } else {
                break
            }
        }
        jitter = buffer
        if buffer.mode == .running {
            lifecycle.handle(.audioAvailable)
        }
    }

    private static func decodePCM(_ pcm: Data) -> [Float] {
        guard pcm.count == AudioDatagram.pcmByteCount else { return [] }
        var samples: [Float] = []
        samples.reserveCapacity(pcm.count / 4)
        var offset = 0
        while offset < pcm.count {
            let bits = UInt32(pcm[offset]) |
                (UInt32(pcm[offset + 1]) << 8) |
                (UInt32(pcm[offset + 2]) << 16) |
                (UInt32(pcm[offset + 3]) << 24)
            samples.append(Float(bitPattern: bits))
            offset += 4
        }
        return samples
    }

    private static func diagnosticName(for event: AudioLifecycleEvent) -> String {
        switch event {
        case .interruptionBegan: return "interruption_began"
        case .interruptionEnded: return "interruption_ended"
        case .routeChanged: return "route_changed"
        case .audioAvailable: return "audio_available"
        }
    }
}

#if canImport(Network)
import Network
import Security

public enum QuicReceiverState: Equatable, Sendable {
    case idle
    case connecting
    case ready
    case failed
    case closed
}

public enum QuicTransportError: Error, Equatable {
    case controlStreamUnavailable
    case malformedTLSIdentity
}

public enum TLSIdentityPolicy: Sendable {
    case pairing(onPeerSPKIHash: @Sendable (Data) -> Void)
    case remembered(spkiSHA256: Data)
}

public final class HearPortQuicTransport {
    public static let alpn = "hearport/1"
    public static let defaultPort: UInt16 = 52_137

    public typealias DataHandler = @Sendable (Data) -> Void
    public typealias StateHandler = @Sendable (QuicReceiverState) -> Void

    public private(set) var state: QuicReceiverState = .idle
    public var onControlData: DataHandler?
    public var onAudioDatagram: DataHandler?
    public var onStateChange: StateHandler?

    private let queue = DispatchQueue(label: "com.hearport.quic")
    private let diagnostics: HearPortDiagnostics
    private var group: NWConnectionGroup?
    private var controlStream: NWConnection?
    private var datagramFlow: NWConnection?
    private var controlReady = false
    private var datagramReady = false

    public init(diagnostics: HearPortDiagnostics = .shared) {
        self.diagnostics = diagnostics
        diagnostics.log(
            .debug,
            category: .transport,
            message: "transport_initialized",
            fields: ["event": "transport_initialized"]
        )
    }

    public func connect(
        host: String,
        port: UInt16 = defaultPort,
        tlsPolicy: TLSIdentityPolicy
    ) {
        let policyName: String
        switch tlsPolicy {
        case .pairing: policyName = "pairing"
        case .remembered: policyName = "remembered"
        }
        diagnostics.log(
            .info,
            category: .transport,
            message: "connect_requested",
            fields: [
                "event": "connect_requested",
                "host": host,
                "port": "\(port)",
                "tls_policy": policyName
            ]
        )
        cancel()
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let quicOptions = NWProtocolQUIC.Options(alpn: [Self.alpn])
        sec_protocol_options_set_tls_resumption_enabled(
            quicOptions.securityProtocolOptions,
            false
        )
        sec_protocol_options_set_tls_tickets_enabled(
            quicOptions.securityProtocolOptions,
            false
        )
        sec_protocol_options_set_verify_block(
            quicOptions.securityProtocolOptions,
            { metadata, _, complete in
                guard let certificateData = Self.peerSPKI(from: metadata),
                      let spkiHash = try? PairingSecurity.windowsSPKIHash(certificateData)
                else {
                    self.diagnostics.log(
                        .warning,
                        category: .security,
                        message: "tls_identity_rejected",
                        fields: [
                            "event": "tls_identity_rejected",
                            "reason": "missing_or_malformed_peer_identity",
                            "tls_policy": policyName
                        ]
                    )
                    complete(false)
                    return
                }
                let accepted: Bool
                switch tlsPolicy {
                case let .pairing(onPeerSPKIHash):
                    onPeerSPKIHash(spkiHash)
                    accepted = true
                case let .remembered(expectedSPKIHash):
                    accepted = PairingSecurity.constantTimeEqual(spkiHash, expectedSPKIHash)
                }
                self.diagnostics.log(
                    accepted ? .info : .warning,
                    category: .security,
                    message: accepted ? "tls_identity_accepted" : "tls_identity_rejected",
                    fields: [
                        "event": accepted ? "tls_identity_accepted" : "tls_identity_rejected",
                        "spki_bytes": "\(spkiHash.count)",
                        "tls_policy": policyName
                    ]
                )
                complete(accepted)
            },
            queue
        )
        let parameters = NWParameters(quic: quicOptions)
        let multiplex = NWMultiplexGroup(to: endpoint)
        let connectionGroup = NWConnectionGroup(with: multiplex,
                                                 using: parameters)
        group = connectionGroup
        state = .connecting
        diagnostics.log(
            .info,
            category: .transport,
            message: "transport_connecting",
            fields: ["event": "transport_connecting", "host": host, "port": "\(port)"]
        )
        onStateChange?(.connecting)

        connectionGroup.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .ready:
                self.openFlows(endpoint: endpoint,
                               connectionGroup: connectionGroup)
            case .failed:
                self.updateState(.failed)
            case .cancelled:
                self.updateState(.closed)
            default:
                break
            }
        }
        connectionGroup.newConnectionHandler = { connection in
            connection.cancel()
        }
        connectionGroup.start(queue: queue)
    }

    public func sendControl(
        _ payload: Data,
        completion: @escaping @Sendable (NWError?) -> Void = { _ in }
    ) throws {
        let framed = try ControlFraming.encode(payload)
        guard let controlStream else { throw QuicTransportError.controlStreamUnavailable }
        diagnostics.log(
            .debug,
            category: .control,
            message: "control_write",
            fields: [
                "event": "control_write",
                "payload_bytes": "\(payload.count)",
                "framed_bytes": "\(framed.count)"
            ]
        )
        controlStream.send(content: framed,
                           contentContext: .defaultMessage,
                           isComplete: true,
                           completion: .contentProcessed { error in
                               completion(error)
                           })
    }

    public func cancel() {
        controlStream?.cancel()
        datagramFlow?.cancel()
        group?.cancel()
        controlStream = nil
        datagramFlow = nil
        group = nil
        controlReady = false
        datagramReady = false
        diagnostics.log(
            .info,
            category: .transport,
            message: "transport_cancelled",
            fields: ["event": "transport_cancelled"]
        )
        updateState(.closed)
    }

    private func openFlows(endpoint: NWEndpoint,
                           connectionGroup: NWConnectionGroup) {
        let controlOptions = NWProtocolQUIC.Options()
        controlOptions.direction = .bidirectional
        controlOptions.isDatagram = false
        let datagramOptions = NWProtocolQUIC.Options()
        datagramOptions.direction = .bidirectional
        datagramOptions.isDatagram = true
        datagramOptions.maxDatagramFrameSize = AudioDatagram.byteCount

        guard let control = connectionGroup.extract(connectionTo: endpoint,
                                                     using: controlOptions),
              let datagram = connectionGroup.extract(connectionTo: endpoint,
                                                      using: datagramOptions) else {
            diagnostics.log(
                .error,
                category: .transport,
                message: "flow_open_failed",
                fields: ["event": "flow_open_failed"]
            )
            updateState(.failed)
            return
        }
        controlStream = control
        datagramFlow = datagram
        control.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.controlReady = true
                self.diagnostics.log(
                    .info,
                    category: .transport,
                    message: "control_flow_ready",
                    fields: ["event": "control_flow_ready"]
                )
                self.updateReadyIfPossible()
            case .failed:
                self.diagnostics.log(
                    .error,
                    category: .transport,
                    message: "control_flow_failed",
                    fields: ["event": "control_flow_failed"]
                )
                self.updateState(.failed)
            default:
                break
            }
        }
        datagram.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.datagramReady = true
                self.diagnostics.log(
                    .info,
                    category: .transport,
                    message: "datagram_flow_ready",
                    fields: ["event": "datagram_flow_ready"]
                )
                self.updateReadyIfPossible()
            case .failed:
                self.diagnostics.log(
                    .error,
                    category: .transport,
                    message: "datagram_flow_failed",
                    fields: ["event": "datagram_flow_failed"]
                )
                self.updateState(.failed)
            default:
                break
            }
        }
        control.start(queue: queue)
        datagram.start(queue: queue)
        receiveControl(on: control)
        receiveDatagrams(on: datagram)
    }

    private func updateReadyIfPossible() {
        if controlReady && datagramReady {
            updateState(.ready)
        }
    }

    private func receiveControl(on stream: NWConnection) {
        stream.receive(minimumIncompleteLength: 1, maximumLength: 65_540) {
            [weak self] data, _, isComplete, error in
            if let data {
                self?.diagnostics.log(
                    .debug,
                    category: .control,
                    message: "control_read",
                    fields: ["event": "control_read", "bytes": "\(data.count)"]
                )
                self?.onControlData?(data)
            }
            if let error {
                self?.diagnostics.log(
                    .warning,
                    category: .transport,
                    message: "control_read_failed",
                    fields: ["event": "control_read_failed", "error": "\(error)"]
                )
            }
            guard error == nil, !isComplete else { return }
            self?.receiveControl(on: stream)
        }
    }

    private func receiveDatagrams(on flow: NWConnection) {
        flow.receiveMessage { [weak self] data, _, _, error in
            if let data {
                self?.diagnostics.log(
                    .debug,
                    category: .audio,
                    message: "datagram_read",
                    fields: ["event": "datagram_read", "bytes": "\(data.count)"]
                )
                self?.onAudioDatagram?(data)
            }
            if let error {
                self?.diagnostics.log(
                    .warning,
                    category: .transport,
                    message: "datagram_read_failed",
                    fields: ["event": "datagram_read_failed", "error": "\(error)"]
                )
            }
            guard error == nil else { return }
            self?.receiveDatagrams(on: flow)
        }
    }

    private func updateState(_ newState: QuicReceiverState) {
        let previous = state
        state = newState
        diagnostics.log(
            .info,
            category: .transport,
            message: "transport_state_changed",
            fields: [
                "event": "transport_state_changed",
                "previous_state": "\(previous)",
                "state": "\(newState)"
            ]
        )
        onStateChange?(newState)
    }

    private static func peerSPKI(from metadata: sec_protocol_metadata_t) -> Data? {
        var certificateData: Data?
        guard sec_protocol_metadata_access_peer_certificate_chain(metadata, { certificate in
            let reference = sec_certificate_copy_ref(certificate).takeRetainedValue()
            certificateData = SecCertificateCopyData(reference) as Data?
        }) else {
            return nil
        }
        guard let certificateData else { return nil }
        return extractSPKI(from: certificateData)
    }

    private struct DERValue {
        let tag: UInt8
        let fullRange: Range<Int>
        let contentRange: Range<Int>
    }

    private static func readDER(_ bytes: [UInt8], from offset: inout Int) -> DERValue? {
        guard offset < bytes.count else { return nil }
        let start = offset
        let tag = bytes[offset]
        offset += 1
        guard offset < bytes.count else { return nil }
        let firstLengthByte = bytes[offset]
        offset += 1
        let length: Int
        if firstLengthByte & 0x80 == 0 {
            length = Int(firstLengthByte)
        } else {
            let lengthBytes = Int(firstLengthByte & 0x7f)
            guard lengthBytes > 0, lengthBytes <= 4,
                  offset + lengthBytes <= bytes.count else { return nil }
            var decoded = 0
            for _ in 0..<lengthBytes {
                decoded = (decoded << 8) | Int(bytes[offset])
                offset += 1
            }
            length = decoded
        }
        let contentStart = offset
        let contentEnd = contentStart + length
        guard contentEnd <= bytes.count else { return nil }
        offset = contentEnd
        return DERValue(
            tag: tag,
            fullRange: start..<contentEnd,
            contentRange: contentStart..<contentEnd
        )
    }

    private static func extractSPKI(from certificate: Data) -> Data? {
        let bytes = Array(certificate)
        var outerOffset = 0
        guard let outer = readDER(bytes, from: &outerOffset), outer.tag == 0x30 else {
            return nil
        }
        var tbsOffset = outer.contentRange.lowerBound
        guard let tbs = readDER(bytes, from: &tbsOffset), tbs.tag == 0x30 else {
            return nil
        }
        var cursor = tbs.contentRange.lowerBound
        if cursor < tbs.contentRange.upperBound, bytes[cursor] == 0xa0 {
            guard readDER(bytes, from: &cursor) != nil else { return nil }
        }
        for _ in 0..<5 {
            guard readDER(bytes, from: &cursor) != nil else { return nil }
        }
        guard let subjectPublicKeyInfo = readDER(bytes, from: &cursor),
              subjectPublicKeyInfo.tag == 0x30 else {
            return nil
        }
        return Data(bytes[subjectPublicKeyInfo.fullRange])
    }
}
#endif
