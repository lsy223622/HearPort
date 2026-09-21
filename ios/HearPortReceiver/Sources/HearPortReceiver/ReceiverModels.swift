import Foundation

public enum AuthMode: UInt32, Equatable, Hashable, Sendable {
    case remembered = 1
    case pair = 2
    case oneTime = 3
}

public enum ReceiverPhase: Equatable, Sendable {
    case awaitingConnect
    case authenticating
    case ready
    case pendingStream
    case active
    case silentRebuffer
    case interrupted
    case closed
}

public enum AudioDisposition: Equatable, Sendable {
    case accepted
    case pendingAudioDiscarded
    case oldStreamDiscarded
}

public enum SequenceNumber {
    public static func isBefore(_ lhs: UInt32, _ rhs: UInt32) -> Bool {
        Int32(bitPattern: lhs &- rhs) < 0
    }

    public static func next(_ value: UInt32) -> UInt32 {
        value &+ 1
    }
}

public final class ReceiverSessionState {
    public private(set) var phase: ReceiverPhase = .awaitingConnect
    public private(set) var authMode: AuthMode?
    public private(set) var pendingStreamID: UInt32?
    public private(set) var activeStreamID: UInt32?

    @discardableResult
    public func receiveConnect(authMode: AuthMode, peerID: Data) -> Bool {
        guard phase == .awaitingConnect else {
            phase = .closed
            return false
        }
        if authMode == .remembered {
            guard peerID.count == 16 else {
                phase = .closed
                return false
            }
        } else if !peerID.isEmpty {
            phase = .closed
            return false
        }
        self.authMode = authMode
        phase = .authenticating
        return true
    }

    @discardableResult
    public func markAuthenticated() -> Bool {
        guard phase == .authenticating else { return false }
        phase = .ready
        return true
    }

    @discardableResult
    public func beginStream(_ streamID: UInt32) -> Bool {
        guard streamID != 0,
              phase == .ready || phase == .active || phase == .silentRebuffer else {
            return false
        }
        pendingStreamID = streamID
        activeStreamID = nil
        phase = .pendingStream
        return true
    }

    @discardableResult
    public func ackWritten(_ streamID: UInt32) -> Bool {
        guard phase == .pendingStream,
              pendingStreamID == streamID,
              streamID != 0 else {
            return false
        }
        pendingStreamID = nil
        activeStreamID = streamID
        phase = .active
        return true
    }

    public func acceptAudio(_ packet: AudioDatagram) -> AudioDisposition {
        if phase == .pendingStream {
            return packet.streamID == pendingStreamID
                ? .pendingAudioDiscarded
                : .oldStreamDiscarded
        }
        if (phase == .active || phase == .silentRebuffer),
           activeStreamID == packet.streamID {
            return .accepted
        }
        return .oldStreamDiscarded
    }

    public func enterSilentRebuffer() {
        guard phase == .active || phase == .ready else { return }
        phase = .silentRebuffer
    }

    public func enterInterruption() {
        guard phase != .closed else { return }
        phase = .interrupted
    }

    public func recoverToRebuffer() {
        guard phase == .interrupted else { return }
        phase = .silentRebuffer
    }

    public func close() {
        phase = .closed
        pendingStreamID = nil
        activeStreamID = nil
    }
}
