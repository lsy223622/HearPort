import Foundation

public struct ClockMapping: Sendable {
    private var remoteOrigin: UInt64?
    private var localOrigin: UInt64 = 0
    private var updatedAt: UInt64 = 0
    private var bestRoundTrip: UInt64 = .max
    private var localPerRemote = 1.0
    public private(set) var uncertaintyNanoseconds: UInt64 = 0

    public init() {}

    public mutating func observe(localSent: UInt64, remoteReceived: UInt64,
                                 remoteSent: UInt64, localReceived: UInt64) {
        guard localReceived >= localSent, remoteSent >= remoteReceived else { return }
        let elapsed = localReceived - localSent
        let remoteProcessing = remoteSent - remoteReceived
        guard elapsed >= remoteProcessing else { return }
        let roundTrip = elapsed - remoteProcessing
        guard roundTrip <= 500_000_000,
              bestRoundTrip == .max || roundTrip <= max(1_000_000, bestRoundTrip * 2)
        else { return }
        let local = localSent + elapsed / 2
        let remote = remoteReceived + remoteProcessing / 2
        if let previous = remoteOrigin, remote > previous, local > localOrigin,
           remote - previous >= 1_000_000_000 {
            let slope = Double(local - localOrigin) / Double(remote - previous)
            if (0.998...1.002).contains(slope) {
                localPerRemote += 0.1 * (slope - localPerRemote)
            }
        }
        remoteOrigin = remote
        localOrigin = local
        updatedAt = localReceived
        bestRoundTrip = min(bestRoundTrip, roundTrip)
        uncertaintyNanoseconds = (roundTrip + 1) / 2
    }

    public func map(remoteNanoseconds: UInt64, at now: UInt64) -> UInt64? {
        guard let remote = remoteOrigin, now >= updatedAt,
              now - updatedAt <= 5_000_000_000 else { return nil }
        let delta = remoteNanoseconds >= remote
            ? Double(remoteNanoseconds - remote) : -Double(remote - remoteNanoseconds)
        let mapped = Double(localOrigin) + delta * localPerRemote
        guard mapped >= 0, mapped < Double(UInt64.max) else { return nil }
        return UInt64(mapped.rounded())
    }

    public func remote(localNanoseconds: UInt64, at now: UInt64) -> UInt64? {
        guard let origin = remoteOrigin, now >= updatedAt,
              now - updatedAt <= 5_000_000_000 else { return nil }
        let delta = localNanoseconds >= localOrigin
            ? Double(localNanoseconds - localOrigin) : -Double(localOrigin - localNanoseconds)
        let timestamp = Double(origin) + delta / localPerRemote
        guard timestamp >= 0, timestamp < Double(UInt64.max) else { return nil }
        return UInt64(timestamp.rounded())
    }
}
