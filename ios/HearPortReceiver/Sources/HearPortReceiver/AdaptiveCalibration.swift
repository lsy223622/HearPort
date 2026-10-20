import Foundation

struct AdaptiveParameters: Codable, Equatable, Sendable {
    var reliable: Bool
    var format: AudioStreamFormat
    var budget: CalibrationBudget
    var reserve: Int
    var choice: CalibrationChoice {
        CalibrationChoice(profileMask: 0, reliable: reliable, budget: budget, outputReserve: reserve)
    }
}

struct AdaptiveObservation: Codable, Sendable {
    let parameters: AdaptiveParameters
    let measurement: CalibrationMeasurement
    let validation: Bool
}

struct AdaptiveCalibrationResult: Codable, Sendable {
    let testedAt: Date
    let goal: Int
    let maximum: Int
    let observations: [AdaptiveObservation]
    let selected: AdaptiveParameters?
    let complete: Bool
    static let storageKey = "hearport.adaptiveCalibration.v1"

    var validation: [CalibrationMeasurement] {
        observations.filter { $0.validation && $0.parameters == selected }.map(\.measurement)
    }
    var canApply: Bool {
        guard complete, [1,2,4].contains(goal), let p = selected,
              (try? AudioStreamFormat(opus: p.format.opus, bitrate: p.format.bitrate,
                frameCount: p.format.frameCount)) == p.format,
              p.budget.maximum <= maximum, p.budget.target > p.reserve,
              p.budget.target + 5 <= p.budget.maximum, validation.count == 2 else { return false }
        return validation.allSatisfy { $0.valid && AdaptiveCalibrationSearch.meets($0, goal: goal) }
    }
    func save(to defaults: UserDefaults = .standard) {
        if canApply, let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey) }
    }
    static func load(from defaults: UserDefaults = .standard) -> Self? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    @discardableResult func apply(to defaults: UserDefaults = .standard) -> Bool {
        guard canApply, let p = selected else { return false }
        defaults.set(p.reliable ? AudioTransportMode.reliable.rawValue : AudioTransportMode.datagram.rawValue,
                     forKey: "hearport.audioTransportMode")
        defaults.set(p.budget.target, forKey: "hearport.targetLatencyMs")
        defaults.set(p.budget.maximum, forKey: "hearport.maximumLatencyMs")
        defaults.set(p.format.opus ? "opus" : "pcm", forKey: "hearport.networkAudio.codec")
        if p.format.opus {
            defaults.set(p.format.bitrate, forKey: "hearport.networkAudio.bitrate")
            defaults.set(p.format.frameCount, forKey: "hearport.networkAudio.frames")
        }
        return true
    }
}

