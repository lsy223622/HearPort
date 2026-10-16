import Foundation

struct CalibrationContext: Codable, Sendable {
    var device = "unknown"
    var operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    var output = "unknown"
    var sampleRate = 0.0
}

struct CalibrationResult: Codable, Sendable {
    let version: Int
    let planID: UInt32
    let testedAt: Date
    let seconds, maximum: Int
    let analysis: CalibrationAnalysis?
    let validation: [CalibrationMeasurement]
    let complete: Bool
    let warnings: [String]
    var context = CalibrationContext()
    var reportConfirmed = false

    static let storageKey = "hearport.environmentCalibration.v1"
    var usable: Bool { reportConfirmed && validObservation }
    private var validObservation: Bool {
        version == 1 && complete && analysis != nil && !validation.isEmpty &&
        analysis!.recommendations.map(\.profile).sorted() == [1,2,4] &&
        !CalibrationSelector.choices(from: analysis!.recommendations).isEmpty &&
        analysis!.recommendations.allSatisfy { recommendation in
            guard let choice = recommendation.choice else { return !recommendation.metGoal }
            return choice.budget.maximum <= maximum && calibrationBudgets(maximum: maximum,
                outputReserve: choice.outputReserve).contains(choice.budget) &&
                validation.filter { $0.reliable == choice.reliable && $0.budget == choice.budget && $0.valid }.count == 2
        }
    }
    func validationStatus(profile: Int) -> String {
        guard let recommendation = analysis?.recommendations.first(where: { $0.profile == profile }),
              let choice = recommendation.choice, recommendation.metGoal else { return "unavailable" }
        guard validObservation else { return "incomplete" }
        let rounds = validation.filter { $0.reliable == choice.reliable && $0.budget == choice.budget }
        let ratio = profile == 1 ? 0.005 : 0.001, gap = profile == 1 ? 40.0 : 20.0
        if profile != 4 && rounds.contains(where: { $0.gapRatio > ratio || $0.longestGapMilliseconds > gap }) { return "not_met" }
        if let baseline = recommendation.measurement,
           rounds.contains(where: { $0.gapRatio > baseline.gapRatio || $0.longestGapMilliseconds > baseline.longestGapMilliseconds }) {
            return "provisional"
        }
        return "observed"
    }
    @discardableResult func save(to defaults: UserDefaults = .standard) -> Bool {
        guard usable, let data = try? JSONEncoder().encode(self) else { return false }
        defaults.set(data, forKey: Self.storageKey)
        return true
    }
    static func load(from defaults: UserDefaults = .standard) -> CalibrationResult? {
        guard let data = defaults.data(forKey: storageKey),
              let result = try? JSONDecoder().decode(Self.self, from: data), result.usable else { return nil }
        return result
    }
    @discardableResult func apply(profile: Int, to defaults: UserDefaults = .standard) -> Bool {
        guard usable, let choice = analysis?.recommendations.first(where: { $0.profile == profile })?.choice else { return false }
        defaults.set(choice.reliable ? AudioTransportMode.reliable.rawValue : AudioTransportMode.datagram.rawValue,
                     forKey: "hearport.audioTransportMode")
        defaults.set(choice.budget.target, forKey: "hearport.targetLatencyMs")
        defaults.set(choice.budget.maximum, forKey: "hearport.maximumLatencyMs")
        return true
    }
    var reportSections: String {
        func number(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "-" }
            return String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        var rows = ["calibration_summary_v1",
            "version\tplan_id\tcomplete\tseconds\tceiling_ms\tprofile\treliable\ttarget_ms\tmaximum_ms\treserve_ms\tmet_goal\tstatus\tage_p95_ms\tgap_ratio\tlongest_gap_ms"]
        for profile in [1,2,4] {
            let recommendation = analysis?.recommendations.first { $0.profile == profile }
            let choice = recommendation?.choice, m = recommendation?.measurement
            rows.append(["1", "\(planID)", complete ? "1" : "0", "\(seconds)", "\(maximum)", "\(profile)",
                choice?.reliable == true ? "1" : "0", "\(choice?.budget.target ?? 0)", "\(choice?.budget.maximum ?? 0)",
                "\(choice?.outputReserve ?? 0)", recommendation?.metGoal == true ? "1" : "0", validationStatus(profile: profile),
                number(m?.ageP95Milliseconds), number(m?.gapRatio), number(m?.longestGapMilliseconds)].joined(separator: "\t"))
        }
        let header = "round\treliable\ttarget_ms\tmaximum_ms\treserve_ms\tvalid\tsample_count\tage_p95_ms\tgap_ratio\tlongest_gap_ms\tsource_gap_ratio\toutput_gap_ratio\tstartup_ms\tinput_hash"
        for (name, measurements) in [("calibration_curve_v1", analysis?.candidates ?? []), ("calibration_validation_v1", validation)] {
            rows.append(""); rows.append(name); rows.append(header)
            for m in measurements {
                rows.append(["\(m.round)",m.reliable ? "1" : "0","\(m.budget.target)","\(m.budget.maximum)","\(m.outputReserve)",
                    m.valid ? "1" : "0","\(m.sampleCount)",number(m.ageP95Milliseconds),number(m.gapRatio),number(m.longestGapMilliseconds),
                    number(m.sourceFrames > 0 ? Double(m.missingSourceFrames)/Double(m.sourceFrames) : nil),
                    number(m.outputSeconds > 0 ? m.missingOutputSeconds/m.outputSeconds : nil),number(m.startupMilliseconds),m.inputFingerprint].joined(separator: "\t"))
            }
        }
        return rows.joined(separator: "\n")
    }
}

