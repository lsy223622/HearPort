#if canImport(Network) && os(iOS)
import Foundation
import Network

public final class ReceiverControlSession {
    public let receiver: HearPortReceiver
    public let transport: HearPortQuicTransport

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
        transport: HearPortQuicTransport = HearPortQuicTransport(),
        provider: any Spake2Provider = UnavailableSpake2Provider(),
        keychain: KeychainRememberedCredentialStore = KeychainRememberedCredentialStore()
    ) {
        self.receiver = receiver
        self.transport = transport
        self.provider = provider
        self.keychain = keychain
        transport.onAudioDatagram = { [weak receiver] data in
            _ = receiver?.receiveDatagram(data)
        }
        transport.onControlData = { [weak self] data in
            self?.receiveControlBytes(data)
        }
        transport.onStateChange = { [weak self] state in
            guard let self else { return }
            self.onTransportState?(state)
            if state == .ready {
                self.sendConnectIfPossible()
            }
        }
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

        if mode == .remembered {
            do {
                credential = try rememberedCredential ?? keychain.load()
            } catch {
                onError?("Unable to load the remembered credential")
                return
            }
            guard let credential else {
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
            try transport.sendControl(envelope.encoded())
            connectSent = true
        } catch {
            onError?("Control stream is not available")
        }
    }

    private func receiveControlBytes(_ bytes: Data) {
        do {
            for frame in try decoder.append(bytes) {
                try handle(ControlEnvelope.decode(frame))
            }
        } catch {
            onError?("Malformed control message")
            transport.cancel()
        }
    }

    private func send(_ message: ControlMessage,
                      completion: @escaping @Sendable (NWError?) -> Void = { _ in }) {
        do {
            try transport.sendControl(ControlEnvelope(message).encoded(),
                                      completion: completion)
        } catch {
            onError?("Unable to write the control message")
        }
    }

    private func handle(_ envelope: ControlEnvelope) throws {
        switch envelope.message {
        case let .pairSpakeA(peerPoint):
            try handlePairSpakeA(peerPoint)
        case let .pairConfirmA(confirmation):
            guard let output = spakeOutput,
                  output.verifyPeerConfirmation(confirmation) else {
                throw PairingSecurityError.providerFailure(-1)
            }
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
        case let .authChallenge(nonce):
            guard mode == .remembered, let credential else {
                throw PairingSecurityError.invalidLength
            }
            let mac = try PairingSecurity.rememberedAuthMAC(
                pairSecret: credential.pairSecret,
                nonce: nonce,
                windowsSPKISHA256: credential.windowsSPKISHA256
            )
            send(.authResponse(peerID: credential.peerID, mac: mac))
        case .sessionReady:
            if mode == .pair, let pendingCredential {
                try keychain.save(pendingCredential)
                credential = pendingCredential
            }
            guard receiver.markAuthenticated() else {
                throw PairingSecurityError.providerFailure(-2)
            }
            ready = true
            onReady?()
        case let .startStream(streamID):
            guard receiver.beginStream(streamID) else {
                throw PairingSecurityError.providerFailure(-3)
            }
            send(.startStreamAck(streamID), completion: { [weak self] error in
                guard let self else { return }
                guard error == nil else {
                    self.onError?("Unable to write StartStreamAck")
                    return
                }
                _ = self.receiver.acknowledgeStartStream(streamID)
            })
        case let .error(_, message):
            onError?(message)
        case .connectRequest, .sessionReady, .pairSpakeB, .pairConfirmB,
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
        send(.pairSpakeB(exchange.publicPoint))
    }
}
#endif
