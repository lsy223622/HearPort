import Foundation

public struct StreamingStereoResampler {
    private var sourcePosition = 0.0
    private var previousLeft = Float.zero
    private var previousRight = Float.zero
    private var hasPreviousFrame = false

    public init() {}

    public mutating func reset() {
        sourcePosition = 0
        previousLeft = 0
        previousRight = 0
        hasPreviousFrame = false
    }

    public func requiredInputFrames(outputFrameCount: Int, ratio: Double) -> Int {
        guard outputFrameCount > 0, ratio > 0 else { return 0 }
        let lastPosition = sourcePosition + Double(outputFrameCount - 1) * ratio
        guard lastPosition >= 0 else { return 1 }
        let lowerIndex = Int(floor(lastPosition))
        let fraction = lastPosition - Double(lowerIndex)
        let required = lowerIndex + (fraction > 0.000000001 ? 2 : 1)
        return max(1, required)
    }

    public mutating func process(
        _ interleavedStereo: [Float],
        outputFrameCount: Int,
        ratio: Double
    ) -> [Float] {
        guard outputFrameCount > 0, ratio > 0 else { return [] }
        let inputFrameCount = interleavedStereo.count / 2
        guard inputFrameCount > 0 else {
            return Array(repeating: 0, count: outputFrameCount * 2)
        }

        var output = Array(repeating: Float.zero, count: outputFrameCount * 2)
        var position = sourcePosition
        for frame in 0..<outputFrameCount {
            let lowerIndex = Int(floor(position))
            let fraction = Float(position - Double(lowerIndex))
            let left: Float
            let right: Float
            if lowerIndex < 0 {
                left = hasPreviousFrame ? previousLeft : interleavedStereo[0]
                right = interleavedStereo[1]
            } else if lowerIndex >= inputFrameCount {
                left = interleavedStereo[(inputFrameCount - 1) * 2]
                right = interleavedStereo[(inputFrameCount - 1) * 2 + 1]
            } else {
                left = interleavedStereo[lowerIndex * 2]
                right = interleavedStereo[lowerIndex * 2 + 1]
            }
            let upperIndex = lowerIndex + 1
            let upperLeft: Float
            let upperRight: Float
            if upperIndex < 0 {
                upperLeft = left
                upperRight = right
            } else if upperIndex >= inputFrameCount {
                upperLeft = left
                upperRight = right
            } else {
                upperLeft = interleavedStereo[upperIndex * 2]
                upperRight = interleavedStereo[upperIndex * 2 + 1]
            }
            output[frame * 2] = left + (upperLeft - left) * fraction
            output[frame * 2 + 1] = right + (upperRight - right) * fraction
            position += ratio
        }

        sourcePosition = position - Double(inputFrameCount)
        previousLeft = interleavedStereo[(inputFrameCount - 1) * 2]
        previousRight = interleavedStereo[(inputFrameCount - 1) * 2 + 1]
        hasPreviousFrame = true
        return output
    }
}
