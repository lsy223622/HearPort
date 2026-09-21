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
    private var decoder = ControlFrameDecoder()
    private var mode: AuthMode = .oneTime
    private var pin: String?
    private var credential: RememberedCredential?
    private var pendingCredential: RememberedCredential?
    private var windowsSPKIHash: Data?
    private var spakeOutput: Spake2Output?
    private var connectSent = false
    private var ready = false

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
        self.decoder = ControlFrameDecoder()
        self.spakeOutput = nil
        self.pendingCredential = nil
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
    }

    private func sendConnectIfPossible() {
        guard !connectSent else { return }
        guard mode == .remembered || (mode == .pair || mode == .oneTime) else { return }
        let peerID = credential?.peerID ?? Data()
        let envelope = ControlEnvelope(.connectRequest(authMode: mode, peerID: peerID))
        do {
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
            send(.pairConfirmB(output.confirmation))
        case let .pairCredential(peerID, pairSecret):
            guard mode == .pair, let windowsSPKIHash else {
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
            send(.authResponse(peerID: credential.peerID, mac: mac))
        case .sessionReady:
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
            guard receiver.markAuthenticated() else {
                throw PairingSecurityError.providerFailure(-2)
            }
            ready = true
            diagnostics.log(
                .info,
                category: .control,
                message: "session_ready",
                fields: ["event": "session_ready", "auth_mode": "\(mode)"]
            )
            onReady?()
        case let .startStream(streamID):
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
        case .connectRequest, .pairSpakeB, .pairConfirmB,
             .authResponse, .startStreamAck:
            throw PairingSecurityError.providerFailure(-4)
        }
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
