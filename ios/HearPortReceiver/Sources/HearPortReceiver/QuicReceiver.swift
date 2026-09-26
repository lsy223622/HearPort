import Foundation

public final class HearPortReceiver {
    public let diagnostics: HearPortDiagnostics
    let debugSessionDiagnostics: DebugSessionDiagnostics
    public let session = ReceiverSessionState()
    public let lifecycle: AudioLifecycleController
    public private(set) var invalidDatagrams = 0

    private var jitter: JitterBuffer?
    private var renderRing: RenderRingBuffer
    private let lock = NSLock()
    private var loggedFirstAudioDatagram = false
    private var lastReceivedSequence: UInt32?
    private var outputRoute = "unknown"
    private var outputSampleRate = 48_000.0
    private let realtimeMetrics = RealtimeAudioMetrics()
    private let realtimeReporterQueue = DispatchQueue(
        label: "com.hearport.receiver.realtime-reporter",
        qos: .utility
    )
    private var realtimeReporter: DispatchSourceTimer?

    public init(bufferTargetPackets: Int = 8,
                renderCapacityFrames: Int = 4_800,
                diagnostics: HearPortDiagnostics = .shared,
                debugSessionDiagnostics: DebugSessionDiagnostics? = nil) {
        precondition(renderCapacityFrames > 0)
        self.diagnostics = diagnostics
        let normalizedBufferTarget = JitterBufferConfiguration(targetPackets: bufferTargetPackets)
            .targetPackets
        self.debugSessionDiagnostics = debugSessionDiagnostics ?? DebugSessionDiagnostics(
            bufferTargetPackets: normalizedBufferTarget,
            diagnostics: diagnostics
        )
        lifecycle = AudioLifecycleController(diagnostics: diagnostics)
        renderRing = RenderRingBuffer(capacityFrames: renderCapacityFrames)
        jitterTargetPackets = normalizedBufferTarget
        diagnostics.log(
            .info,
            category: .realtime,
            message: "receiver_initialized",
            fields: [
                "event": "receiver_initialized",
                "jitter_target_packets": "\(jitterTargetPackets)",
                "render_capacity_frames": "\(renderCapacityFrames)"
            ]
        )
        startRealtimeReporter()
    }

    deinit {
        realtimeReporter?.cancel()
    }

    public var renderFillFrames: Int {
        guard lock.try() else { return 0 }
        defer { lock.unlock() }
        return renderRing.fillFrames + (jitter?.fillPackets ?? 0) * AudioDatagram.framesPerPacket
    }

    public var jitterStats: JitterStats? {
        lock.lock()
        defer { lock.unlock() }
        return jitter?.stats
    }

    public func recordRenderCallback(requestedFrames: Int,
                                     renderedFrames: Int,
                                     fillFrames: Int,
                                     resamplerRatio: Double,
                                     fillError: Double) {
        realtimeMetrics.recordRenderCallback(
            requestedFrames: requestedFrames,
            renderedFrames: renderedFrames,
            fillFrames: fillFrames,
            resamplerRatio: resamplerRatio,
            fillError: fillError
        )
    }

    public func recordAudioOutput(route: String, sampleRate: Double) {
        lock.lock()
        outputRoute = route
        outputSampleRate = sampleRate
        lock.unlock()
    }

    private let jitterTargetPackets: Int

    var jitterTargetFrames: Int {
        jitterTargetPackets * AudioDatagram.framesPerPacket
    }

    @discardableResult
    public func beginAuthentication(authMode: AuthMode, peerID: Data) -> Bool {
        lock.lock()
        let accepted = session.receiveConnect(authMode: authMode, peerID: peerID)
        let phase = session.phase
        lock.unlock()
        diagnostics.log(
            accepted ? .info : .warning,
            category: .pairing,
            message: accepted ? "connect_accepted" : "connect_rejected",
            fields: [
                "event": accepted ? "connect_accepted" : "connect_rejected",
                "auth_mode": "\(authMode)",
                "peer_id_bytes": "\(peerID.count)",
                "phase": "\(phase)"
            ]
        )
        return accepted
    }

