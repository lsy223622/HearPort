#if canImport(Network) && os(iOS)
import Foundation
import Network

public final class ReceiverControlSession {
    public let receiver: HearPortReceiver
    public let transport: HearPortQuicTransport
    private let diagnostics: HearPortDiagnostics

    public var onReady: (() -> Void)?
    public var onError: ((String) -> Void)?
    public var onTransportState: ((QuicReceiverState) -> Void)?

    private let provider: any Spake2Provider
    private let keychain: KeychainRememberedCredentialStore
    private let debugSessionDiagnostics: DebugSessionDiagnostics
    private let debugReportTransfer: DebugReportTransfer
    private let debugQueue = DispatchQueue(
        label: "com.hearport.receiver.debug-report",
        qos: .utility
    )
    private var decoder = ControlFrameDecoder()
    private var mode: AuthMode = .oneTime
    private var pin: String?
    private var credential: RememberedCredential?
    private var pendingCredential: RememberedCredential?
    private var windowsSPKIHash: Data?
    private var spakeOutput: Spake2Output?
    private var connectSent = false
    private var ready = false
    private var receiverReadyNotified = false
    private var peerFeatures: UInt32 = 0
    private var activeDebugSessionID: Data?
    private var activeDebugStreamID: UInt32?
    private var pendingReportSessionID: Data?
    private var pairConfirmationVerified = false
    private var rememberedResponseSent = false

    public init(
        receiver: HearPortReceiver,
        transport: HearPortQuicTransport? = nil,
        provider: any Spake2Provider = UnavailableSpake2Provider(),
        keychain: KeychainRememberedCredentialStore = KeychainRememberedCredentialStore()
    ) {
        self.receiver = receiver
        self.transport = transport ?? HearPortQuicTransport(diagnostics: receiver.diagnostics)
        diagnostics = receiver.diagnostics
        self.provider = provider
        self.keychain = keychain
        debugSessionDiagnostics = receiver.debugSessionDiagnostics
        debugReportTransfer = receiver.debugSessionDiagnostics.reportTransfer
        self.transport.onAudioDatagram = { [weak receiver] data in
            _ = receiver?.receiveDatagram(data)
        }
        self.transport.onControlData = { [weak self] data in
            self?.receiveControlBytes(data)
        }
        self.transport.onControlStreamCreated = { [weak self] in
            self?.sendConnectIfPossible()
        }
        self.transport.onStateChange = { [weak self] state in
            guard let self else { return }
            self.diagnostics.log(
                .info,
                category: .transport,
                message: "session_transport_state",
                fields: ["event": "session_transport_state", "state": "\(state)"]
            )
            self.onTransportState?(state)
            if state == .ready {
                self.sendConnectIfPossible()
            } else if state == .failed || state == .closed {
                if self.debugSessionDiagnostics.isRecording {
                    let reason = state == .closed ? "connection_closed" : "connection_failed"
                    self.debugQueue.async { [weak self] in
                        guard let self, self.debugSessionDiagnostics.isRecording else { return }
                        do {
                            _ = try self.debugSessionDiagnostics.persistPartial(reason: reason)
                        } catch {
                            self.logDebugReportFailure(error, event: "partial_report_persist_failed")
                        }
                    }
                }
                self.ready = false
                self.connectSent = false
                self.pairConfirmationVerified = false
                self.rememberedResponseSent = false
                self.activeDebugSessionID = nil
                self.activeDebugStreamID = nil
                self.receiver.resetForConnection()
            }
        }
        diagnostics.log(
            .debug,
            category: .control,
            message: "control_session_initialized",
            fields: ["event": "control_session_initialized"]
        )
    }

