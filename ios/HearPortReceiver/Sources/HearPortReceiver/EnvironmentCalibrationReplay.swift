import Foundation
import CryptoKit

struct CalibrationPacket: Sendable {
    var receivedAt: UInt64
    let capturedAt: UInt64
    let uncertainty: UInt64
    let sequence: UInt32
    let generation: UInt32
    let sourceFrame: UInt64
    var processedAt: UInt64 = 0
    var kind: AudioRecordKind = .probe
    var availableAt: UInt64 { max(receivedAt, processedAt) }
}

struct CalibrationTick: Sendable {
    let at: UInt64
    let uncertainty: UInt64
}

struct CalibrationRoundTrace: Sendable {
    let round: CalibrationMessage
    var packets: [CalibrationPacket]
    var ticks: [CalibrationTick]
    var endAt: UInt64
    var complete = true
    var clockValid = true

    var captureStart: UInt64? {
        guard let first = packets.min(by: { $0.availableAt < $1.availableAt }),
              first.sourceFrame >= round.firstSourceFrame else { return nil }
        let offset = (first.sourceFrame - round.firstSourceFrame) * 1_000_000_000 / 48_000
        return first.capturedAt >= offset ? first.capturedAt - offset : nil
    }

    var observableFrames: UInt64 {
        guard let start = captureStart else { return 0 }
        let reserve = UInt64(round.budget.maximum) * 1_000_000
        guard endAt > start, endAt - start > reserve else { return 0 }
        return min(UInt64(round.seconds) * 48_000, (endAt - start - reserve) * 48_000 / 1_000_000_000) / 120 * 120
    }