/// Sequential observations cannot establish causation. Every candidate is repeated;
/// transport baselines use ABBA, and the selected settings receive two longer repeats.
struct AdaptiveCalibrationSearch: Sendable {
    let goal: Int
    let maximum: Int
    let reserve: Int
    private(set) var observations: [AdaptiveObservation] = []
    private(set) var selected: AdaptiveParameters?
    private(set) var validating = false
    private var initial: AdaptiveParameters {
        let cap = min(maximum, goal == 1 ? 80 : goal == 2 ? 150 : maximum)
        return parameters(reliable: false, format: try! AudioStreamFormat(opus: true), cap: cap)
    }
    private func parameters(reliable: Bool, format: AudioStreamFormat, cap: Int) -> AdaptiveParameters {
        let floor = reserve + 20
        let cap = min(maximum, max(floor, cap))
        let target = min(cap - 5, max(reserve + 5, ((cap * (goal == 1 ? 5 : 7) / 10) / 5) * 5))
        return AdaptiveParameters(reliable: reliable, format: format,
            budget: CalibrationBudget(target: target, maximum: cap), reserve: reserve)
    }
    static func meets(_ m: CalibrationMeasurement, goal: Int) -> Bool {
        m.valid && m.gapRatio <= (goal == 1 ? 0.005 : goal == 2 ? 0.001 : 0.0001) &&
            m.longestGapMilliseconds <= (goal == 1 ? 40 : goal == 2 ? 20 : 10)
    }
    mutating func record(_ p: AdaptiveParameters, measurement: CalibrationMeasurement, validation: Bool) {
        observations.append(AdaptiveObservation(parameters: p, measurement: measurement, validation: validation))
    }
    private func samples(_ p: AdaptiveParameters) -> [CalibrationMeasurement] {
        observations.filter { !$0.validation && $0.parameters == p }.map(\.measurement)
    }
    private func qualifies(_ p: AdaptiveParameters) -> Bool {
        let rows = samples(p)
        return rows.count >= 2 && rows.allSatisfy { Self.meets($0, goal: goal) }
    }
    private func worst(_ p: AdaptiveParameters) -> (Double, Double, Double) {
        let rows = samples(p)
        return (rows.map(\.gapRatio).max() ?? 1, rows.map(\.longestGapMilliseconds).max() ?? .infinity,
                rows.compactMap(\.ageP95Milliseconds).max() ?? .infinity)
    }
    private func best() -> AdaptiveParameters? {
        let candidates = observations.filter { !$0.validation && $0.measurement.valid }.map(\.parameters)
        return candidates.filter { samples($0).count >= 2 && samples($0).allSatisfy(\.valid) }.min {
            let a = worst($0), b = worst($1)
            if qualifies($0) != qualifies($1) { return qualifies($0) }
            if qualifies($0) && goal != 4 { return a.2 < b.2 }
            return a < b
        }
    }
    mutating func next() -> AdaptiveParameters? {
        if validating {
            guard let selected, observations.filter({ $0.validation }).count < 2 else { return nil }
            return selected
        }
        let explored = observations.filter { !$0.validation }
        if explored.count < 4 {
            var p = initial; p.reliable = [false,true,true,false][explored.count]; return p
        }
        // Repeat each changed setting before using it to guide the next step.
        if let last = explored.last, samples(last.parameters).count < 2 { return last.parameters }
        guard let best = best() else { return nil }
        let base = qualifies(best) ? best : explored.last!.parameters
        var next = base
        let passing = qualifies(best)
        if !passing {
            let ratio = worst(base).0 / (goal == 1 ? 0.005 : goal == 2 ? 0.001 : 0.0001)
            if base.format.opus && (base.format.bitrate != 192_000 || base.format.frameCount != 480) {
                next.format = try! AudioStreamFormat(opus: true, bitrate: 192_000,
                    frameCount: ratio > 4 ? 480 : min(480, base.format.frameCount * 2))
            } else {
                let step = ratio > 4 ? max(20, (maximum - base.budget.maximum) / 2) : 10
                next = parameters(reliable: base.reliable, format: base.format, cap: base.budget.maximum + step)
            }
        } else {
            let tried = explored.map(\.parameters)
            let shorter = try! AudioStreamFormat(opus: true, bitrate: 256_000, frameCount: 120)
            var alternative = best; alternative.format = shorter
            var pcm = best; pcm.format = .pcm
            if !tried.contains(alternative) { next = alternative }
            else if worst(best).0 == 0 && !tried.contains(pcm) { next = pcm }
            else {
                let failed = explored.filter { !Self.meets($0.measurement, goal: goal) &&
                    $0.parameters.reliable == best.reliable && $0.parameters.format == best.format &&
                    $0.parameters.budget.maximum < best.budget.maximum }.map { $0.parameters.budget.maximum }.max() ?? (reserve + 20)
                next = parameters(reliable: best.reliable, format: best.format,
                    cap: best.budget.maximum - max(5, (best.budget.maximum - failed) / 2 / 5 * 5))
            }
        }
        if explored.count >= 12 || explored.contains(where: { $0.parameters == next }) {
            selected = best; validating = true; return best
        }
        return next
    }
}

