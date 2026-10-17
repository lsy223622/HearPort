import Foundation

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

enum AudioLinkQuality: Int { case unknown, poor, variable, stable }

struct AudioLinkSample {
    let epoch: UInt64
    let time: TimeInterval
    let received, missing, late: Int
    let roundTripMilliseconds: Double?
    let interrupted: Bool
    var outputGapFrames: UInt64 = 0
}

/// UI observation only: counts describe packets unavailable to playout, not Wi-Fi loss.
struct AudioLinkQualityTracker {
    private(set) var quality: AudioLinkQuality = .unknown
    private(set) var missingRatio: Double?
    private(set) var lateRatio: Double?
    private var previous: AudioLinkSample?
    private struct Interval {
        let end: TimeInterval
        let received, missing, late: Int
        let interrupted: Bool
        let rtt: Double?
    }
    private var intervals: [Interval] = []
    private var startedAt: TimeInterval = 0
    private var improvementStartedAt: TimeInterval?
    private var improvingTo: AudioLinkQuality?

    mutating func observe(_ sample: AudioLinkSample) {
        guard let prior = previous, prior.epoch == sample.epoch,
              sample.time > prior.time, sample.time - prior.time <= 3,
              sample.received >= prior.received, sample.missing >= prior.missing,
              sample.late >= prior.late else {
            self = Self(); previous = sample; startedAt = sample.time; return
        }
        previous = sample
        // Initial buffer fill is not an observation of steady audio delivery.
        guard sample.time - startedAt >= 3 else {
            intervals.removeAll(); missingRatio = nil; lateRatio = nil; return
        }
        intervals.append(Interval(end: sample.time, received: sample.received - prior.received,
            missing: sample.missing - prior.missing, late: sample.late - prior.late,
            interrupted: sample.interrupted || sample.outputGapFrames > prior.outputGapFrames,
            rtt: sample.roundTripMilliseconds))
        intervals.removeAll { sample.time - $0.end >= 5 }
        let received = intervals.reduce(0) { $0 + $1.received }
        let missing = intervals.reduce(0) { $0 + $1.missing }
        let late = intervals.reduce(0) { $0 + $1.late }
        let total = received + missing
        missingRatio = total > 0 ? Double(missing) / Double(total) : nil
        lateRatio = received + late > 0 ? Double(late) / Double(received + late) : nil
        guard total + late > 0 else {
            quality = .unknown; startedAt = sample.time
            improvementStartedAt = nil; improvingTo = nil; return
        }
        let rtt = intervals.compactMap(\.rtt).max() ?? 0
        let unavailable = missingRatio ?? 0, delayed = lateRatio ?? 0
        let candidate: AudioLinkQuality
        if intervals.contains(where: { $0.interrupted }) || unavailable >= 0.01 || delayed >= 0.02 || rtt >= 150 {
            candidate = .poor
        } else if unavailable > 0.001 || delayed > 0.005 || rtt >= 80 {
            candidate = .variable
        } else { candidate = .stable }
        if quality == .unknown || candidate.rawValue <= quality.rawValue {
            quality = candidate; improvementStartedAt = nil; improvingTo = nil
        } else {
            if improvingTo != candidate { improvingTo = candidate; improvementStartedAt = sample.time }
            if let began = improvementStartedAt, sample.time - began >= 8 {
                quality = candidate; improvementStartedAt = nil; improvingTo = nil
            }
        }
    }
}