struct CalibrationProgressSnapshot: Sendable {
    let stage: String
    let index, count, completed, total: Int
}

final class EnvironmentCalibrationSession: @unchecked Sendable {
    let setup: CalibrationMessage
    private let lock = NSLock()
    private let cancelled = AtomicUInt64()
    private var context = CalibrationContext()
    func setContext(_ value: CalibrationContext) { lock.lock(); context = value; lock.unlock() }
    private var traces: [CalibrationRoundTrace] = []
    private var current: CalibrationRoundTrace?
    private var consumer: ProbeConsumer?
    private var analysis: CalibrationAnalysis?
    private var analyzing = false
    private var retainedPackets = 0
    private var analysisCompleted = 0, analysisTotal = 0

    init(setup: CalibrationMessage) { self.setup = setup }

    func beginRound(_ round: CalibrationMessage, at: UInt64) throws -> CalibrationMessage {
        lock.lock(); defer { lock.unlock() }
        let expected = traces.count + (current == nil ? 1 : 2)
        guard cancelled.load() == 0, round.planID == setup.planID, round.index == expected,
              round.seconds == setup.seconds, round.budget.maximum <= setup.budget.maximum,
              round.firstSequence == UInt32(round.index - 1) * UInt32(round.seconds * 400),
              round.firstSourceFrame == UInt64(round.firstSequence) * 120 else { throw ControlMessageError.invalidMessage }
        if round.phase == 0 {
            guard round.index <= 4, round.count == 4, analysis == nil,
                  round.budget.maximum == setup.budget.maximum else { throw ControlMessageError.invalidMessage }
        } else {
            guard let analysis, round.index > 4 else { throw ControlMessageError.invalidMessage }
            let choices = CalibrationSelector.choices(from: analysis.recommendations)
            guard round.count == 4 + choices.count * 2,
                  choices.contains(where: { $0.profileMask == round.profileMask && $0.reliable == round.reliable &&
                      $0.budget == round.budget && $0.outputReserve == round.outputReserve }) else { throw ControlMessageError.invalidMessage }
        }
        finishCurrent(at: at)
        current = CalibrationRoundTrace(round: round, packets: [], ticks: [], endAt: at)
        let spec = CoordinatedProbePlan.Round(payloadBytes: 992, packetsPerSecond: 400, burstPackets: 1, variant: 1,
            reliable: round.reliable, repeatIndex: 1, controller: 2, repair: 0, correctionPercent: 5)
        consumer = ProbeConsumer(round: spec, budget: try PlayoutBudget(targetMilliseconds: Double(round.budget.target),
            maximumMilliseconds: Double(round.budget.maximum), outputReserveMilliseconds: Double(round.outputReserve)),
            firstSequence: round.firstSequence, sourceFrame: round.firstSourceFrame, durationSeconds: round.seconds)
        var ack = CalibrationMessage(kind: .ack, planID: setup.planID)
        ack.phase = round.phase; ack.index = round.index
        return ack
    }

    @discardableResult
    func receive(_ record: TimedAudioRecord, capturedAt: UInt64?, uncertainty: UInt64,
                 receivedAt: UInt64, processedAt: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let round = current?.round, cancelled.load() == 0, record.streamID == setup.planID,
              record.kind == .probe || record.kind == .retransmission,
              record.frameCount == 120, record.payload.count == 960,
              record.generation >= round.generation,
              record.sequence >= round.firstSequence,
              UInt64(record.sequence - round.firstSequence) < UInt64(round.seconds * 400),
              record.sourceFrame == UInt64(record.sequence) * 120 else { return false }
        guard let capture = capturedAt, capture <= receivedAt || capture - receivedAt <= uncertainty else {
            current!.clockValid = false; return false
        }
        guard retainedPackets < DebugSessionDiagnostics.defaultCapacity else {
            current!.complete = false; return false
        }
        current!.packets.append(CalibrationPacket(receivedAt: receivedAt, capturedAt: capture, uncertainty: uncertainty,
            sequence: record.sequence, generation: record.generation, sourceFrame: record.sourceFrame, processedAt: processedAt, kind: record.kind))
        retainedPackets += 1
        consumer?.receive(record, capturedAt: capture, uncertainty: uncertainty, now: receivedAt)
        return true
    }