    public func resetForConnection() {
        lock.lock()
        session.resetForConnection()
        jitter = nil
        renderRing.reset()
        loggedFirstAudioDatagram = false
        lastReceivedSequence = nil
        realtimeMetrics.resetInterval()
        lock.unlock()
        diagnostics.log(
            .debug,
            category: .pairing,
            message: "receiver_connection_reset",
            fields: ["event": "receiver_connection_reset"]
        )
    }

    @discardableResult
    public func beginStream(_ streamID: UInt32) -> Bool {
        lock.lock()
        let accepted = session.beginStream(streamID)
        if accepted {
            jitter = JitterBuffer(streamID: streamID,
                                  targetPackets: jitterTargetPackets)
            renderRing.reset()
            loggedFirstAudioDatagram = false
            lastReceivedSequence = nil
            realtimeMetrics.resetInterval()
        }
        let phase = session.phase
        lock.unlock()
        diagnostics.log(
            accepted ? .info : .warning,
            category: .realtime,
            message: accepted ? "stream_begin_accepted" : "stream_begin_rejected",
            fields: [
                "event": accepted ? "stream_begin_accepted" : "stream_begin_rejected",
                "stream_id": "\(streamID)",
                "jitter_target_packets": "\(jitterTargetPackets)",
                "phase": "\(phase)"
            ]
        )
        return accepted
    }

    @discardableResult
    public func markAuthenticated() -> Bool {
        lock.lock()
        let accepted = session.markAuthenticated()
        let phase = session.phase
        lock.unlock()
        diagnostics.log(
            accepted ? .info : .warning,
            category: .pairing,
            message: accepted ? "authentication_accepted" : "authentication_rejected",
            fields: [
                "event": accepted ? "authentication_accepted" : "authentication_rejected",
                "phase": "\(phase)"
            ]
        )
        return accepted
    }

    @discardableResult
    public func acknowledgeStartStream(_ streamID: UInt32) -> Bool {
        lock.lock()
        let accepted = session.ackWritten(streamID)
        let phase = session.phase
        lock.unlock()
        diagnostics.log(
            accepted ? .info : .warning,
            category: .control,
            message: accepted ? "start_stream_acknowledged" : "start_stream_ack_rejected",
            fields: [
                "event": accepted ? "start_stream_acknowledged" : "start_stream_ack_rejected",
                "stream_id": "\(streamID)",
                "phase": "\(phase)"
            ]
        )
        return accepted
    }

