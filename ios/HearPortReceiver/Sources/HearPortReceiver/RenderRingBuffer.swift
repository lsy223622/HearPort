import Foundation

public struct RenderRingBuffer {
    public let capacityFrames: Int
    private var storage: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var countFrames = 0

    public private(set) var overflowFrames = 0
    public private(set) var underflowFrames = 0

    public init(capacityFrames: Int) {
        precondition(capacityFrames > 0)
        self.capacityFrames = capacityFrames
        storage = Array(repeating: 0, count: capacityFrames * 2)
    }

    public var fillFrames: Int { countFrames }

    public mutating func reset() {
        readIndex = 0
        writeIndex = 0
        countFrames = 0
        overflowFrames = 0
        underflowFrames = 0
    }

    @discardableResult
    public mutating func push(_ interleavedStereo: [Float]) -> Int {
        guard interleavedStereo.count.isMultiple(of: 2) else { return 0 }
        var sourceIndex = 0
        var frames = interleavedStereo.count / 2
        if frames > capacityFrames {
            sourceIndex = (frames - capacityFrames) * 2
            frames = capacityFrames
        }
        if countFrames + frames > capacityFrames {
            let discarded = countFrames + frames - capacityFrames
            readIndex = (readIndex + discarded * 2) % storage.count
            countFrames -= discarded
            overflowFrames += discarded
        }
        for _ in 0..<frames {
            storage[writeIndex] = interleavedStereo[sourceIndex]
            storage[writeIndex + 1] = interleavedStereo[sourceIndex + 1]
            sourceIndex += 2
            writeIndex = (writeIndex + 2) % storage.count
        }
        countFrames += frames
        return frames
    }

    public mutating func pop(frames requestedFrames: Int) -> [Float] {
        guard requestedFrames > 0 else { return [] }
        var output = Array(repeating: Float.zero, count: requestedFrames * 2)
        let available = min(requestedFrames, countFrames)
        for frame in 0..<available {
            output[frame * 2] = storage[readIndex]
            output[frame * 2 + 1] = storage[readIndex + 1]
            readIndex = (readIndex + 2) % storage.count
        }
        countFrames -= available
        if available < requestedFrames {
            underflowFrames += requestedFrames - available
        }
        return output
    }
}
