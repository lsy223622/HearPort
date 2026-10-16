import Foundation

struct CalibrationResult: Codable, Sendable {
    let version: Int
    let planID: UInt32
    let testedAt: Date
    let seconds, maximum: Int
    let analysis: CalibrationAnalysis?
    let validation: [CalibrationMeasurement]
    let complete: Bool
    let warnings: [String]
}

struct CalibrationProgressSnapshot: Sendable {
    let stage: String
    let index, count, completed, total: Int
}

final class EnvironmentCalibrationSession: @unchecked Sendable {
    let setup: CalibrationMessage
    private let lock = NSLock()
    private let cancelled = AtomicUInt64()
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
        guard let round = current?.round, cancelled.load() == 0, record.kind == .probe,
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
            sequence: record.sequence, generation: record.generation, sourceFrame: record.sourceFrame, processedAt: processedAt))
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

    func cancel() { cancelled.store(1) }

    func result(at: UInt64, completed: Bool) -> CalibrationResult {
        lock.lock()
        finishCurrent(at: at); consumer = nil
        let input = traces, captured = analysis
        lock.unlock()
        let validation = input.filter { $0.round.phase == 1 }.map { CalibrationReplay.evaluate(trace: $0, budget: $0.round.budget) }
        let choices = captured.map { CalibrationSelector.choices(from: $0.recommendations) } ?? []
        let valid = completed && cancelled.load() == 0 && captured != nil && !choices.isEmpty && input.count == 4 + choices.count * 2 &&
            input.allSatisfy { $0.complete && $0.clockValid && !$0.packets.isEmpty } && validation.allSatisfy(\.valid) &&
            choices.allSatisfy { choice in
                input.filter { $0.round.phase == 1 && $0.round.profileMask == choice.profileMask &&
                    $0.round.reliable == choice.reliable && $0.round.budget == choice.budget }.count == 2
            }
        var warnings = ["Calibration is a finite observation of this network, not a future stability guarantee.",
            "Sampling replay is conditional on the recorded sender behavior. Validation uses new traffic.",
            "Source ages include output reserve estimates; audio DSP and acoustic latency were not measured."]
        if !valid { warnings.append("Calibration did not complete with sufficient valid data.") }
        return CalibrationResult(version: 1, planID: setup.planID, testedAt: Date(), seconds: setup.seconds,
            maximum: setup.budget.maximum, analysis: captured, validation: validation, complete: valid, warnings: warnings)
    }

    private func finishCurrent(at: UInt64) {
        guard var trace = current else { return }
        trace.endAt = at
        if cancelled.load() != 0 { trace.complete = false }
        traces.append(trace); current = nil
    }
}
