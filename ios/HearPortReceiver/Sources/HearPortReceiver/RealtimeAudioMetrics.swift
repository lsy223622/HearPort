import Foundation

struct RealtimeAudioMetricsSnapshot: Sendable {
    let fields: [String: String]
}

final class RealtimeAudioMetrics: @unchecked Sendable {
    private let datagramsReceived = AtomicUInt64()
    private let datagramBytes = AtomicUInt64()
    private let invalidDatagrams = AtomicUInt64()
    private let acceptedDatagrams = AtomicUInt64()
    private let pendingStreamDatagrams = AtomicUInt64()
    private let oldStreamDatagrams = AtomicUInt64()
    private let insertedPackets = AtomicUInt64()
    private let duplicatePackets = AtomicUInt64()
    private let latePackets = AtomicUInt64()
    private let wrongStreamPackets = AtomicUInt64()
    private let capacityDrops = AtomicUInt64()
    private let lostPackets = AtomicUInt64()
    private let concealedPackets = AtomicUInt64()
    private let renderCallbacks = AtomicUInt64()
    private let requestedRenderFrames = AtomicUInt64()
    private let renderedFrames = AtomicUInt64()
    private let renderUnderflowFrames = AtomicUInt64()
    private let renderOverflowFrames = AtomicUInt64()
    private let renderLockMisses = AtomicUInt64()
    private let skippedSnapshots = AtomicUInt64()
    private let jitterMinFillPackets = AtomicUInt64(UInt64.max)
    private let jitterMaxFillPackets = AtomicUInt64()
    private let currentRenderFillFrames = AtomicUInt64()
    private let renderMinFillFrames = AtomicUInt64(UInt64.max)
    private let renderMaxFillFrames = AtomicUInt64()
    private let resamplerRatio = AtomicUInt64(Double(1).bitPattern)
    private let driftFillError = AtomicUInt64(Double(0).bitPattern)

    func resetInterval() {
        for counter in intervalCounters {
            counter.exchange(0)
        }
        jitterMinFillPackets.store(UInt64.max)
        jitterMaxFillPackets.store(0)
        renderMinFillFrames.store(UInt64.max)
        renderMaxFillFrames.store(0)
    }

    func recordDatagram(byteCount: Int) {
        datagramsReceived.increment()
        datagramBytes.increment(by: UInt64(max(0, byteCount)))
    }

    func recordInvalidDatagram() {
        invalidDatagrams.increment()
    }

    func recordDisposition(_ disposition: AudioDisposition) {
        switch disposition {
        case .accepted:
            acceptedDatagrams.increment()
        case .pendingAudioDiscarded:
            pendingStreamDatagrams.increment()
        case .oldStreamDiscarded:
            oldStreamDatagrams.increment()
        }
    }

    func recordJitterResult(_ result: JitterInsertResult, fillPackets: Int) {
        switch result {
        case .inserted:
            insertedPackets.increment()
        case .duplicate:
            duplicatePackets.increment()
        case .late:
            latePackets.increment()
        case .wrongStream:
            wrongStreamPackets.increment()
        case .capacityExceeded:
            capacityDrops.increment()
        }
        let fill = UInt64(max(0, fillPackets))
        jitterMinFillPackets.updateMinimum(fill)
        jitterMaxFillPackets.updateMaximum(fill)
    }

    func recordConcealment() {
        lostPackets.increment()
        concealedPackets.increment()
    }

    func recordRenderBuffer(fillFrames: Int,
                            underflowFrames: Int,
                            overflowFrames: Int) {
        recordRenderFill(fillFrames)
        renderUnderflowFrames.increment(by: UInt64(max(0, underflowFrames)))
        renderOverflowFrames.increment(by: UInt64(max(0, overflowFrames)))
    }

    func recordRenderCallback(requestedFrames: Int,
                              renderedFrames: Int,
                              fillFrames: Int,
                              resamplerRatio: Double,
                              fillError: Double) {
        renderCallbacks.increment()
        requestedRenderFrames.increment(by: UInt64(max(0, requestedFrames)))
        self.renderedFrames.increment(by: UInt64(max(0, renderedFrames)))
        recordRenderFill(fillFrames)
        recordConversion(resamplerRatio: resamplerRatio, fillError: fillError)
    }

    func recordRenderLockMiss() {
        renderLockMisses.increment()
    }

    func recordConversion(resamplerRatio: Double, fillError: Double) {
        self.resamplerRatio.store(resamplerRatio.bitPattern)
        driftFillError.store(fillError.bitPattern)
    }