    public func connect(
        host: String,
        port: UInt16 = HearPortQuicTransport.defaultPort,
        mode: AuthMode,
        pin: String? = nil,
        rememberedCredential: RememberedCredential? = nil
    ) {
        self.mode = mode
        self.pin = pin
        self.connectSent = false
        self.ready = false
        self.receiverReadyNotified = false
        self.peerFeatures = 0
        self.activeDebugSessionID = nil
        self.activeDebugStreamID = nil
        self.pendingReportSessionID = nil
        self.decoder = ControlFrameDecoder()
        self.spakeOutput = nil
        self.pendingCredential = nil
        self.pairConfirmationVerified = false
        self.rememberedResponseSent = false
        receiver.resetForConnection()
        diagnostics.log(
            .info,
            category: .control,
            message: "connect_started",
            fields: [
                "event": "connect_started",
                "host": host,
                "port": "\(port)",
                "auth_mode": "\(mode)"
            ]
        )

        if mode == .remembered {
            do {
                credential = try rememberedCredential ?? keychain.load()
                diagnostics.log(
                    .info,
                    category: .security,
                    message: "remembered_credential_loaded",
                    fields: [
                        "event": "remembered_credential_loaded",
                        "found": credential == nil ? "false" : "true"
                    ]
                )
            } catch {
                diagnostics.log(
                    .error,
                    category: .security,
                    message: "remembered_credential_load_failed",
                    fields: [
                        "event": "remembered_credential_load_failed",
                        "error_type": "\(type(of: error))"
                    ]
                )
                onError?("Unable to load the remembered credential")
                return
            }
            guard let credential else {
                diagnostics.log(
                    .warning,
                    category: .security,
                    message: "remembered_credential_missing",
                    fields: ["event": "remembered_credential_missing"]
                )
                onError?("No remembered PC is stored")
                return
            }
            transport.connect(
                host: host,
                port: port,
                tlsPolicy: .remembered(spkiSHA256: credential.windowsSPKISHA256)
            )
        } else {
            credential = nil
            diagnostics.log(
                .info,
                category: .pairing,
                message: "ephemeral_auth_requested",
                fields: ["event": "ephemeral_auth_requested", "auth_mode": "\(mode)"]
            )
            transport.connect(
                host: host,
                port: port,
                tlsPolicy: .pairing(onPeerSPKIHash: { [weak self] hash in
                    self?.windowsSPKIHash = hash
                })
            )
        }
    }

    public func cancel() {
        diagnostics.log(
            .info,
            category: .control,
            message: "control_session_cancelled",
            fields: ["event": "control_session_cancelled"]
        )
        transport.cancel()
        ready = false
        connectSent = false
        pairConfirmationVerified = false
        rememberedResponseSent = false
        receiver.resetForConnection()
    }

    private func sendConnectIfPossible() {
        guard !connectSent else { return }
        guard mode == .remembered || (mode == .pair || mode == .oneTime) else { return }
        let peerID = credential?.peerID ?? Data()
        let envelope = ControlEnvelope(.connectRequest(authMode: mode,
                                                       peerID: peerID,
                                                       features: ControlFeature.diagnosticsUpload))
        do {
            guard receiver.beginAuthentication(authMode: mode, peerID: peerID) else {
                throw PairingSecurityError.providerFailure(-5)
            }
            let encoded = try envelope.encoded()
            diagnostics.log(
                .debug,
                category: .control,
                message: "control_message_sent",
                fields: [
                    "event": "control_message_sent",
                    "message": envelope.message.diagnosticName,
                    "payload_bytes": "\(encoded.count)",
                    "peer_id_bytes": "\(peerID.count)"
                ]
            )
            try transport.sendControl(encoded)
            connectSent = true
        } catch {
            diagnostics.log(
                .error,
                category: .control,
                message: "connect_message_failed",
                fields: ["event": "connect_message_failed", "error_type": "\(type(of: error))"]
            )
            receiver.resetForConnection()
            onError?("Control stream is not available")
        }
    }

    private func receiveControlBytes(_ bytes: Data) {
        do {
            let frames = try decoder.append(bytes)
            diagnostics.log(
                .debug,
                category: .control,
                message: "control_frames_decoded",
                fields: [
                    "event": "control_frames_decoded",
                    "input_bytes": "\(bytes.count)",
                    "frame_count": "\(frames.count)"
                ]
            )
            for frame in frames {
                let envelope = try ControlEnvelope.decode(frame)
                diagnostics.log(
                    .debug,
                    category: .control,
                    message: "control_message_received",
                    fields: [
                        "event": "control_message_received",
                        "message": envelope.message.diagnosticName,
                        "payload_bytes": "\(frame.count)"
                    ]
                )
                try handle(envelope)
            }
        } catch {
            diagnostics.log(
                .error,
                category: .control,
                message: "control_message_decode_failed",
                fields: [
                    "event": "control_message_decode_failed",
                    "input_bytes": "\(bytes.count)",
                    "error_type": "\(type(of: error))"
                ]
            )
            onError?("Malformed control message")
            transport.cancel()
        }
    }