    func tick(at: UInt64, uncertainty: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard current != nil, cancelled.load() == 0 else { return }
        if current!.ticks.count < DebugSessionDiagnostics.defaultCapacity {
            current!.ticks.append(CalibrationTick(at: at, uncertainty: uncertainty))
        } else { current!.complete = false }
        consumer?.updateUncertainty(uncertainty)
        _ = consumer?.tick(now: at)
    }

    func feedback() -> (sequence: UInt32?, played: UInt64?, buffered: UInt32)? {
        lock.lock(); defer { lock.unlock() }
        guard let consumer, cancelled.load() == 0 else { return nil }
        return (consumer.latestReceivedSequence, consumer.playedSourceFrame, UInt32(consumer.bufferedFrames / 48))
    }

    func progress() -> CalibrationProgressSnapshot {
        lock.lock(); defer { lock.unlock() }
        let round = current?.round
        return CalibrationProgressSnapshot(stage: cancelled.load() != 0 ? "interrupted" : analyzing ? "analyzing" :
            (round?.phase == 1 ? "validation" : "sampling"), index: round?.index ?? 0, count: round?.count ?? 4,
            completed: analysisCompleted, total: analysisTotal)
    }

    func analyze(at: UInt64, progress: (Int,Int) -> Void) throws -> CalibrationAnalysis {
        lock.lock()
        guard cancelled.load() == 0, analysis == nil, !analyzing,
              traces.count + (current == nil ? 0 : 1) == 4 else { lock.unlock(); throw CancellationError() }
        finishCurrent(at: at); consumer = nil; analyzing = true
        let input = traces
        lock.unlock()
        defer { lock.lock(); analyzing = false; lock.unlock() }
        let result = try CalibrationReplay.analyze(traces: input, maximum: setup.budget.maximum,
            progress: { done,total in
                self.lock.lock(); self.analysisCompleted = done; self.analysisTotal = total; self.lock.unlock()
                progress(done,total)
            }, cancelled: { self.cancelled.load() != 0 })
        lock.lock(); defer { lock.unlock() }
        guard cancelled.load() == 0 else { throw CancellationError() }
        analysis = result
        return result
    }

    var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return current != nil || !traces.isEmpty || analyzing }
    func cancel() { cancelled.store(1) }
    func confirm(_ result: CalibrationResult, planID: UInt32) -> CalibrationResult? {
        guard cancelled.load() == 0, planID == setup.planID, result.planID == planID, result.complete else { return nil }
        var confirmed = result
        confirmed.reportConfirmed = true
        return confirmed
    }

    func result(at: UInt64, completed: Bool) -> CalibrationResult {
        lock.lock()
        finishCurrent(at: at); consumer = nil
        let input = traces, captured = analysis, capturedContext = context
        lock.unlock()
        let validation = input.filter { $0.round.phase == 1 }.map { CalibrationReplay.evaluate(trace: $0, budget: $0.round.budget) }
        let choices = captured.map { CalibrationSelector.choices(from: $0.recommendations) } ?? []
        let valid = completed && cancelled.load() == 0 && captured != nil && !choices.isEmpty && input.count == 4 + choices.count * 2 &&
            input.allSatisfy { $0.complete && $0.clockValid && !$0.packets.isEmpty && $0.observableFrames == UInt64($0.round.seconds) * 48_000 } && validation.allSatisfy(\.valid) &&
            choices.allSatisfy { choice in
                input.filter { $0.round.phase == 1 && $0.round.profileMask == choice.profileMask &&
                    $0.round.reliable == choice.reliable && $0.round.budget == choice.budget }.count == 2
            }
        var warnings = ["Calibration is a finite observation of this network, not a future stability guarantee.",
            "Sampling replay is conditional on the recorded sender behavior. Validation uses new traffic.",
            "Source ages include output reserve estimates; audio DSP and acoustic latency were not measured."]
        if !valid { warnings.append("Calibration did not complete with sufficient valid data.") }
        var result = CalibrationResult(version: 1, planID: setup.planID, testedAt: Date(), seconds: setup.seconds,
            maximum: setup.budget.maximum, analysis: captured, validation: validation, complete: valid, warnings: warnings)
        result.context = capturedContext
        return result
    }

    private func finishCurrent(at: UInt64) {
        guard var trace = current else { return }
        trace.endAt = at
        if cancelled.load() != 0 { trace.complete = false }
        traces.append(trace); current = nil
    }
}