/// Only transport-shaped random bytes are sent. Codec preparation is reserved in
/// the deadline; these measurements do not claim to benchmark the iPad decoder.
final class AdaptiveCalibrationSession: @unchecked Sendable {
    let setup: CalibrationMessage
    private let lock = NSLock()
    private var search: AdaptiveCalibrationSearch
    private var current: CalibrationRoundTrace?
    private var parameters: AdaptiveParameters?
    private var consumer: ProbeConsumer?
    private var cancelled = false
    private var began: UInt64 = 0
    private var received = 0
    private var playedFrames: UInt64 = 0, missingFrames: UInt64 = 0
    private var longestLiveGap = 0.0, liveRun = 0.0
    private var liveGapEnd: UInt64?
    private var expected: AdaptiveParameters?
    private var expectedValidation = false

    init(setup: CalibrationMessage, reserve: Int) {
        self.setup = setup
        search = AdaptiveCalibrationSearch(goal: setup.goal, maximum: setup.budget.maximum, reserve: reserve)
    }
    var outputReserve: Int { search.reserve }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func next(at: UInt64) -> CalibrationMessage {
        lock.lock(); defer { lock.unlock() }
        if var trace = current, let parameters {
            trace.endAt = at
            search.record(parameters, measurement: CalibrationReplay.evaluate(trace: trace, budget: trace.round.budget),
                          validation: trace.round.phase == 1)
        }
        current = nil; consumer = nil; parameters = nil
        var m = CalibrationMessage(kind: .selection, planID: setup.planID); m.goal = setup.goal
        guard !cancelled, let next = search.next() else { expected = nil; return m }
        expected = next; expectedValidation = search.validating
        var choice = next.choice; choice.profileMask = setup.goal
        m.choices = [choice]; m.format = next.format; m.phase = search.validating ? 1 : 0
        return m
    }
    func begin(_ round: CalibrationMessage, at: UInt64) throws -> CalibrationMessage {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, let expected, current == nil, round.goal == setup.goal,
              round.planID == setup.planID, round.index == search.observations.count + 1,
              round.phase == (expectedValidation ? 1 : 0), round.format == expected.format,
              round.reliable == expected.reliable, round.budget == expected.budget,
              round.outputReserve == expected.reserve,
              round.seconds == setup.seconds * (expectedValidation ? 2 : 1),
              round.firstSequence == UInt32(round.index - 1) * UInt32(setup.seconds * 800) else { throw ControlMessageError.invalidMessage }
        parameters = expected; self.expected = nil
        current = CalibrationRoundTrace(round: round, packets: [], ticks: [], endAt: at)
        began = 0; received = 0; playedFrames = 0; missingFrames = 0
        longestLiveGap = 0; liveRun = 0; liveGapEnd = nil
        let budget = try PlayoutBudget(targetMilliseconds: Double(round.budget.target), maximumMilliseconds: Double(round.budget.maximum),
            outputReserveMilliseconds: Double(round.outputReserve))
        let spec = CoordinatedProbePlan.Round(payloadBytes: 992, packetsPerSecond: 400, burstPackets: 1, variant: 1,
            reliable: round.reliable, repeatIndex: 1, controller: 2, repair: 0, correctionPercent: 5)
        consumer = ProbeConsumer(round: spec, budget: budget, firstSequence: round.firstSequence,
            sourceFrame: round.firstSourceFrame, durationSeconds: round.seconds)
        var ack = CalibrationMessage(kind: .ack, planID: setup.planID)
        ack.goal = setup.goal; ack.phase = round.phase; ack.index = round.index
        return ack
    }
    func receive(_ record: TimedAudioRecord, captured: UInt64?, uncertainty: UInt64, at: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, let round = current?.round, let p = parameters,
              record.streamID == setup.planID, record.kind == .probe,
              record.generation >= round.generation, Int(record.frameCount) == p.format.frameCount,
              record.sequence >= round.firstSequence,
              UInt64(record.sequence - round.firstSequence) + UInt64(record.frameCount / 120) <= UInt64(round.seconds * 400),
              (record.sequence - round.firstSequence).isMultiple(of: UInt32(record.frameCount / 120)),
              record.sourceFrame == UInt64(record.sequence) * 120 else { return }
        guard let capture = captured, capture <= at || capture - at <= uncertainty else { current!.clockValid = false; return }
        guard current!.packets.count + Int(record.frameCount / 120) <= 100_000 else { current!.complete = false; return }
        if began == 0 { began = at }
        received += 1
        let processed = at + (p.format.opus ? 2_000_000 : 0)
        for slice in 0..<Int(record.frameCount / 120) {
            let source = record.sourceFrame + UInt64(slice * 120)
            let packet = CalibrationPacket(receivedAt: at, capturedAt: capture + UInt64(slice) * 2_500_000,
                uncertainty: uncertainty, sequence: record.sequence + UInt32(slice), generation: record.generation,
                sourceFrame: source, processedAt: processed)
            current!.packets.append(packet)
            // The replay and live feedback use identical logical source units.
            if let logical = try? TimedAudioRecord(streamID: record.streamID, generation: record.generation,
                sequence: packet.sequence, frameCount: 120, kind: .probe, capturedAt: packet.capturedAt,
                sourceFrame: source, payload: Data(repeating: 0, count: 960)) {
                consumer?.receive(logical, capturedAt: packet.capturedAt, uncertainty: uncertainty, now: processed)
            }
        }
    }
    func tick(at: UInt64, uncertainty: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, current != nil else { return }
        if current!.ticks.count < 100_000 { current!.ticks.append(CalibrationTick(at: at, uncertainty: uncertainty)) }
        else { current!.complete = false }
        consumer?.updateUncertainty(uncertainty)
        if let result = consumer?.tick(now: at) {
            playedFrames += UInt64(result.playedFrames + result.concealedFrames)
            missingFrames += UInt64(result.concealedFrames)
            for range in result.missingSource {
                liveRun = liveGapEnd == range.lowerBound ? liveRun + Double(range.count) / 48 : Double(range.count) / 48
                liveGapEnd = range.upperBound; longestLiveGap = max(longestLiveGap, liveRun)
            }
        }
    }
    func feedback() -> (sequence: UInt32?, played: UInt64?, buffered: UInt32)? {
        lock.lock(); defer { lock.unlock() }
        guard let consumer else { return nil }
        return (consumer.latestReceivedSequence, consumer.playedSourceFrame, UInt32(consumer.bufferedFrames / 48))
    }
    func progress() -> CalibrationProgressSnapshot {
        lock.lock(); defer { lock.unlock() }
        let round = current?.round
        var p = CalibrationProgressSnapshot(stage: "adaptive", index: round?.index ?? search.observations.count,
            count: 16, completed: search.observations.count, total: 0,
            seconds: round?.seconds ?? setup.seconds, roundStartedAt: began)
        p.adaptive = true; p.validating = search.validating; p.parameters = parameters
        p.lastGapRatio = search.observations.last?.measurement.gapRatio
        p.lastLongestGap = search.observations.last?.measurement.longestGapMilliseconds
        p.receivedPackets = received
        p.liveGapRatio = playedFrames > 0 ? Double(missingFrames) / Double(playedFrames) : nil
        p.liveLongestGap = longestLiveGap
        let observed = search.observations.count
        let verified = search.observations.filter(\.validation).count
        p.minimumWindows = search.validating ? max(0, 2 - verified) : max(0, 4 - observed) + 2
        p.maximumWindows = search.validating ? max(0, 2 - verified) : max(0, 12 - observed) + 2
        p.validationIndex = verified + 1
        return p
    }
    func result(complete: Bool) -> AdaptiveCalibrationResult {
        lock.lock(); defer { lock.unlock() }
        return AdaptiveCalibrationResult(testedAt: Date(), goal: setup.goal, maximum: setup.budget.maximum,
            observations: search.observations, selected: search.selected, complete: complete && !cancelled)
    }
}
