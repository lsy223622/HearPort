import Foundation

public struct ClockMapping: Sendable {
    private var remoteOrigin: UInt64?
    private var localOrigin: UInt64 = 0
    private var updatedAt: UInt64 = 0
    private var recentRoundTrips: [(at: UInt64, duration: UInt64)] = []
    private var localPerRemote = 1.0
    public private(set) var uncertaintyNanoseconds: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func observe(localSent: UInt64, remoteReceived: UInt64,
                                 remoteSent: UInt64, localReceived: UInt64) -> Bool {
        guard localReceived >= localSent, remoteSent >= remoteReceived,
              remoteOrigin == nil || localReceived >= updatedAt else { return false }
        let elapsed = localReceived - localSent
        let remoteProcessing = remoteSent - remoteReceived
        guard elapsed >= remoteProcessing else { return false }
        let roundTrip = elapsed - remoteProcessing
        guard roundTrip <= 500_000_000 else { return false }
        // Relearn a changed path before the mapping's 30-second holdover expires.
        recentRoundTrips.removeAll { localReceived >= $0.at && localReceived - $0.at > 10_000_000_000 }
        // Rejected valid exchanges still describe the current path's RTT floor.
        recentRoundTrips.append((localReceived, roundTrip))
        let bestRoundTrip = recentRoundTrips.map(\.duration).min()!
        guard roundTrip <= max(1_000_000, bestRoundTrip * 2) else { return false }
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
        // Remote processing duration also carries the permitted clock-rate error.
        uncertaintyNanoseconds = (roundTrip + 1) / 2 + UInt64(ceil(Double(remoteProcessing) * 0.001))
        return true
    }

    public func uncertainty(at now: UInt64, remoteNanoseconds: UInt64? = nil) -> UInt64 {
        guard let age = ageNanoseconds(at: now), age <= 30_000_000_000 else { return .max }
        let rateError = max(abs(localPerRemote / 0.998 - 1), abs(localPerRemote / 1.002 - 1))
        let distance = now >= localOrigin ? now - localOrigin : localOrigin - now
        var growth = rateError * (Double(distance) + Double(uncertaintyNanoseconds))
        if let timestamp = remoteNanoseconds, let origin = remoteOrigin {
            let sourceDistance = timestamp >= origin ? timestamp - origin : origin - timestamp
            growth = max(growth, max(abs(localPerRemote - 0.998), abs(localPerRemote - 1.002)) * Double(sourceDistance))
        }
        return uncertaintyNanoseconds + UInt64(ceil(growth))
    }

    func ageNanoseconds(at now: UInt64) -> UInt64? {
        guard remoteOrigin != nil else { return nil }
        return now >= updatedAt ? now - updatedAt : updatedAt - now
    }

    public func map(remoteNanoseconds: UInt64, at now: UInt64) -> UInt64? {
        guard let remote = remoteOrigin, let age = ageNanoseconds(at: now),
              age <= 30_000_000_000 else { return nil }
        let delta = remoteNanoseconds >= remote
            ? Double(remoteNanoseconds - remote) : -Double(remote - remoteNanoseconds)
        let mapped = Double(localOrigin) + delta * localPerRemote
        guard mapped >= 0, mapped < Double(UInt64.max) else { return nil }
        return UInt64(mapped.rounded())
    }

    public func remote(localNanoseconds: UInt64, at now: UInt64) -> UInt64? {
        guard let origin = remoteOrigin, let age = ageNanoseconds(at: now),
              age <= 30_000_000_000 else { return nil }
        let delta = localNanoseconds >= localOrigin
            ? Double(localNanoseconds - localOrigin) : -Double(localOrigin - localNanoseconds)
        let timestamp = Double(origin) + delta / localPerRemote
        guard timestamp >= 0, timestamp < Double(UInt64.max) else { return nil }
        return UInt64(timestamp.rounded())
    }
}
