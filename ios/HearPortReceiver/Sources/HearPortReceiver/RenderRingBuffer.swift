import Foundation
import HearPortAtomics

final class RenderRingBuffer: @unchecked Sendable {
    let capacityFrames: Int
    private let storage: OpaquePointer
    private let maximumAge = AtomicUInt64()
    private let clockUncertainty = AtomicUInt64()

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
    var sourceFillFrames: Int { Int(hearport_audio_ring_source_fill(storage)) }
    var lastSourceFrame: UInt64? {
        let frame = hearport_audio_ring_last_source(storage)
        return frame == UInt64.max ? nil : frame
    }
    var expiredFrames: UInt64 { hearport_audio_ring_expired_frames(storage) }

    func setMaximumAge(nanoseconds: UInt64) { maximumAge.store(nanoseconds) }
    func setClockUncertainty(nanoseconds: UInt64) { clockUncertainty.store(nanoseconds) }

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
        let age = maximumAge.load(), uncertainty = clockUncertainty.load()
        let permittedAge = age == 0 ? 0 : (age > uncertainty ? age - uncertainty : 1)
        let rendered = output.withUnsafeMutableBufferPointer { samples in
            Int(hearport_audio_ring_pop_at(storage, samples.baseAddress, requestedFrames,
                DispatchTime.now().uptimeNanoseconds, permittedAge))
        }
        return (output, rendered)
    }

    @discardableResult
    func pushTimed(_ samples: [Float], sourceBegin: UInt64, sourceEnd: UInt64,
                    capturedAt: UInt64, deadline: UInt64 = .max) -> Int {
        guard samples.count.isMultiple(of: 2) else { return 0 }
        return samples.withUnsafeBufferPointer {
            Int(hearport_audio_ring_push_timed(storage, $0.baseAddress, samples.count / 2,
                                             sourceBegin, sourceEnd, capturedAt, deadline))
        }
    }
}
