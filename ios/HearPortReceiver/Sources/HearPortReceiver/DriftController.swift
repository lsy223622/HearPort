import Foundation

public struct DriftController {
    public let nominalRatio: Double
    public let maximumCorrection: Double
    public private(set) var ratio: Double

    private let lowPassAlpha: Double
    private var lowPassError: Double?

    public init(nominalRatio: Double = 1.0,
                maximumCorrection: Double = 0.001,
                lowPassAlpha: Double = 0.02) {
        precondition(nominalRatio > 0)
        precondition(maximumCorrection > 0)
        precondition(lowPassAlpha > 0 && lowPassAlpha <= 1)
        self.nominalRatio = nominalRatio
        self.maximumCorrection = maximumCorrection
        self.lowPassAlpha = lowPassAlpha
        ratio = nominalRatio
    }

    @discardableResult
    public mutating func update(fillError: Double, validAudio: Bool) -> Double {
        guard validAudio else {
            freeze()
            return ratio
        }
        if let previous = lowPassError {
            lowPassError = previous + lowPassAlpha * (fillError - previous)
        } else {
            lowPassError = fillError
        }
        let correction = min(max(lowPassError! * 0.000001,
                                 -maximumCorrection), maximumCorrection)
        ratio = nominalRatio + correction
        return ratio
    }

    public mutating func freeze() {
        lowPassError = nil
    }

    public mutating func reset() {
        lowPassError = nil
        ratio = nominalRatio
    }
}