    private func send(_ message: ControlMessage,
                      completion: @escaping @Sendable (NWError?) -> Void = { _ in }) {
        do {
            let envelope = ControlEnvelope(message)
            let encoded = try envelope.encoded()
            diagnostics.log(
                .debug,
                category: .control,
                message: "control_message_sent",
                fields: [
                    "event": "control_message_sent",
                    "message": message.diagnosticName,
                    "payload_bytes": "\(encoded.count)"
                ]
            )
            try transport.sendControl(encoded,
                                      completion: completion)
        } catch {
            diagnostics.log(
                .error,
                category: .control,
                message: "control_message_write_failed",
                fields: [
                    "event": "control_message_write_failed",
                    "message": message.diagnosticName,
                    "error_type": "\(type(of: error))"
                ]
            )
            onError?("Unable to write the control message")
        }
    }

    private func handle(_ envelope: ControlEnvelope) throws {
        diagnostics.log(
            .debug,
            category: .control,
            message: "control_message_handling",
            fields: [
                "event": "control_message_handling",
                "message": envelope.message.diagnosticName
            ]
        )
        switch envelope.message {
        case let .pairSpakeA(peerPoint):
            diagnostics.log(
                .info,
                category: .pairing,
                message: "pairing_spake_a_received",
                fields: ["event": "pairing_spake_a_received", "bytes": "\(peerPoint.count)"]
            )
            try handlePairSpakeA(peerPoint)
        case let .pairConfirmA(confirmation):
            diagnostics.log(
                .info,
                category: .pairing,
                message: "pairing_confirmation_received",
                fields: ["event": "pairing_confirmation_received", "bytes": "\(confirmation.count)"]
            )
            guard let output = spakeOutput,
                  output.verifyPeerConfirmation(confirmation) else {
                diagnostics.log(
                    .warning,
                    category: .security,
                    message: "pairing_confirmation_rejected",
                    fields: ["event": "pairing_confirmation_rejected"]
                )
                throw PairingSecurityError.providerFailure(-1)
            }
            diagnostics.log(
                .info,
                category: .security,
                message: "pairing_confirmation_accepted",
                fields: ["event": "pairing_confirmation_accepted"]
            )
            pairConfirmationVerified = true
            send(.pairConfirmB(output.confirmation))
        case let .pairCredential(peerID, pairSecret):
            guard mode == .pair, pairConfirmationVerified, let windowsSPKIHash else {
                throw PairingSecurityError.invalidLength
            }
            pendingCredential = try RememberedCredential(
                peerID: peerID,
                pairSecret: pairSecret,
                windowsSPKISHA256: windowsSPKIHash
            )
            diagnostics.log(
                .info,
                category: .pairing,
                message: "pairing_credential_received",
                fields: [
                    "event": "pairing_credential_received",
                    "peer_id_bytes": "\(peerID.count)",
                    "credential_bytes": "\(pairSecret.count)"
                ]
            )
        case let .authChallenge(nonce):
            guard mode == .remembered, let credential else {
                throw PairingSecurityError.invalidLength
            }
            let mac = try PairingSecurity.rememberedAuthMAC(
                pairSecret: credential.pairSecret,
                nonce: nonce,
                windowsSPKISHA256: credential.windowsSPKISHA256
            )
            diagnostics.log(
                .info,
                category: .security,
                message: "remembered_auth_challenge_received",
                fields: ["event": "remembered_auth_challenge_received", "nonce_bytes": "\(nonce.count)"]
            )
            rememberedResponseSent = true
            send(.authResponse(peerID: credential.peerID, mac: mac))
        case let .sessionReady(features):
            switch mode {
            case .remembered:
                guard rememberedResponseSent else {
                    throw PairingSecurityError.providerFailure(-6)
                }
            case .pair:
                guard pairConfirmationVerified, pendingCredential != nil else {
                    throw PairingSecurityError.providerFailure(-7)
                }
            case .oneTime:
                guard pairConfirmationVerified else {
                    throw PairingSecurityError.providerFailure(-8)
                }
            }
            guard receiver.markAuthenticated() else {
                throw PairingSecurityError.providerFailure(-2)
            }
            if mode == .pair, let pendingCredential {
                try keychain.save(pendingCredential)
                credential = pendingCredential
                diagnostics.log(
                    .info,
                    category: .security,
                    message: "remembered_credential_saved",
                    fields: ["event": "remembered_credential_saved"]
                )
            }
            ready = true
            peerFeatures = features
            diagnostics.log(
                .info,
                category: .control,
                message: "session_ready",
                fields: [
                    "event": "session_ready",
                    "auth_mode": "\(mode)",
                    "features": "\(features)"
                ]
            )
            if (features & ControlFeature.diagnosticsUpload) != 0 {
                debugQueue.async { [weak self] in
                    guard let self else { return }
                    do {
                        guard let report = try self.debugReportTransfer.pendingReport() else {
                            self.sendReceiverReady()
                            return
                        }
                        let chunks = try self.debugReportTransfer.makeChunks()
                        self.beginReportUpload(report, chunks: chunks)
                    } catch {
                        self.logDebugReportFailure(error, event: "pending_report_prepare_failed")
                        self.onError?("Unable to prepare the pending diagnostic report")
                    }
                }
            } else {
                receiverReadyNotified = true
                onReady?()
            }
        case let .startStream(streamID):
            if activeDebugSessionID != nil, activeDebugStreamID != streamID {
                throw PairingSecurityError.providerFailure(-12)
            }
            diagnostics.log(
                .info,
                category: .realtime,
                message: "start_stream_received",
                fields: ["event": "start_stream_received", "stream_id": "\(streamID)"]
            )
            guard receiver.beginStream(streamID) else {
                throw PairingSecurityError.providerFailure(-3)
            }
            send(.startStreamAck(streamID), completion: { [weak self] error in
                guard let self else { return }
                guard error == nil else {
                    self.diagnostics.log(
                        .error,
                        category: .control,
                        message: "start_stream_ack_failed",
                        fields: [
                            "event": "start_stream_ack_failed",
                            "stream_id": "\(streamID)",
                            "error": "\(String(describing: error))"
                        ]
                    )
                    self.onError?("Unable to write StartStreamAck")
                    return
                }
                self.diagnostics.log(
                    .info,
                    category: .control,
                    message: "start_stream_ack_written",
                    fields: ["event": "start_stream_ack_written", "stream_id": "\(streamID)"]
                )
                _ = self.receiver.acknowledgeStartStream(streamID)
            })
        case let .error(code, message):
            diagnostics.log(
                .warning,
                category: .control,
                message: "peer_error_received",
                fields: [
                    "event": "peer_error_received",
                    "error_code": "\(code)",
                    "message_bytes": "\(message.utf8.count)"
                ]
            )
            onError?(message)
        case let .diagnosticsStart(sessionID, streamID, durationSeconds):
            guard (peerFeatures & ControlFeature.diagnosticsUpload) != 0,
                  activeDebugSessionID == nil,
                  pendingReportSessionID == nil else {
                throw PairingSecurityError.providerFailure(-9)
            }
            debugSessionDiagnostics.begin(
                sessionID: sessionID,
                streamID: streamID,
                durationSeconds: durationSeconds
            )
            activeDebugSessionID = sessionID
            activeDebugStreamID = streamID
            _ = diagnostics.logAsync(
                .info,
                category: .realtime,
                message: "debug_capture_armed",
                fields: [
                    "event": "debug_capture_armed",
                    "session_id": Self.hex(sessionID),
                    "stream_id": "\(streamID)",
                    "duration_seconds": "\(durationSeconds)"
                ]
            )
        case let .diagnosticsEnd(sessionID, reason):
            guard activeDebugSessionID == sessionID, activeDebugStreamID != nil else {
                throw PairingSecurityError.providerFailure(-10)
            }
            activeDebugStreamID = nil
            let endReason = reason == 1 ? "duration_expired" : "sender_reason_\(reason)"
            debugQueue.async { [weak self] in
                guard let self else { return }
                do {
                    _ = try self.debugSessionDiagnostics.finish(
                        reason: endReason,
                        diagnostics: self.diagnostics
                    )
                    guard let report = try self.debugReportTransfer.pendingReport(),
                          report.sessionID == sessionID else {
                        throw DebugReportTransferError.noPendingReport
                    }
                    let chunks = try self.debugReportTransfer.makeChunks()
                    self.beginReportUpload(report, chunks: chunks)
                } catch {
                    self.logDebugReportFailure(error, event: "final_report_prepare_failed")
                    self.onError?("Unable to prepare the diagnostic report")
                }
            }
        case let .diagnosticsReportReceived(sessionID):
            guard pendingReportSessionID == sessionID else {
                throw PairingSecurityError.providerFailure(-11)
            }
            debugQueue.async { [weak self] in
                guard let self else { return }
                do {
                    try self.debugReportTransfer.acknowledge(sessionID: sessionID)
                    self.pendingReportSessionID = nil
                    if self.activeDebugSessionID == sessionID {
                        self.activeDebugSessionID = nil
                        self.activeDebugStreamID = nil
                    }
                    self.sendReceiverReady()
                } catch {
                    self.logDebugReportFailure(error, event: "report_acknowledgement_failed")
                    self.onError?("Unable to confirm the diagnostic report")
                }
            }
        case .connectRequest, .pairSpakeB, .pairConfirmB,
             .authResponse, .startStreamAck, .receiverReady,
             .diagnosticsReportStart, .diagnosticsReportChunk,
             .diagnosticsReportEnd:
            throw PairingSecurityError.providerFailure(-4)
        }
    }

