import Foundation

public final class HearPortReceiver {
    public let session = ReceiverSessionState()
    public let lifecycle = AudioLifecycleController()
    public private(set) var invalidDatagrams = 0

    private var jitter: JitterBuffer?
    private var renderRing: RenderRingBuffer
    private let lock = NSLock()

    public init(startupPackets: Int = 8, renderCapacityFrames: Int = 4_800) {
        precondition(startupPackets > 0)
        precondition(renderCapacityFrames > 0)
        renderRing = RenderRingBuffer(capacityFrames: renderCapacityFrames)
        startupPacketTarget = startupPackets
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
        guard session.beginStream(streamID) else { return false }
        jitter = JitterBuffer(streamID: streamID,
                              startupPackets: startupPacketTarget)
        renderRing.reset()
        return true
    }

    @discardableResult
    public func acknowledgeStartStream(_ streamID: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return session.ackWritten(streamID)
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
            return nil
        }
        guard session.acceptAudio(packet) == .accepted,
              var buffer = jitter else {
            return session.acceptAudio(packet)
        }
        _ = buffer.insert(packet)
        _ = buffer.startIfReady()
        jitter = buffer
        return .accepted
    }

    public func handleAudioLifecycle(_ event: AudioLifecycleEvent) {
        lock.lock()
        defer { lock.unlock() }
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
    }

    public func enterSilentRebuffer() {
        lock.lock()
        defer { lock.unlock() }
        jitter?.enterSilentRebuffer()
        session.enterSilentRebuffer()
        lifecycle.handle(.routeChanged)
        renderRing.reset()
    }

    public func renderFrames(_ frameCount: Int) -> [Float] {
        guard frameCount > 0 else { return [] }
        guard lock.try() else {
            return Array(repeating: 0, count: frameCount * 2)
        }
        defer { lock.unlock() }
        pumpLocked(minimumFrames: frameCount)
        if lifecycle.shouldRenderSilence {
            return Array(repeating: 0, count: frameCount * 2)
        }
        return renderRing.pop(frames: frameCount)
    }

    private func pumpLocked(minimumFrames: Int) {
        guard var buffer = jitter else { return }
        while renderRing.fillFrames < minimumFrames {
            guard let packet = buffer.consumeNext() else { break }
            renderRing.push(Self.decodePCM(packet.pcm))
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
}

#if canImport(Network)
import Network

public enum QuicReceiverState: Equatable, Sendable {
    case idle
    case connecting
    case ready
    case failed
    case closed
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
    private var group: NWConnectionGroup?
    private var controlStream: NWConnection?
    private var datagramFlow: NWConnection?

    public init() {}

    public func connect(host: String, port: UInt16 = defaultPort) {
        cancel()
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let parameters = NWParameters.quic(alpn: [Self.alpn])
        let multiplex = NWMultiplexGroup(to: endpoint)
        let connectionGroup = NWConnectionGroup(with: multiplex,
                                                 using: parameters)
        group = connectionGroup
        state = .connecting
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

    public func sendControl(_ payload: Data) throws {
        let framed = try ControlFraming.encode(payload)
        controlStream?.send(content: framed,
                            contentContext: .defaultMessage,
                            isComplete: true,
                            completion: .contentProcessed { _ in })
    }

    public func cancel() {
        controlStream?.cancel()
        datagramFlow?.cancel()
        group?.cancel()
        controlStream = nil
        datagramFlow = nil
        group = nil
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
            updateState(.failed)
            return
        }
        controlStream = control
        datagramFlow = datagram
        control.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.updateState(.failed) }
        }
        datagram.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.updateState(.failed) }
        }
        control.start(queue: queue)
        datagram.start(queue: queue)
        receiveControl(on: control)
        receiveDatagrams(on: datagram)
        updateState(.ready)
    }

    private func receiveControl(on stream: NWConnection) {
        stream.receive(minimumIncompleteLength: 1, maximumLength: 65_540) {
            [weak self] data, _, isComplete, error in
            if let data { self?.onControlData?(data) }
            guard error == nil, !isComplete else { return }
            self?.receiveControl(on: stream)
        }
    }

    private func receiveDatagrams(on flow: NWConnection) {
        flow.receiveMessage { [weak self] data, _, _, error in
            if let data { self?.onAudioDatagram?(data) }
            guard error == nil else { return }
            self?.receiveDatagrams(on: flow)
        }
    }

    private func updateState(_ newState: QuicReceiverState) {
        state = newState
        onStateChange?(newState)
    }
}
#endif