    func recordReporterSkipped() {
        skippedSnapshots.increment()
    }

    func snapshotAndReset(streamID: UInt32?,
                          lastSequence: UInt32?,
                          expectedSequence: UInt32?,
                          jitterMode: JitterMode?,
                          jitterTargetPackets: Int,
                          jitterFillPackets: Int,
                          renderFillFrames: Int,
                          sessionPhase: ReceiverPhase,
                          lifecycleState: AudioLifecycleState,
                          outputRoute: String,
                          sampleRate: Double,
                          diagnosticsDropped: UInt64) -> RealtimeAudioMetricsSnapshot {
        let fields: [String: String] = [
            "event": "realtime_summary",
            "stream_id": streamID.map(String.init) ?? "none",
            "last_sequence": lastSequence.map(String.init) ?? "none",
            "expected_sequence": expectedSequence.map(String.init) ?? "none",
            "jitter_mode": jitterMode.map(String.init(describing:)) ?? "none",
            "jitter_target_packets": "\(jitterTargetPackets)",
            "jitter_fill_packets": "\(jitterFillPackets)",
            "jitter_min_fill_packets": intervalMinimum(jitterMinFillPackets),
            "jitter_max_fill_packets": "\(jitterMaxFillPackets.exchange(0))",
            "render_fill_frames": "\(max(renderFillFrames, Int(currentRenderFillFrames.load())))",
            "render_min_fill_frames": intervalMinimum(renderMinFillFrames),
            "render_max_fill_frames": "\(renderMaxFillFrames.exchange(0))",
            "datagrams_received": "\(datagramsReceived.exchange(0))",
            "datagram_bytes": "\(datagramBytes.exchange(0))",
            "invalid_datagrams": "\(invalidDatagrams.exchange(0))",
            "accepted_datagrams": "\(acceptedDatagrams.exchange(0))",
            "pending_stream_datagrams": "\(pendingStreamDatagrams.exchange(0))",
            "old_stream_datagrams": "\(oldStreamDatagrams.exchange(0))",
            "inserted_packets": "\(insertedPackets.exchange(0))",
            "duplicate_packets": "\(duplicatePackets.exchange(0))",
            "late_packets": "\(latePackets.exchange(0))",
            "wrong_stream_packets": "\(wrongStreamPackets.exchange(0))",
            "capacity_drops": "\(capacityDrops.exchange(0))",
            "lost_packets": "\(lostPackets.exchange(0))",
            "concealed_packets": "\(concealedPackets.exchange(0))",
            "render_callbacks": "\(renderCallbacks.exchange(0))",
            "requested_render_frames": "\(requestedRenderFrames.exchange(0))",
            "rendered_frames": "\(renderedFrames.exchange(0))",
            "render_underflow_frames": "\(renderUnderflowFrames.exchange(0))",
            "render_overflow_frames": "\(renderOverflowFrames.exchange(0))",
            "render_lock_misses": "\(renderLockMisses.exchange(0))",
            "skipped_snapshots": "\(skippedSnapshots.exchange(0))",
            "resampler_ratio": "\(Double(bitPattern: resamplerRatio.load()))",
            "drift_fill_error": "\(Double(bitPattern: driftFillError.load()))",
            "session_phase": "\(sessionPhase)",
            "lifecycle_state": "\(lifecycleState)",
            "output_route": outputRoute,
            "sample_rate": "\(sampleRate)",
            "diagnostics_dropped": "\(diagnosticsDropped)"
        ]
        return RealtimeAudioMetricsSnapshot(fields: fields)
    }

    private var intervalCounters: [AtomicUInt64] {
        [
            datagramsReceived, datagramBytes, invalidDatagrams,
            acceptedDatagrams, pendingStreamDatagrams, oldStreamDatagrams,
            insertedPackets, duplicatePackets, latePackets, wrongStreamPackets,
            capacityDrops, lostPackets, concealedPackets, renderCallbacks,
            requestedRenderFrames, renderedFrames,
            renderUnderflowFrames, renderOverflowFrames,
            renderLockMisses, skippedSnapshots
        ]
    }

    private func recordRenderFill(_ fillFrames: Int) {
        let fill = UInt64(max(0, fillFrames))
        currentRenderFillFrames.store(fill)
        renderMinFillFrames.updateMinimum(fill)
        renderMaxFillFrames.updateMaximum(fill)
    }

    private func intervalMinimum(_ counter: AtomicUInt64) -> String {
        let value = counter.exchange(UInt64.max)
        return value == UInt64.max ? "none" : "\(value)"
    }
}