    private func beginReportUpload(_ report: PendingDiagnosticReport, chunks: [Data]) {
        guard report.data.count <= Int(UInt32.max),
              !chunks.isEmpty, chunks.count <= Int(UInt32.max) else {
            logDebugReportFailure(DebugReportTransferError.reportTooLarge,
                                  event: "report_upload_rejected")
            onError?("The diagnostic report is too large to send")
            return
        }
        pendingReportSessionID = report.sessionID
        send(
            .diagnosticsReportStart(
                sessionID: report.sessionID,
                formatVersion: report.formatVersion,
                totalBytes: UInt32(report.data.count),
                chunkCount: UInt32(chunks.count)
            ),
            completion: { [weak self] error in
                guard let self else { return }
                if let error {
                    self.logDebugReportFailure(error, event: "report_start_send_failed")
                    self.onError?("Unable to start the diagnostic report upload")
                    return
                }
                self.sendReportChunk(sessionID: report.sessionID, chunks: chunks, index: 0)
            }
        )
    }

    private func sendReportChunk(sessionID: Data, chunks: [Data], index: Int) {
        guard index < chunks.count else {
            send(.diagnosticsReportEnd(sessionID: sessionID), completion: { [weak self] error in
                guard let self, let error else { return }
                self.logDebugReportFailure(error, event: "report_end_send_failed")
                self.onError?("Unable to finish the diagnostic report upload")
            })
            return
        }
        send(
            .diagnosticsReportChunk(
                sessionID: sessionID,
                index: UInt32(index),
                bytes: chunks[index]
            ),
            completion: { [weak self] error in
                guard let self else { return }
                if let error {
                    self.logDebugReportFailure(error, event: "report_chunk_send_failed")
                    self.onError?("Unable to send the diagnostic report")
                    return
                }
                self.sendReportChunk(sessionID: sessionID, chunks: chunks, index: index + 1)
            }
        )
    }