    var fingerprint: String {
        var hash = SHA256()
        func add(_ values: [UInt64]) {
            var bytes: [UInt8] = []
            for value in values {
                for shift in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
            }
            hash.update(data: Data(bytes))
        }
        add([UInt64(round.index), UInt64(round.seconds), endAt, complete ? 1 : 0, clockValid ? 1 : 0])
        for p in packets { add([p.receivedAt,p.processedAt,p.capturedAt,p.uncertainty,UInt64(p.sequence),UInt64(p.generation),p.sourceFrame,UInt64(p.kind.rawValue)]) }
        for t in ticks { add([t.at,t.uncertainty]) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct CalibrationCoveragePoint: Codable, Sendable {
    let round: Int
    let reliable: Bool
    let maximumMilliseconds: Int
    let inputFingerprint: String
    let observableFrames, unavailableSourceFrames: UInt64
    let longestGapMilliseconds: Double
}

struct CalibrationBlock: Codable, Equatable, Sendable {
    var sourceFrames: UInt64 = 0
    var missingSourceFrames: UInt64 = 0
    var outputSeconds = 0.0
    var missingOutputSeconds = 0.0
    var gapRatio: Double {
        max(sourceFrames > 0 ? Double(missingSourceFrames) / Double(sourceFrames) : 0,
            outputSeconds > 0 ? missingOutputSeconds / outputSeconds : 0)
    }
}

struct CalibrationMeasurement: Codable, Sendable {
    let round: Int
    let reliable: Bool
    let budget: CalibrationBudget
    let outputReserve: Int
    var inputFingerprint: String
    var complete = false
    var clockValid = false
    var sampleCount = 1
    var sourceFrames: UInt64 = 0
    var missingSourceFrames: UInt64 = 0
    var outputSeconds = 0.0, missingOutputSeconds = 0.0
    var longestSourceGapMilliseconds = 0.0, longestOutputGapMilliseconds = 0.0
    var startupMilliseconds = 0.0
    var ageP50Milliseconds: Double?
    var ageP95Milliseconds: Double?
    var maximumAgeMilliseconds: Double?
    var maximumCorrection = 0.0, correctionSeconds = 0.0
    var blocks: [CalibrationBlock] = []
    var ages: [Double] = []

    enum CodingKeys: String, CodingKey {
        case round, reliable, budget, outputReserve, inputFingerprint, complete, clockValid, sampleCount
        case sourceFrames, missingSourceFrames, outputSeconds, missingOutputSeconds
        case longestSourceGapMilliseconds, longestOutputGapMilliseconds, startupMilliseconds
        case ageP50Milliseconds, ageP95Milliseconds, maximumAgeMilliseconds, maximumCorrection, correctionSeconds, blocks
    }
    var valid: Bool { complete && clockValid && sourceFrames > 0 && ageP95Milliseconds != nil }
    var gapRatio: Double {
        max(sourceFrames > 0 ? Double(missingSourceFrames) / Double(sourceFrames) : 1,
            outputSeconds > 0 ? missingOutputSeconds / outputSeconds : 1)
    }
    var longestGapMilliseconds: Double { max(longestSourceGapMilliseconds, longestOutputGapMilliseconds) }
}

struct CalibrationRecommendation: Codable, Sendable {
    let profile: Int
    let choice: CalibrationChoice?
    let measurement: CalibrationMeasurement?
    let metGoal: Bool
}

struct CalibrationPairedRange: Codable, Sendable {
    let reliable: Bool
    let budget, referenceBudget: CalibrationBudget
    let lowerDifference, upperDifference: Double
}

struct CalibrationAnalysis: Codable, Sendable {
    let measurements: [CalibrationMeasurement]
    let candidates: [CalibrationMeasurement]
    let coverage: [CalibrationCoveragePoint]
    let recommendations: [CalibrationRecommendation]
    let pairedRanges: [CalibrationPairedRange]
}

enum CalibrationReplay {
    static func coverage(trace: CalibrationRoundTrace, maximum: Int) -> CalibrationCoveragePoint {
        let count = Int(trace.observableFrames / 120)
        var available = [Bool](repeating: false, count: count)
        for p in trace.packets where p.sourceFrame >= trace.round.firstSourceFrame {
            let index = Int((p.sourceFrame - trace.round.firstSourceFrame) / 120)
            guard index < count else { continue }
            let remaining = max(0, maximum - trace.round.outputReserve) * 1_000_000
            guard UInt64(remaining) > p.uncertainty else { continue }
            if p.availableAt <= p.capturedAt + UInt64(remaining) - p.uncertainty { available[index] = true }
        }
        var missing = 0, run = 0, longest = 0
        for value in available {
            if value { run = 0 } else { missing += 1; run += 1; longest = max(longest, run) }
        }
        return CalibrationCoveragePoint(round: trace.round.index, reliable: trace.round.reliable,
            maximumMilliseconds: maximum, inputFingerprint: trace.fingerprint, observableFrames: UInt64(count) * 120,
            unavailableSourceFrames: UInt64(missing) * 120, longestGapMilliseconds: Double(longest) * 2.5)
    }

    static func evaluate(trace: CalibrationRoundTrace, budget: CalibrationBudget) -> CalibrationMeasurement {
        var m = CalibrationMeasurement(round: trace.round.index, reliable: trace.round.reliable,
            budget: budget, outputReserve: trace.round.outputReserve, inputFingerprint: trace.fingerprint)
        m.clockValid = trace.clockValid
        m.complete = trace.complete && trace.observableFrames == UInt64(trace.round.seconds) * 48_000
        let firstSource = trace.round.firstSourceFrame
        let sourceEnd = firstSource + trace.observableFrames
        guard let start = trace.captureStart, sourceEnd > firstSource,
              let playout = try? PlayoutBudget(targetMilliseconds: Double(budget.target), maximumMilliseconds: Double(budget.maximum),
                                              outputReserveMilliseconds: Double(trace.round.outputReserve)) else { return m }
        let spec = CoordinatedProbePlan.Round(payloadBytes: 992, packetsPerSecond: 400, burstPackets: 1, variant: 1,
            reliable: trace.round.reliable, repeatIndex: 1, controller: 2, repair: 0, correctionPercent: 5)
        var consumer = ProbeConsumer(round: spec, budget: playout, firstSequence: trace.round.firstSequence,
            sourceFrame: firstSource, durationSeconds: trace.round.seconds, sourceFrameLimit: sourceEnd)
        let packets = trace.packets.enumerated().sorted {
            $0.element.availableAt == $1.element.availableAt ? $0.offset < $1.offset : $0.element.availableAt < $1.element.availableAt
        }.map(\.element)
        let payload = Data(repeating: 0, count: 960)
        var next = 0, previousSource = firstSource, started = false
        var previousAt = start
        var gapEnd: UInt64?, sourceRun: UInt64 = 0
        var outputGapEnd: Double?, outputRun = 0.0
        m.blocks = [CalibrationBlock](repeating: CalibrationBlock(), count: max(1, (trace.round.seconds + 4) / 5))
        func sourceBlocks(_ range: Range<UInt64>, missing: Bool) {
            var lower = range.lowerBound
            while lower < range.upperBound {
                let block = min(m.blocks.count - 1, Int((lower - firstSource) / 240_000))
                let upper = min(range.upperBound, firstSource + UInt64(block + 1) * 240_000)
                guard upper > lower else { break }
                if missing { m.blocks[block].missingSourceFrames += upper - lower }
                else { m.blocks[block].sourceFrames += upper - lower }
                lower = upper
            }
        }
        for tick in trace.ticks.sorted(by: { $0.at < $1.at }) where tick.at >= start && tick.at <= trace.endAt {
            while next < packets.count && packets[next].availableAt <= tick.at {
                let p = packets[next]; next += 1
                guard p.sourceFrame >= firstSource, p.sourceFrame < sourceEnd,
                      let record = try? TimedAudioRecord(streamID: 1, generation: p.generation, sequence: p.sequence,
                        frameCount: 120, kind: p.kind, capturedAt: p.capturedAt, sourceFrame: p.sourceFrame, payload: payload) else { continue }
                consumer.receive(record, capturedAt: p.capturedAt, uncertainty: p.uncertainty, now: p.receivedAt)
            }
            consumer.updateUncertainty(tick.uncertainty)
            let result = consumer.tick(now: tick.at)
            let cursor = min(sourceEnd, consumer.playedSourceFrame ?? previousSource)
            let frames = result.playedFrames + result.concealedFrames
            if !started && frames > 0 {
                started = true
                m.startupMilliseconds = Double(tick.at - start) / 1e6
                previousSource = min(cursor, previousSource + result.skippedFrames)
            }
            defer { previousSource = cursor; previousAt = tick.at }
            guard started else { continue }
            if cursor > previousSource {
                m.sourceFrames += cursor - previousSource
                sourceBlocks(previousSource..<cursor, missing: false)
                for range in result.missingSource {
                    let lo = max(previousSource, range.lowerBound), hi = min(cursor, range.upperBound)
                    guard hi > lo else { continue }
                    m.missingSourceFrames += hi - lo
                    sourceBlocks(lo..<hi, missing: true)
                    sourceRun = gapEnd == lo ? sourceRun + hi - lo : hi - lo
                    gapEnd = hi
                    m.longestSourceGapMilliseconds = max(m.longestSourceGapMilliseconds, Double(sourceRun) / 48)
                }
            }
            let elapsed = tick.at >= previousAt ? Double(tick.at - previousAt) / 1e9 : 0
            let duration = frames > 0 ? min(elapsed, Double(frames) / (48_000 * (1 + result.correction))) :
                (result.waitingFrames > 0 ? elapsed : 0)
            let block = min(m.blocks.count - 1, Int((tick.at - start) / 5_000_000_000))
            m.outputSeconds += duration; m.blocks[block].outputSeconds += duration
            let at = Double(previousAt - start) / 1e9
            for range in result.missingOutput where duration > 0 {
                let lo = at + range.lowerBound * duration, hi = at + range.upperBound * duration
                m.missingOutputSeconds += hi - lo; m.blocks[block].missingOutputSeconds += hi - lo
                outputRun = outputGapEnd.map { abs($0 - lo) < 0.000001 } == true ? outputRun + hi - lo : hi - lo
                outputGapEnd = hi
                m.longestOutputGapMilliseconds = max(m.longestOutputGapMilliseconds, outputRun * 1000)
            }
            if let age = result.sourceAgeMilliseconds {
                m.ages.append(age + Double(trace.round.outputReserve) + Double(tick.uncertainty) / 1e6)
            }
            m.maximumCorrection = max(m.maximumCorrection, abs(result.correction))
            if abs(result.correction) > 0.00001 { m.correctionSeconds += duration }
        }
        setAges(&m)
        return m
    }

    static func analyze(traces: [CalibrationRoundTrace], maximum: Int,
                        progress: (Int, Int) -> Void, cancelled: () -> Bool) throws -> CalibrationAnalysis {
        let candidates = traces.map { calibrationBudgets(maximum: maximum, outputReserve: $0.round.outputReserve) }
        let total = candidates.reduce(0) { $0 + $1.count }
        var measurements: [CalibrationMeasurement] = [], curves: [CalibrationCoveragePoint] = []
        for (index, trace) in traces.enumerated() {
            for maximum in Set(candidates[index].map(\.maximum)).sorted() {
                curves.append(coverage(trace: trace, maximum: maximum))
            }
            for budget in candidates[index] {
                if cancelled() { throw CancellationError() }
                measurements.append(evaluate(trace: trace, budget: budget))
                progress(measurements.count, total)
            }
        }
        let aggregated = CalibrationSelector.aggregate(measurements)
        return CalibrationAnalysis(measurements: measurements, candidates: aggregated, coverage: curves,
            recommendations: CalibrationSelector.select(measurements: aggregated),
            pairedRanges: pairedRanges(measurements))
    }

    static func setAges(_ m: inout CalibrationMeasurement) {
        let values = m.ages.sorted()
        guard !values.isEmpty else { return }
        m.ageP50Milliseconds = values[Int(Double(values.count - 1) * 0.5)]
        m.ageP95Milliseconds = values[Int(Double(values.count - 1) * 0.95)]
        m.maximumAgeMilliseconds = values.last
    }

    private static func pairedRanges(_ rows: [CalibrationMeasurement]) -> [CalibrationPairedRange] {
        var result: [CalibrationPairedRange] = []
        for mode in [false,true] {
            let modes = rows.filter { $0.reliable == mode && $0.valid }
            guard let reference = modes.max(by: { ($0.budget.maximum,$0.budget.target) < ($1.budget.maximum,$1.budget.target) }) else { continue }
            for budget in Set(modes.map(\.budget)).sorted(by: { ($0.maximum,$0.target) < ($1.maximum,$1.target) }) {
                var differences: [Double] = []
                for row in modes where row.budget == budget {
                    guard let other = modes.first(where: { $0.round == row.round && $0.budget == reference.budget && $0.inputFingerprint == row.inputFingerprint }) else { continue }
                    differences += zip(row.blocks,other.blocks).map { $0.gapRatio - $1.gapRatio }
                }
                guard !differences.isEmpty else { continue }
                var seed: UInt64 = 7, means: [Double] = []
                for _ in 0..<200 {
                    var sum = 0.0
                    for _ in differences {
                        seed = seed &* 6364136223846793005 &+ 1
                        sum += differences[Int((seed >> 32) % UInt64(differences.count))]
                    }
                    means.append(sum / Double(differences.count))
                }
                means.sort()
                result.append(CalibrationPairedRange(reliable: mode, budget: budget, referenceBudget: reference.budget,
                    lowerDifference: means[4], upperDifference: means[194]))
            }
        }
        return result
    }
}

enum CalibrationSelector {
    private struct Key: Hashable { let reliable: Bool; let budget: CalibrationBudget; let reserve: Int }

    static func aggregate(_ rows: [CalibrationMeasurement]) -> [CalibrationMeasurement] {
        let groups = Dictionary(grouping: rows) { Key(reliable: $0.reliable, budget: $0.budget, reserve: $0.outputReserve) }
        return groups.values.map { group in
            var m = group[0]
            if group.count == 1 { return m }
            m.complete = group.allSatisfy(\.complete) && Set(group.map(\.round)).count == group.count
            m.clockValid = group.allSatisfy(\.clockValid)
            m.inputFingerprint = SHA256.hash(data: Data(group.map(\.inputFingerprint).sorted().joined(separator: ",").utf8))
                .map { String(format: "%02x", $0) }.joined()
            m.sampleCount = group.reduce(0) { $0 + $1.sampleCount }
            m.sourceFrames = group.reduce(0) { $0 + $1.sourceFrames }
            m.missingSourceFrames = group.reduce(0) { $0 + $1.missingSourceFrames }
            m.outputSeconds = group.reduce(0) { $0 + $1.outputSeconds }
            m.missingOutputSeconds = group.reduce(0) { $0 + $1.missingOutputSeconds }
            m.longestSourceGapMilliseconds = group.map(\.longestSourceGapMilliseconds).max() ?? 0
            m.longestOutputGapMilliseconds = group.map(\.longestOutputGapMilliseconds).max() ?? 0
            m.startupMilliseconds = group.map(\.startupMilliseconds).max() ?? 0
            m.maximumCorrection = group.map(\.maximumCorrection).max() ?? 0
            m.correctionSeconds = group.reduce(0) { $0 + $1.correctionSeconds }
            m.ages = group.flatMap(\.ages); m.blocks = group.flatMap(\.blocks)
            CalibrationReplay.setAges(&m)
            return m
        }.sorted { ($0.reliable ? 1 : 0,$0.budget.maximum,$0.budget.target) < ($1.reliable ? 1 : 0,$1.budget.maximum,$1.budget.target) }
    }

    static func select(measurements: [CalibrationMeasurement]) -> [CalibrationRecommendation] {
        let valid = aggregate(measurements).filter { $0.valid && $0.sampleCount >= 2 }
        guard !valid.isEmpty else { return [] }
        let frontier = valid.filter { row in
            !valid.contains { other in
                let a = other.ageP95Milliseconds!, b = row.ageP95Milliseconds!
                return a <= b && other.gapRatio <= row.gapRatio && other.longestGapMilliseconds <= row.longestGapMilliseconds &&
                    (a < b || other.gapRatio < row.gapRatio || other.longestGapMilliseconds < row.longestGapMilliseconds)
            }
        }
        func latency(_ a: CalibrationMeasurement, _ b: CalibrationMeasurement) -> Bool {
            (a.ageP95Milliseconds!,a.gapRatio,a.longestGapMilliseconds,a.budget.maximum,a.budget.target,a.reliable ? 1 : 0) <
            (b.ageP95Milliseconds!,b.gapRatio,b.longestGapMilliseconds,b.budget.maximum,b.budget.target,b.reliable ? 1 : 0)
        }
        let stable = frontier.min {
            ($0.gapRatio,$0.longestGapMilliseconds,$0.ageP95Milliseconds!,$0.budget.maximum,$0.budget.target,$0.reliable ? 1 : 0) <
            ($1.gapRatio,$1.longestGapMilliseconds,$1.ageP95Milliseconds!,$1.budget.maximum,$1.budget.target,$1.reliable ? 1 : 0)
        }!
        return [1,2,4].map { profile in
            let selected = profile == 4 ? stable : frontier.filter {
                $0.gapRatio <= (profile == 1 ? 0.005 : 0.001) && $0.longestGapMilliseconds <= (profile == 1 ? 40 : 20)
            }.min(by: latency)
            let choice = selected.map { CalibrationChoice(profileMask: profile, reliable: $0.reliable,
                budget: $0.budget, outputReserve: $0.outputReserve) }
            return CalibrationRecommendation(profile: profile, choice: choice, measurement: selected ?? stable, metGoal: selected != nil)
        }
    }

    static func choices(from recommendations: [CalibrationRecommendation]) -> [CalibrationChoice] {
        var result: [CalibrationChoice] = []
        for recommendation in recommendations {
            guard let choice = recommendation.choice else { continue }
            if let i = result.firstIndex(where: { $0.reliable == choice.reliable && $0.budget == choice.budget && $0.outputReserve == choice.outputReserve }) {
                result[i].profileMask |= choice.profileMask
            } else { result.append(choice) }
        }
        return result
    }
}