    @discardableResult
    public func receiveDatagram(_ data: Data) -> AudioDisposition? {
        realtimeMetrics.recordDatagram(byteCount: data.count)
        let receivedAt = DispatchTime.now().uptimeNanoseconds
        let packet: AudioDatagram
        do {
            packet = try AudioDatagram(encoded: data)
        } catch {
            lock.lock()
            invalidDatagrams += 1
            lock.unlock()
            realtimeMetrics.recordInvalidDatagram()
            _ = diagnostics.logAsync(
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

        var firstFields: [String: String]?
        var transitionFields: [String: String]?
        var jitterResult: JitterInsertResult?
        var trimmedSequences: [UInt32] = []
        var fillPackets = 0
        var disposition: AudioDisposition
        lock.lock()
        disposition = session.acceptAudio(packet)
        realtimeMetrics.recordDisposition(disposition)
        if disposition == .accepted {
            lastReceivedSequence = packet.sequence
        }
        if disposition == .accepted {
            let previousMode = jitter?.mode
            let previousTrimmedPackets = jitter?.stats.trimmedPackets ?? 0
            if let insertResult = jitter?.insert(packet) {
                jitterResult = insertResult
                let started = jitter?.startIfReady() ?? false
                let trimmedPackets = (jitter?.stats.trimmedPackets ?? 0) - previousTrimmedPackets
                trimmedSequences = jitter?.takeTrimmedSequences() ?? []
                fillPackets = jitter?.fillPackets ?? 0
                realtimeMetrics.recordJitterResult(insertResult,
                                                   fillPackets: fillPackets,
                                                   trimmedPackets: trimmedPackets)
                if started && previousMode != jitter?.mode {
                    transitionFields = [
                        "event": "jitter_started",
                        "stream_id": "\(packet.streamID)",
                        "sequence": "\(packet.sequence)",
                        "jitter_mode": "\(jitter!.mode)",
                        "target_packets": "\(jitter!.targetPackets)",
                        "buffer_packets": "\(fillPackets)"
                    ]
                }
                if !loggedFirstAudioDatagram {
                    loggedFirstAudioDatagram = true
                    firstFields = [
                        "event": "datagram_received",
                        "stream_id": "\(packet.streamID)",
                        "sequence": "\(packet.sequence)",
                        "audio_bytes": "\(packet.pcm.count)",
                        "jitter_result": "\(insertResult)",
                        "jitter_mode": "\(jitter!.mode)",
                        "buffer_packets": "\(fillPackets)",
                        "buffer_started": "\(started)"
                    ]
                }
            }
        }
        lock.unlock()

        debugSessionDiagnostics.recordPacket(
            streamID: packet.streamID,
            sequence: packet.sequence,
            receivedAt: receivedAt,
            disposition: disposition,
            jitterResult: jitterResult,
            fillPackets: fillPackets
        )
        for sequence in trimmedSequences {
            debugSessionDiagnostics.recordJitterDecision(
                streamID: packet.streamID,
                sequence: sequence,
                decision: .trimmed,
                at: receivedAt,
                fillPackets: fillPackets
            )
        }

        if let firstFields {
            _ = diagnostics.logAsync(.debug,
                                     category: .audio,
                                     message: "datagram_received",
                                     fields: firstFields)
        }
        if let transitionFields {
            _ = diagnostics.logAsync(.info,
                                     category: .realtime,
                                     message: "jitter_started",
                                     fields: transitionFields)
        }
        return disposition
    }

    public func handleAudioLifecycle(_ event: AudioLifecycleEvent) {
        lock.lock()
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
        let state = lifecycle.state
        let generation = lifecycle.resetGeneration
        lock.unlock()
        diagnostics.log(
            .info,
            category: .audio,
            message: "audio_lifecycle",
            fields: [
                "event": Self.diagnosticName(for: event),
                "previous_state": "\(previousState)",
                "state": "\(state)",
                "reset_generation": "\(generation)"
            ]
        )
    }

    public func enterSilentRebuffer() {
        lock.lock()
        jitter?.enterSilentRebuffer()
        session.enterSilentRebuffer()
        lifecycle.enterSilentRebuffer()
        renderRing.reset()
        let phase = session.phase
        let state = lifecycle.state
        lock.unlock()
        diagnostics.log(
            .info,
            category: .audio,
            message: "silent_rebuffer_entered",
            fields: [
                "event": "silent_rebuffer_entered",
                "phase": "\(phase)",
                "state": "\(state)"
            ]
        )
    }

    public func renderFrames(_ frameCount: Int) -> [Float] {
        guard frameCount > 0 else { return [] }
        guard lock.try() else {
            realtimeMetrics.recordRenderLockMiss(silencedFrames: frameCount)
            return Array(repeating: 0, count: frameCount * 2)
        }
        defer { lock.unlock() }
        let wasSilent = lifecycle.shouldRenderSilence
        let underflowBefore = renderRing.underflowFrames
        let overflowBefore = renderRing.overflowFrames
        pumpLocked(minimumFrames: frameCount)
        let output = renderRing.pop(frames: frameCount)
        realtimeMetrics.recordRenderBuffer(
            fillFrames: renderRing.fillFrames,
            underflowFrames: renderRing.underflowFrames - underflowBefore,
            overflowFrames: renderRing.overflowFrames - overflowBefore
        )
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
        guard jitter != nil else { return }
        while renderRing.fillFrames < minimumFrames {
            if let packet = jitter?.consumeNext() {
                renderRing.push(Self.decodePCM(packet.pcm))
            } else if jitter?.hasFuturePacket == true,
                      let sequence = jitter?.expectedSequence,
                      let concealed = jitter?.concealMissing() {
                realtimeMetrics.recordConcealment()
                debugSessionDiagnostics.recordJitterDecision(
                    streamID: jitter!.streamID,
                    sequence: sequence,
                    decision: .concealed,
                    at: DispatchTime.now().uptimeNanoseconds,
                    fillPackets: jitter!.fillPackets
                )
                renderRing.push(Self.decodePCM(concealed))
            } else {
                break
            }
        }
        if jitter?.mode == .running {
            lifecycle.handle(.audioAvailable)
        }
    }

    private func startRealtimeReporter() {
        let timer = DispatchSource.makeTimerSource(queue: realtimeReporterQueue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.emitRealtimeDiagnostics()
        }
        timer.resume()
        realtimeReporter = timer
    }

    func emitRealtimeDiagnosticsForTesting() {
        emitRealtimeDiagnostics()
    }

    private func emitRealtimeDiagnostics() {
        guard lock.try() else {
            realtimeMetrics.recordReporterSkipped()
            return
        }
        let phase = session.phase
        let shouldReport = jitter != nil || phase != .awaitingConnect
        guard shouldReport else {
            lock.unlock()
            return
        }
        let buffer = jitter
        let streamID = buffer?.streamID ?? session.activeStreamID ?? session.pendingStreamID
        let lastSequence = lastReceivedSequence
        let expectedSequence = buffer?.expectedSequence
        let mode = buffer?.mode
        let targetPackets = buffer?.targetPackets ?? jitterTargetPackets
        let jitterFillPackets = buffer?.fillPackets ?? 0
        let renderFill = renderRing.fillFrames
        let lifecycleState = lifecycle.state
        let route = outputRoute
        let sampleRate = outputSampleRate
        lock.unlock()

        let diagnosticsDropped = diagnostics.snapshot().asyncDroppedCount
        let snapshot = realtimeMetrics.snapshotAndReset(
            streamID: streamID,
            lastSequence: lastSequence,
            expectedSequence: expectedSequence,
            jitterMode: mode,
            jitterTargetPackets: targetPackets,
            jitterFillPackets: jitterFillPackets,
            renderFillFrames: renderFill,
            sessionPhase: phase,
            lifecycleState: lifecycleState,
            outputRoute: route,
            sampleRate: sampleRate,
            diagnosticsDropped: diagnosticsDropped
        )
        let level: DiagnosticsLevel = debugSessionDiagnostics.isRecording ? .info : .debug
        _ = diagnostics.logAsync(
            level,
            category: .realtime,
            message: "realtime_summary",
            fields: snapshot.fields
        )
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
    public var onControlStreamCreated: (() -> Void)?

    private let queue = DispatchQueue(label: "com.hearport.quic")
    private let diagnostics: HearPortDiagnostics
    private var group: NWConnectionGroup?
    private var controlStream: NWConnection?
    private var controlReady = false
    private var datagramReady = false
    private var loggedFirstDatagram = false

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
        quicOptions.direction = .bidirectional
        quicOptions.isDatagram = true
        // The transport limit includes the QUIC frame header, not just audio bytes.
        quicOptions.maxDatagramFrameSize = 65_535
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
        // Stream options must preserve the tunnel's TLS and transport parameters.
        let controlOptions = parameters.copy().defaultProtocolStack.transportProtocol as! NWProtocolQUIC.Options
        controlOptions.direction = .bidirectional
        controlOptions.isDatagram = false
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
                self.datagramReady = true
                self.diagnostics.log(
                    .info,
                    category: .transport,
                    message: "datagram_group_ready",
                    fields: ["event": "datagram_group_ready"]
                )
                self.openControlStream(
                    connectionGroup: connectionGroup,
                    options: controlOptions
                )
            case let .waiting(error):
                self.diagnostics.log(
                    .warning,
                    category: .transport,
                    message: "transport_waiting",
                    fields: [
                        "event": "transport_waiting",
                        "error": "\(error)"
                    ]
                )
            case let .failed(error):
                self.diagnostics.log(
                    .error,
                    category: .transport,
                    message: "transport_failed",
                    fields: [
                        "event": "transport_failed",
                        "error": "\(error)"
                    ]
                )
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
        connectionGroup.setReceiveHandler(
            maximumMessageSize: AudioDatagram.byteCount,
            rejectOversizedMessages: true
        ) { [weak self] _, data, isComplete in
            guard let self else { return }
            if let data {
                let isFirst = !self.loggedFirstDatagram
                self.loggedFirstDatagram = true
                if isFirst {
                    _ = self.diagnostics.logAsync(
                        .debug,
                        category: .audio,
                        message: "datagram_read",
                        fields: [
                            "event": "datagram_read",
                            "bytes": "\(data.count)",
                            "is_complete": "\(isComplete)"
                        ]
                    )
                }
                self.onAudioDatagram?(data)
            }
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
                           isComplete: false,
                           completion: .contentProcessed { error in
                               completion(error)
                           })
    }

    public func cancel() {
        controlStream?.cancel()
        group?.cancel()
        controlStream = nil
        group = nil
        controlReady = false
        datagramReady = false
        loggedFirstDatagram = false
        diagnostics.log(
            .info,
            category: .transport,
            message: "transport_cancelled",
            fields: ["event": "transport_cancelled"]
        )
        updateState(.closed)
    }

    private func openControlStream(
        connectionGroup: NWConnectionGroup,
        options: NWProtocolQUIC.Options
    ) {
        diagnostics.log(
            .debug,
            category: .control,
            message: "control_stream_open_requested",
            fields: ["event": "control_stream_open_requested", "direction": "bidirectional"]
        )
        guard let control = NWConnection(from: connectionGroup, using: options) else {
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
        control.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .setup, .preparing:
                self.diagnostics.log(
                    .debug,
                    category: .transport,
                    message: "control_flow_state",
                    fields: [
                        "event": "control_flow_state",
                        "state": "\(state)"
                    ]
                )
            case .ready:
                self.controlReady = true
                self.diagnostics.log(
                    .info,
                    category: .transport,
                    message: "control_flow_ready",
                    fields: ["event": "control_flow_ready"]
                )
                self.onControlStreamCreated?()
                self.updateReadyIfPossible()
            case let .waiting(error):
                self.diagnostics.log(
                    .warning,
                    category: .transport,
                    message: "control_flow_waiting",
                    fields: [
                        "event": "control_flow_waiting",
                        "error": "\(error)"
                    ]
                )
            case let .failed(error):
                self.diagnostics.log(
                    .error,
                    category: .transport,
                    message: "control_flow_failed",
                    fields: [
                        "event": "control_flow_failed",
                        "error": "\(error)"
                    ]
                )
                self.updateState(.failed)
            case .cancelled:
                self.diagnostics.log(
                    .debug,
                    category: .transport,
                    message: "control_flow_state",
                    fields: [
                        "event": "control_flow_state",
                        "state": "cancelled"
                    ]
                )
            default:
                break
            }
        }
        control.start(queue: queue)
        receiveControl(on: control)
        diagnostics.log(
            .debug,
            category: .control,
            message: "control_stream_created",
            fields: ["event": "control_stream_created"]
        )
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