    private func sendReceiverReady() {
        send(.receiverReady, completion: { [weak self] error in
            guard let self else { return }
            if let error {
                self.logDebugReportFailure(error, event: "receiver_ready_send_failed")
                self.onError?("Unable to resume the audio session")
                return
            }
            guard !self.receiverReadyNotified else { return }
            self.receiverReadyNotified = true
            self.onReady?()
        })
    }

    private func logDebugReportFailure(_ error: Error, event: String) {
        diagnostics.log(
            .error,
            category: .control,
            message: event,
            fields: ["event": event, "error_type": "\(type(of: error))"]
        )
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func handlePairSpakeA(_ peerPoint: Data) throws {
        guard (mode == .pair || mode == .oneTime),
              let pin,
              let windowsSPKIHash else {
            throw PairingSecurityError.invalidLength
        }
        let scalar = try PairingSecurity.pinScalar(pin)
        let identityA = try PairingSecurity.identityA(windowsSPKISHA256: windowsSPKIHash)
        let identityB = PairingSecurity.identityB()
        let exchange = try provider.begin(
            role: .receiverPartyB,
            scalar: scalar,
            identityA: identityA,
            identityB: identityB
        )
        let output = try exchange.finish(peerPoint: peerPoint)
        spakeOutput = output
        diagnostics.log(
            .info,
            category: .security,
            message: "pairing_spake_completed",
            fields: [
                "event": "pairing_spake_completed",
                "peer_point_bytes": "\(peerPoint.count)",
                "public_point_bytes": "\(exchange.publicPoint.count)"
            ]
        )
        send(.pairSpakeB(exchange.publicPoint))
    }
}
#endif
