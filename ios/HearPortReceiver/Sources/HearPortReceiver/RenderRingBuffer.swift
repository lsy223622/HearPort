import Foundation
import HearPortAtomics

final class RenderRingBuffer: @unchecked Sendable {
    let capacityFrames: Int
    private let storage: OpaquePointer

    init(capacityFrames: Int) {
        precondition(capacityFrames > 0)
        guard let storage = hearport_audio_ring_create(capacityFrames) else {
            preconditionFailure("Could not allocate audio ring")
        }
        self.capacityFrames = capacityFrames
        self.storage = storage
    }

    deinit {
        hearport_audio_ring_destroy(storage)
    }

    var fillFrames: Int { Int(hearport_audio_ring_fill(storage)) }
    var isResetAcknowledged: Bool { hearport_audio_ring_reset_acknowledged(storage) }

    func requestReset() {
        hearport_audio_ring_request_reset(storage)
    }

    @discardableResult
    func push(_ interleavedStereo: [Float]) -> Int {
        guard interleavedStereo.count.isMultiple(of: 2) else { return 0 }
        return interleavedStereo.withUnsafeBufferPointer { samples in
            Int(hearport_audio_ring_push(storage, samples.baseAddress,
                                         interleavedStereo.count / 2))
        }
    }

    func pop(frames requestedFrames: Int) -> (samples: [Float], renderedFrames: Int) {
        guard requestedFrames > 0 else { return ([], 0) }
        var output = Array(repeating: Float.zero, count: requestedFrames * 2)
        let rendered = output.withUnsafeMutableBufferPointer { samples in
            Int(hearport_audio_ring_pop(storage, samples.baseAddress, requestedFrames))
        }
        return (output, rendered)
    }
}
