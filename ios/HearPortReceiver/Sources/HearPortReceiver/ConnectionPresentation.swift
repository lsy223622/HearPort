import Foundation

func networkEndpointLabel(address: String, port: UInt16) -> String {
    "\(address.contains(":") ? "[\(address)]" : address):\(port)"
}

enum ConnectionPresentationStage {
    case idle, connecting, recovering, playing, testing, reporting, completed

    static func resolve(completed: Bool, reporting: Bool, recovering: Bool,
                        connecting: Bool, playing: Bool, testing: Bool) -> Self {
        if completed { return .completed }
        if reporting { return .reporting }
        if recovering { return .recovering }
        if connecting { return .connecting }
        if testing { return .testing }
        return playing ? .playing : .idle
    }
}

enum LinkStability: Int { case unknown, poor, variable, stable }

struct LinkTimingSample {
    let epoch: UInt64
    let time: TimeInterval
    let roundTripMilliseconds: Double?
    let roundTripObservedAt: UInt64?
}

struct LinkStabilityTracker {
    private(set) var quality: LinkStability = .unknown
    private(set) var variationMilliseconds: Double?
    var sampleCount: Int { observations.count }
    private var epoch: UInt64?
    private var lastPollAt: TimeInterval?
    private var startedAt: TimeInterval = 0
    private var newestObservation: UInt64?
    private var observations: [(at: UInt64, milliseconds: Double)] = []
    private var improvementStartedAt: TimeInterval?
    private var improvingTo: LinkStability?

    mutating func observe(_ sample: LinkTimingSample) {
        if epoch != sample.epoch || lastPollAt.map({ sample.time < $0 || sample.time - $0 > 3 }) == true {
            self = Self(); epoch = sample.epoch; startedAt = sample.time
        }
        lastPollAt = sample.time
        if let at = sample.roundTripObservedAt, let rtt = sample.roundTripMilliseconds,
           rtt.isFinite, rtt >= 0, Double(at) / 1_000_000_000 <= sample.time,
           sample.time - Double(at) / 1_000_000_000 <= 6,
           newestObservation.map({ at > $0 }) ?? true {
            observations.append((at, rtt)); newestObservation = at
        }
        // At one probe every two seconds, retain roughly six independent exchanges.
        observations.removeAll { sample.time - Double($0.at) / 1_000_000_000 > 12 }
        let lastResponse = newestObservation ?? sample.roundTripObservedAt
        let lastResponseTime = lastResponse.map { Double($0) / 1_000_000_000 } ?? startedAt
        if sample.time - lastResponseTime > 6 {
            quality = .poor; variationMilliseconds = nil
            improvementStartedAt = nil; improvingTo = nil; return
        }
        guard observations.count >= 3, let first = observations.first, let last = observations.last,
              last.at - first.at >= 4_000_000_000 else {
            variationMilliseconds = nil
            if quality != .poor { quality = .unknown }
            return
        }
        let sorted = observations.map(\.milliseconds).sorted()
        let spread = percentile(sorted, fraction: 0.9) - percentile(sorted, fraction: 0.1)
        variationMilliseconds = spread
        // Absolute milliseconds: 5 -> 10 ms remains within the stable band.
        let candidate: LinkStability = spread <= 10 ? .stable : spread <= 30 ? .variable : .poor
        if quality == .unknown || candidate.rawValue <= quality.rawValue {
            quality = candidate; improvementStartedAt = nil; improvingTo = nil
        } else {
            if improvingTo != candidate { improvingTo = candidate; improvementStartedAt = sample.time }
            if let began = improvementStartedAt, sample.time - began >= 8 {
                quality = candidate; improvementStartedAt = nil; improvingTo = nil
            }
        }
    }

    private func percentile(_ sorted: [Double], fraction: Double) -> Double {
        let position = Double(sorted.count - 1) * fraction
        let lower = Int(position), upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }
}
