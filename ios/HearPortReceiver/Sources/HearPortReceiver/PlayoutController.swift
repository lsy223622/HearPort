import Foundation

public struct PlayoutBudget: Equatable, Sendable {
    public let targetMilliseconds: Double
    public let maximumMilliseconds: Double
    public let outputReserveMilliseconds: Double

    public init(targetMilliseconds: Double, maximumMilliseconds: Double,
                outputReserveMilliseconds: Double) throws {
        guard targetMilliseconds.isFinite, maximumMilliseconds.isFinite,
              outputReserveMilliseconds.isFinite,
              outputReserveMilliseconds >= 0,
              targetMilliseconds > outputReserveMilliseconds,
              maximumMilliseconds >= targetMilliseconds,
              maximumMilliseconds <= 2_000 else {
            throw ControlMessageError.invalidMessage
        }
        self.targetMilliseconds = targetMilliseconds
        self.maximumMilliseconds = maximumMilliseconds
        self.outputReserveMilliseconds = outputReserveMilliseconds
    }

    public func prepareDeadline(capturedAt: UInt64, processingMilliseconds: Double = 0,
                                uncertaintyNanoseconds: UInt64 = 0) -> UInt64 {
        let allowance = max(0, maximumMilliseconds - outputReserveMilliseconds -
                             max(0, processingMilliseconds)) * 1_000_000
        let remaining = max(0, allowance - Double(uncertaintyNanoseconds))
        let (deadline, overflow) = capturedAt.addingReportingOverflow(UInt64(remaining))
        return overflow ? .max : deadline
    }
}

public enum PlayoutAction: String, Sendable { case normal, wait, conceal, resync }

public struct PlayoutDecision: Sendable {
    public let action: PlayoutAction
    public let correction: Double
    public let targetMilliseconds: Double
    public let prepareDeadline: UInt64?
}

public struct PlayoutController: Sendable {
    public let budget: PlayoutBudget
    public let maximumCorrection: Double
    public private(set) var targetMilliseconds: Double
    private var anchor: (sourceFrame: UInt64, capturedAt: UInt64)?
    private var delays: [Double] = []
    private var lastDecisionAt: UInt64?
    private var correction = 0.0

    public init(budget: PlayoutBudget, maximumCorrection: Double = 0.05) {
        self.budget = budget
        self.maximumCorrection = min(0.2, max(0, maximumCorrection))
        targetMilliseconds = budget.targetMilliseconds
    }

    public mutating func observeArrival(sourceFrame: UInt64, capturedAt: UInt64,
                                        receivedAt: UInt64) {
        if anchor == nil { anchor = (sourceFrame, capturedAt) }
        guard receivedAt >= capturedAt else { return }
        delays.append(Double(receivedAt - capturedAt) / 1_000_000)
        if delays.count > 256 { delays.removeFirst(delays.count - 256) }
    }

    public func captureTime(sourceFrame: UInt64) -> UInt64? {
        guard let anchor else { return nil }
        let frames = sourceFrame >= anchor.sourceFrame
            ? Double(sourceFrame - anchor.sourceFrame)
            : -Double(anchor.sourceFrame - sourceFrame)
        let timestamp = Double(anchor.capturedAt) + frames * 1_000_000_000 / 48_000
        guard timestamp >= 0, timestamp < Double(UInt64.max) else { return nil }
        return UInt64(timestamp.rounded())
    }

    public mutating func decision(now: UInt64, nextSourceFrame: UInt64,
                                  playableFrames: Int, stagedSourceFrames: Int,
                                  processingMilliseconds: Double = 0,
                                  uncertaintyNanoseconds: UInt64 = 0) -> PlayoutDecision {
        let elapsed = lastDecisionAt.map { now >= $0 ? Double(now - $0) / 1_000_000 : 0 } ?? 5
        lastDecisionAt = now
        if delays.count >= 8 {
            let sorted = delays.sorted()
            let tail = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.98))]
            let desired = min(budget.maximumMilliseconds, max(budget.targetMilliseconds,
                tail + budget.outputReserveMilliseconds + processingMilliseconds + 5))
            let step = desired > targetMilliseconds ? elapsed * 0.2 : elapsed * 0.005
            targetMilliseconds += min(step, max(-step, desired - targetMilliseconds))
        }
        let deadline = captureTime(sourceFrame: nextSourceFrame).map {
            budget.prepareDeadline(capturedAt: $0, processingMilliseconds: processingMilliseconds,
                                   uncertaintyNanoseconds: uncertaintyNanoseconds)
        }
        let totalFrames = max(0, playableFrames) + max(0, stagedSourceFrames)
        let fill = Double(totalFrames) / 48
        let bufferTarget = max(0, targetMilliseconds - budget.outputReserveMilliseconds -
                               processingMilliseconds - (delays.min() ?? 0))
        let error = fill - bufferTarget
        let adjusted = error > 2.5 ? error - 2.5 : (error < -2.5 ? error + 2.5 : 0)
        var desired = min(maximumCorrection, max(-maximumCorrection, adjusted / 250))
        if totalFrames == 0 { desired = 0 }
        correction += min(elapsed * 0.002, max(-elapsed * 0.002, desired - correction))
        let action: PlayoutAction
        if let deadline, now >= deadline {
            action = totalFrames == 0 ? .conceal : .resync
            correction = max(0, correction)
        } else {
            action = totalFrames == 0 ? .wait : .normal
        }
        if totalFrames == 0 { correction = 0 }
        return PlayoutDecision(action: action, correction: correction,
                               targetMilliseconds: targetMilliseconds, prepareDeadline: deadline)
    }
}
