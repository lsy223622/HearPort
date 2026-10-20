import Foundation

public final class HearPortReceiver {
    public let diagnostics: HearPortDiagnostics
    let debugSessionDiagnostics: DebugSessionDiagnostics
    public let session = ReceiverSessionState()
    public let lifecycle: AudioLifecycleController
    public private(set) var invalidDatagrams = 0

    private var jitter: JitterBuffer?
    private let renderRing: RenderRingBuffer
    private let lock = NSLock()
    private let compressionAdmissionLock = NSLock()
    private let jitterFillFramesAtomic = AtomicUInt64()
    private let renderActiveAtomic = AtomicUInt64()
    private let pumpQueue = DispatchQueue(label: "com.hearport.receiver.pump", qos: .userInitiated)
    private var pumpTimer: DispatchSourceTimer?
    private var ringReserveFrames: Int
    private var loggedFirstAudioDatagram = false
    private var lastReceivedSequence: UInt32?
    private var clockMapping = ClockMapping()
    private var observedRoundTrip: (at: UInt64, duration: UInt64)?
    private var connectionTimingEpoch: UInt64 = 0
    private var playoutController: PlayoutController?
    private var reliableSourceFloor: UInt64 = 0
    private var compressionMusicDecoder: CompressionMusicDecoder?
    private var liveAudioDecoder: LiveAudioDecoder?
    private var liveAudioEpoch: UInt64 = 0
    private var compressionMusicRound: MusicTestRound?
    private var compressionSourceCoverage: CompressionSourceCoverage?
    private var compressionExpiredFramesAtStart: UInt64 = 0
    private var playoutAdaptive = true
    private var playoutMaximumCorrection = 0.05
    private var timedPackets: [UInt32: (record: TimedAudioRecord, capturedAt: UInt64, uncertainty: UInt64)] = [:]
    private var sourceAnchor: (sequence: UInt32, frame: UInt64)?
    private var timeStretch = StreamingTimeStretch()
    private var concealment = MusicConcealment()
    private let targetFramesAtomic = AtomicUInt64()
    private let concealingAtomic = AtomicUInt64()
    private let dynamicCorrectionAtomic = AtomicUInt64(Double(0).bitPattern)
    private let renderRequestFramesAtomic = AtomicUInt64(120)
    private let renderStartedAtAtomic = AtomicUInt64()
    public private(set) var playoutBudget: PlayoutBudget?
    private var outputRoute = "unknown"
    private var outputSampleRate = 48_000.0
    private let realtimeMetrics = RealtimeAudioMetrics()
    private let realtimeReporterQueue = DispatchQueue(
        label: "com.hearport.receiver.realtime-reporter",
        qos: .utility
    )
    private var realtimeReporter: DispatchSourceTimer?

    public init(bufferTargetPackets: Int = 8,
                renderCapacityFrames: Int = 4_800,
                diagnostics: HearPortDiagnostics = .shared,
                debugSessionDiagnostics: DebugSessionDiagnostics? = nil) {
        precondition(renderCapacityFrames > 0)
        self.diagnostics = diagnostics
        let normalizedBufferTarget = JitterBufferConfiguration(targetPackets: bufferTargetPackets)
            .targetPackets
        self.debugSessionDiagnostics = debugSessionDiagnostics ?? DebugSessionDiagnostics(
            bufferTargetPackets: normalizedBufferTarget,
            diagnostics: diagnostics
        )
        lifecycle = AudioLifecycleController(diagnostics: diagnostics)
        renderRing = RenderRingBuffer(capacityFrames: renderCapacityFrames)
        jitterTargetPackets = normalizedBufferTarget
        let targetFrames = normalizedBufferTarget * AudioDatagram.framesPerPacket
        targetFramesAtomic.store(UInt64(targetFrames))
        ringReserveFrames = min(renderCapacityFrames, 2_048,
                                targetFrames - (normalizedBufferTarget > 8
                                    ? AudioDatagram.framesPerPacket : 0))
        diagnostics.log(
            .info,
            category: .realtime,
            message: "receiver_initialized",
            fields: [
                "event": "receiver_initialized",
                "jitter_target_packets": "\(jitterTargetPackets)",
                "render_capacity_frames": "\(renderCapacityFrames)"
            ]
        )
        startRealtimeReporter()
    }

    deinit {
        realtimeReporter?.cancel()
        pumpTimer?.cancel()
    }

    public var renderFillFrames: Int {
        renderRing.sourceFillFrames + Int(jitterFillFramesAtomic.load())
    }

    public var isRenderActive: Bool {
        renderActiveAtomic.load() != 0 && renderRing.fillFrames > 0
    }

    public var isConcealing: Bool { concealingAtomic.load() != 0 }

    public var dynamicCorrection: Double { Double(bitPattern: dynamicCorrectionAtomic.load()) }

    public var jitterStats: JitterStats? {
        lock.lock()
        defer { lock.unlock() }
        return jitter?.stats
    }

    func linkTimingSample(at now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> LinkTimingSample {
        lock.lock(); defer { lock.unlock() }
        let rtt = observedRoundTrip.flatMap { observation -> Double? in
            guard now >= observation.at, now - observation.at <= 6_000_000_000 else { return nil }
            return Double(observation.duration) / 1_000_000
        }
        return LinkTimingSample(epoch: connectionTimingEpoch, time: Double(now) / 1_000_000_000,
            roundTripMilliseconds: rtt, roundTripObservedAt: observedRoundTrip?.at)
    }

    public func recordRenderCallback(requestedFrames: Int,
                                     renderedFrames: Int,
                                     fillFrames: Int,
                                     resamplerRatio: Double,
                                     fillError: Double) {
        realtimeMetrics.recordRenderCallback(
            requestedFrames: requestedFrames,
            renderedFrames: renderedFrames,
            fillFrames: fillFrames,
            resamplerRatio: resamplerRatio,
            fillError: fillError
        )
    }

    public func recordAudioOutput(route: String, sampleRate: Double) {
        lock.lock()
        outputRoute = route
        outputSampleRate = sampleRate
        lock.unlock()
    }

    private let jitterTargetPackets: Int

    var jitterTargetFrames: Int {
        Int(targetFramesAtomic.load())
    }

    @discardableResult
    public func beginAuthentication(authMode: AuthMode, peerID: Data) -> Bool {
        lock.lock()
        let accepted = session.receiveConnect(authMode: authMode, peerID: peerID)
        let phase = session.phase
        lock.unlock()
        diagnostics.log(
            accepted ? .info : .warning,
            category: .pairing,
            message: accepted ? "connect_accepted" : "connect_rejected",
            fields: [
                "event": accepted ? "connect_accepted" : "connect_rejected",
                "auth_mode": "\(authMode)",
                "peer_id_bytes": "\(peerID.count)",
                "phase": "\(phase)"
            ]
        )
        return accepted
    }

    public func resetForConnection() {
        stopLiveAudio()
        endMusicRound(reason: "connection_reset")
        lock.lock()
        session.resetForConnection()
        clockMapping = ClockMapping()
        observedRoundTrip = nil
        connectionTimingEpoch &+= 1
        playoutController = nil
        playoutBudget = nil
        timedPackets.removeAll(keepingCapacity: true)
        sourceAnchor = nil
        timeStretch.reset()
        concealment.reset()
        concealingAtomic.store(0)
        dynamicCorrectionAtomic.store(Double(0).bitPattern)
        renderRing.setMaximumAge(nanoseconds: 0)
        jitter = nil
        renderActiveAtomic.store(0)
        jitterFillFramesAtomic.store(0)
        renderRing.requestReset()
        pumpTimer?.cancel()
        pumpTimer = nil
        loggedFirstAudioDatagram = false
        lastReceivedSequence = nil
        realtimeMetrics.resetInterval()
        lock.unlock()
        diagnostics.log(
            .debug,
            category: .pairing,
            message: "receiver_connection_reset",
            fields: ["event": "receiver_connection_reset"]
        )
    }

    @discardableResult
    public func beginStream(_ streamID: UInt32) -> Bool {
        stopLiveAudio()
        endMusicRound(reason: "stream_replaced")
        lock.lock()
        let accepted = session.beginStream(streamID)
        if accepted {
            reliableSourceFloor = 0
            playoutAdaptive = true; playoutMaximumCorrection = 0.05
            if let budget = playoutBudget {
                playoutController = PlayoutController(budget: budget,
                    maximumCorrection: playoutMaximumCorrection, adaptive: playoutAdaptive)
            }
            timedPackets.removeAll(keepingCapacity: true)
            sourceAnchor = nil
        timeStretch.reset()
        concealment.reset()
        concealingAtomic.store(0)
        dynamicCorrectionAtomic.store(Double(0).bitPattern)
            jitter = JitterBuffer(streamID: streamID,
                                  targetPackets: jitterTargetPackets)
            renderActiveAtomic.store(0)
            jitterFillFramesAtomic.store(0)
            renderRing.requestReset()
            startPumpTimerLocked()
            loggedFirstAudioDatagram = false
            lastReceivedSequence = nil
            realtimeMetrics.resetInterval()
        }
        let phase = session.phase
        lock.unlock()
        diagnostics.log(
            accepted ? .info : .warning,
            category: .realtime,
            message: accepted ? "stream_begin_accepted" : "stream_begin_rejected",
            fields: [
                "event": accepted ? "stream_begin_accepted" : "stream_begin_rejected",
                "stream_id": "\(streamID)",
                "jitter_target_packets": "\(jitterTargetPackets)",
                "phase": "\(phase)"
            ]
        )
        return accepted
    }

    public func beginReliableGeneration(_ streamID: UInt32, generation: UInt32 = 1) -> Bool {
        lock.lock()
        guard session.activeStreamID == streamID || session.pendingStreamID == streamID else {
            lock.unlock()
            return false
        }
        if playoutBudget != nil, let sequence = jitter?.expectedSequence,
           let source = sourcePosition(for: sequence) {
            reliableSourceFloor = max(reliableSourceFloor, source)
        }
        let preserveOutput = playoutBudget != nil && renderRing.fillFrames > 0
        jitter = JitterBuffer(streamID: streamID, targetPackets: jitterTargetPackets,
            maximumPackets: max(256, Int(ceil((playoutBudget?.maximumMilliseconds ?? 100) / 2.5))))
        timedPackets.removeAll(keepingCapacity: true)
        sourceAnchor = nil
        timeStretch.reset()
        concealment.reset()
        concealingAtomic.store(0)
        dynamicCorrectionAtomic.store(Double(0).bitPattern)
        if !preserveOutput { renderActiveAtomic.store(0) }
        jitterFillFramesAtomic.store(0)
        if !preserveOutput {
            renderRing.requestReset()
            lifecycle.enterSilentRebuffer()
            session.enterSilentRebuffer()
        }
        lastReceivedSequence = nil
        loggedFirstAudioDatagram = false
        lock.unlock()
        _ = diagnostics.logAsync(.info, category: .audio,
                                 message: "reliable_generation_rebuffer",
                                 fields: ["event": "reliable_generation_rebuffer",
                                          "stream_id": "\(streamID)"])
        return true
    }

    public func reliableProgressSequence() -> UInt32? {
        lock.lock()
        defer { lock.unlock() }
        return lastReceivedSequence
    }

    private func stopLiveAudio() {
        compressionAdmissionLock.lock()
        lock.lock()
        let previous = liveAudioDecoder
        liveAudioDecoder = nil; liveAudioEpoch &+= 1
        lock.unlock(); compressionAdmissionLock.unlock()
        previous?.stop()
    }

    func configureLiveAudio(streamID: UInt32, format: AudioStreamFormat, budget: PlayoutBudget) throws {
        stopLiveAudio()
        guard format.opus else { return }
        lock.lock(); let epoch = liveAudioEpoch; lock.unlock()
        let decoder = try LiveAudioDecoder(format: format, streamID: streamID, budget: budget) { [weak self] record in
            guard let self else { return }
            self.compressionAdmissionLock.lock()
            defer { self.compressionAdmissionLock.unlock() }
            self.lock.lock()
            let current = self.liveAudioEpoch == epoch && self.session.activeStreamID == streamID
            self.lock.unlock()
            if current { _ = self.receiveTimedRecord(record) }
        }
        lock.lock(); liveAudioDecoder = decoder; lock.unlock()
    }

    func receiveLiveRecord(_ record: TimedAudioRecord) {
        let at = DispatchTime.now().uptimeNanoseconds
        lock.lock(); let decoder = liveAudioDecoder; lock.unlock()
        guard let decoder, decoder.valid(record), let mapped = mappedCapture(record, at: at) else { return }
        lock.lock()
        if liveAudioDecoder === decoder, session.activeStreamID == record.streamID {
            playoutController?.observeArrival(sourceFrame: record.sourceFrame, capturedAt: mapped.0, receivedAt: at)
        }
        lock.unlock()
        decoder.receive(record, captured: mapped.0, uncertainty: mapped.1)
    }

    public func configurePlayout(_ budget: PlayoutBudget) {
        lock.lock()
        playoutBudget = budget
        if let buffer = jitter {
            jitter = JitterBuffer(streamID: buffer.streamID, targetPackets: jitterTargetPackets,
                maximumPackets: max(256, Int(ceil(budget.maximumMilliseconds / 2.5))))
        }
        playoutController = PlayoutController(budget: budget, maximumCorrection: playoutMaximumCorrection, adaptive: playoutAdaptive)
        renderRing.setMaximumAge(nanoseconds: UInt64(
            (budget.maximumMilliseconds - budget.outputReserveMilliseconds) * 1_000_000))
        let target = max(1, Int(ceil((budget.targetMilliseconds - budget.outputReserveMilliseconds) / 2.5)))
        jitter?.setTargetPackets(target, recoveryPackets: max(target,
            Int((budget.maximumMilliseconds - budget.outputReserveMilliseconds) / 2.5)))
        ringReserveFrames = min(renderRing.capacityFrames, 2_048, target * 120)
        targetFramesAtomic.store(UInt64(target * 120))
        lock.unlock()
    }

    @discardableResult
    func beginMusicRound(streamID: UInt32, round: MusicTestRound) -> Bool {
        lock.lock()
        guard session.activeStreamID == streamID, let budget = playoutBudget else {
            lock.unlock(); return false
        }
        lock.unlock()
        endMusicRound(reason: "next_round")

        let newDecoder: CompressionMusicDecoder?
        if round.isCompressionTest {
            do {
                newDecoder = try CompressionMusicDecoder(round: round, streamID: streamID,
                    budget: budget, diagnostics: diagnostics,
                    currentTargetMilliseconds: { [weak self] in
                        self?.compressionDecodeTargetMilliseconds ?? budget.targetMilliseconds
                    },
                    recordSummary: { [weak self] fields in
                        self?.debugSessionDiagnostics.recordCompressionSummary(fields: fields)
                    },
                    onDecoded: { [weak self] record in
                        self?.receiveDecodedMusicRecord(record, streamID: streamID,
                                                        generation: round.generation) ?? false
                    })
            } catch {
                diagnostics.log(.error, category: .audio, message: "compression_decoder_create_failed",
                    fields: ["event": "compression_decoder_create_failed",
                             "round": "\(round.index)", "error": "\(error)"])
                return false
            }
        } else {
            newDecoder = nil
        }

        lock.lock()
        guard session.activeStreamID == streamID, playoutBudget != nil else {
            lock.unlock()
            newDecoder?.finish(reason: "round_rejected")
            return false
        }
        reliableSourceFloor = UInt64(round.firstSequence) * 120
        compressionSourceCoverage = round.isCompressionTest ? CompressionSourceCoverage(
            sourceBegin: UInt64(round.firstSequence) * 120,
            sourceEnd: UInt64(round.firstSequence) * 120 + UInt64(round.seconds * 48_000)) : nil
        timedPackets.removeAll(keepingCapacity: true)
        sourceAnchor = nil
        jitter = JitterBuffer(streamID: streamID, targetPackets: jitterTargetPackets,
            maximumPackets: max(256, Int(ceil(budget.maximumMilliseconds / 2.5))))
        playoutAdaptive = round.adaptive
        playoutMaximumCorrection = round.adaptive ? 0.05 : 0
        playoutController = PlayoutController(budget: budget,
            maximumCorrection: playoutMaximumCorrection, adaptive: playoutAdaptive)
        timeStretch.reset(); concealment.reset()
        concealingAtomic.store(0); dynamicCorrectionAtomic.store(Double(0).bitPattern)
        renderActiveAtomic.store(0); jitterFillFramesAtomic.store(0)
        renderRing.requestReset()
        compressionExpiredFramesAtStart = renderRing.expiredFrames
        lifecycle.enterSilentRebuffer(); session.enterSilentRebuffer()
        lastReceivedSequence = nil; loggedFirstAudioDatagram = false
        compressionMusicDecoder = newDecoder
        compressionMusicRound = round.isCompressionTest ? round : nil
        lock.unlock()
        return true
    }

    func receiveMusicRecord(_ record: TimedAudioRecord,
                            receivedAt: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock()
        guard compressionMusicRound?.version == 4, let decoder = compressionMusicDecoder else {
            lock.unlock(); return
        }
        lock.unlock()
        let mapped = mappedCapture(record, at: receivedAt)
        if let mapped, decoder.valid(record) {
            lock.lock()
            guard compressionMusicDecoder === decoder, session.activeStreamID == record.streamID else {
                lock.unlock(); return
            }
            playoutController?.observeArrival(sourceFrame: record.sourceFrame,
                capturedAt: mapped.0, receivedAt: receivedAt)
            lock.unlock()
        }
        decoder.receive(record, mappedCapturedAt: mapped?.0,
                        uncertainty: mapped?.1 ?? .max, receivedAt: receivedAt)
    }

    private func receiveDecodedMusicRecord(_ record: TimedAudioRecord,
                                           streamID: UInt32,
                                           generation: UInt32) -> Bool {
        compressionAdmissionLock.lock()
        defer { compressionAdmissionLock.unlock() }
        lock.lock()
        let isCurrentRound = compressionMusicRound?.generation == generation &&
            session.activeStreamID == streamID
        lock.unlock()
        guard isCurrentRound else { return false }
        return receiveTimedRecord(record) == .accepted
    }

    private var compressionDecodeTargetMilliseconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return playoutController?.targetMilliseconds ?? playoutBudget?.targetMilliseconds ?? 0
    }

    func endMusicRound(reason: String = "round_end") {
        compressionAdmissionLock.lock()
        lock.lock()
        let decoder = compressionMusicDecoder
        let round = compressionMusicRound
        let sourceFramesPrepared = compressionSourceCoverage?.preparedFrames ?? 0
        let longestMissingSourceFrames = compressionSourceCoverage?.longestMissingSourceFrames ?? 0
        let expiredFrames = max(0, Int(clamping: renderRing.expiredFrames &- compressionExpiredFramesAtStart))
        let firstSourceFrame = round.map { UInt64($0.firstSequence) * 120 } ?? 0
        let playedSourceEnd = renderRing.lastSourceFrame
        let playoutSourceFrames: Int
        if let playedSourceEnd, playedSourceEnd >= firstSourceFrame, let round {
            playoutSourceFrames = Int(min(UInt64(round.seconds * 48_000), playedSourceEnd - firstSourceFrame))
        } else {
            playoutSourceFrames = 0
        }
        compressionMusicDecoder = nil
        compressionMusicRound = nil
        compressionSourceCoverage = nil
        lock.unlock()
        compressionAdmissionLock.unlock()
        decoder?.finish(reason: reason, sourceFramesPrepared: sourceFramesPrepared,
                        longestMissingSourceFrames: longestMissingSourceFrames,
                        playoutExpiredOutputFrames: expiredFrames,
                        playoutSourceFrames: playoutSourceFrames)
    }

    @discardableResult
    public func observeClock(localSent: UInt64, remoteReceived: UInt64,
                              remoteSent: UInt64, localReceived: UInt64) -> Bool {
        lock.lock()
        if localReceived >= localSent, remoteSent >= remoteReceived,
           localReceived - localSent >= remoteSent - remoteReceived,
           localReceived >= (observedRoundTrip?.at ?? 0) {
            observedRoundTrip = (localReceived, (localReceived - localSent) - (remoteSent - remoteReceived))
        }
        let accepted = clockMapping.observe(localSent: localSent, remoteReceived: remoteReceived,
                              remoteSent: remoteSent, localReceived: localReceived)
        let age = clockMapping.ageNanoseconds(at: localReceived)
        let uncertainty = clockMapping.uncertainty(at: localReceived)
        renderRing.setClockUncertainty(nanoseconds: clockMapping.uncertainty(at: DispatchTime.now().uptimeNanoseconds))
        lock.unlock()
        debugSessionDiagnostics.recordClockExchange(localSent: localSent, remoteReceived: remoteReceived,
            remoteSent: remoteSent, localReceived: localReceived, accepted: accepted,
            mappingAge: age, uncertainty: uncertainty)
        return accepted
    }

    @discardableResult
    public func receiveTimedRecord(_ record: TimedAudioRecord) -> AudioDisposition? {
        guard record.frameCount == 120, record.payload.count == 960,
              record.kind == .audio || record.kind == .retransmission || record.kind == .repeated
        else { return nil }
        guard let packet = try? AudioDatagram(streamID: record.streamID,
                                              sequence: record.sequence, pcm: record.payload) else {
            return nil
        }
        return receiveDatagram(packet.encoded, timedRecord: record)
    }

    func mappedCapture(_ record: TimedAudioRecord, at now: UInt64) -> (UInt64, UInt64)? {
        lock.lock(); defer { lock.unlock() }
        guard let timestamp = clockMapping.map(remoteNanoseconds: record.capturedAt, at: now) else { return nil }
        return (timestamp, clockMapping.uncertainty(at: now, remoteNanoseconds: record.capturedAt))
    }

    var clockUncertainty: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return clockMapping.uncertainty(at: DispatchTime.now().uptimeNanoseconds)
    }

    var estimatedRoundTrip: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return clockMapping.uncertaintyNanoseconds * 2
    }

    public func progressTiming() -> AudioProgressTiming? {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        guard let generated = clockMapping.remote(localNanoseconds: now, at: now) else { return nil }
        return AudioProgressTiming(playedSourceFrame: renderRing.lastSourceFrame, generatedAt: generated,
            bufferedMilliseconds: UInt32(min(2000, renderFillFrames / 48)))
    }

    @discardableResult
    public func markAuthenticated() -> Bool {
        lock.lock()
        let accepted = session.markAuthenticated()
        let phase = session.phase
        lock.unlock()
        diagnostics.log(
            accepted ? .info : .warning,
            category: .pairing,
            message: accepted ? "authentication_accepted" : "authentication_rejected",
            fields: [
                "event": accepted ? "authentication_accepted" : "authentication_rejected",
                "phase": "\(phase)"
            ]
        )
        return accepted
    }

    @discardableResult
    public func acknowledgeStartStream(_ streamID: UInt32) -> Bool {
        lock.lock()
        let accepted = session.ackWritten(streamID)
        let phase = session.phase
        lock.unlock()
        diagnostics.log(
            accepted ? .info : .warning,
            category: .control,
            message: accepted ? "start_stream_acknowledged" : "start_stream_ack_rejected",
            fields: [
                "event": accepted ? "start_stream_acknowledged" : "start_stream_ack_rejected",
                "stream_id": "\(streamID)",
                "phase": "\(phase)"
            ]
        )
        return accepted
    }

    @discardableResult
    public func receiveDatagram(_ data: Data, timedRecord: TimedAudioRecord? = nil) -> AudioDisposition? {
        realtimeMetrics.recordDatagram(byteCount: data.count)
        let receivedAt = DispatchTime.now().uptimeNanoseconds
        let packet: AudioDatagram
        do {
            packet = try AudioDatagram(encoded: data)
        } catch {
            lock.lock()
            invalidDatagrams += 1
            lock.unlock()
            realtimeMetrics.recordInvalidDatagram()
            _ = diagnostics.logAsync(
                .warning,
                category: .audio,
                message: "datagram_rejected",
                fields: [
                    "event": "invalid_datagram",
                    "bytes": "\(data.count)",
                    "reason": "\(error)"
                ]
            )
            return nil
        }

        var firstFields: [String: String]?
        var transitionFields: [String: String]?
        var jitterResult: JitterInsertResult?
        var trimmedSequences: [UInt32] = []
        var fillPackets = 0
        var disposition: AudioDisposition
        lock.lock()
        if let record = timedRecord, record.sourceFrame < reliableSourceFloor {
            lock.unlock(); return nil
        }
        let captured = timedRecord.flatMap { clockMapping.map(remoteNanoseconds: $0.capturedAt, at: receivedAt) }
        if timedRecord != nil && captured == nil {
            lock.unlock()
            debugSessionDiagnostics.recordClockUnavailablePacket()
            return nil
        }
        disposition = session.acceptAudio(packet)
        realtimeMetrics.recordDisposition(disposition)
        if disposition == .accepted {
            lastReceivedSequence = packet.sequence
        }
        if disposition == .accepted {
            let previousMode = jitter?.mode
            let previousTrimmedPackets = jitter?.stats.trimmedPackets ?? 0
            let stagedBeforeInsert = max(0, renderRing.fillFrames -
                                         AudioDatagram.framesPerPacket)
            if let insertResult = jitter?.insert(packet, stagedFrames: stagedBeforeInsert) {
                jitterResult = insertResult
                if insertResult == .inserted, let timedRecord, let captured {
                    timedPackets[packet.sequence] = (timedRecord, captured,
                        clockMapping.uncertainty(at: receivedAt, remoteNanoseconds: timedRecord.capturedAt))
                    if sourceAnchor == nil { sourceAnchor = (packet.sequence, timedRecord.sourceFrame) }
                }
                if compressionMusicRound == nil && liveAudioDecoder == nil,
                   insertResult == .inserted || insertResult == .late, let timedRecord, let captured {
                    playoutController?.observeArrival(sourceFrame: timedRecord.sourceFrame,
                        capturedAt: captured, receivedAt: receivedAt, original: timedRecord.kind == .audio)
                }
                let started = playoutController == nil ? (jitter?.startIfReady() ?? false) : false
                pumpLocked()
                jitter?.trimToTarget(stagedFrames: renderRing.sourceFillFrames)
                let trimmedPackets = (jitter?.stats.trimmedPackets ?? 0) - previousTrimmedPackets
                trimmedSequences = jitter?.takeTrimmedSequences() ?? []
                for sequence in trimmedSequences { timedPackets.removeValue(forKey: sequence) }
                fillPackets = jitter?.fillPackets ?? 0
                realtimeMetrics.recordJitterResult(insertResult,
                                                   fillPackets: fillPackets,
                                                   trimmedPackets: trimmedPackets)
                if started && previousMode != jitter?.mode {
                    transitionFields = [
                        "event": "jitter_started",
                        "stream_id": "\(packet.streamID)",
                        "sequence": "\(packet.sequence)",
                        "jitter_mode": "\(jitter!.mode)",
                        "target_packets": "\(jitter!.targetPackets)",
                        "buffer_packets": "\(fillPackets)"
                    ]
                }
                if !loggedFirstAudioDatagram {
                    loggedFirstAudioDatagram = true
                    firstFields = [
                        "event": "datagram_received",
                        "stream_id": "\(packet.streamID)",
                        "sequence": "\(packet.sequence)",
                        "audio_bytes": "\(packet.pcm.count)",
                        "jitter_result": "\(insertResult)",
                        "jitter_mode": "\(jitter!.mode)",
                        "buffer_packets": "\(fillPackets)",
                        "buffer_started": "\(started)"
                    ]
                }
            }
        }
        jitterFillFramesAtomic.store(UInt64((playoutController == nil
            ? (jitter?.fillPackets ?? 0) : (jitter?.contiguousPackets ?? 0)) *
                                            AudioDatagram.framesPerPacket))
        lock.unlock()

        debugSessionDiagnostics.recordPacket(
            streamID: packet.streamID,
            sequence: packet.sequence,
            receivedAt: receivedAt,
            disposition: disposition,
            jitterResult: jitterResult,
            fillPackets: fillPackets
        )
        for sequence in trimmedSequences {
            debugSessionDiagnostics.recordJitterDecision(
                streamID: packet.streamID,
                sequence: sequence,
                decision: .trimmed,
                at: receivedAt,
                fillPackets: fillPackets
            )
        }

        if let firstFields {
            _ = diagnostics.logAsync(.debug,
                                     category: .audio,
                                     message: "datagram_received",
                                     fields: firstFields)
        }
        if let transitionFields {
            _ = diagnostics.logAsync(.info,
                                     category: .realtime,
                                     message: "jitter_started",
                                     fields: transitionFields)
        }
        return disposition
    }

    public func handleAudioLifecycle(_ event: AudioLifecycleEvent) {
        lock.lock()
        let previousState = lifecycle.state
        lifecycle.handle(event)
        switch event {
        case .interruptionBegan:
            renderActiveAtomic.store(0)
            renderRing.requestReset()
            jitter?.enterSilentRebuffer()
            session.enterInterruption()
        case .routeChanged:
            renderActiveAtomic.store(0)
            renderRing.requestReset()
            jitter?.enterSilentRebuffer()
            session.enterInterruption()
            session.recoverToRebuffer()
        case .interruptionEnded:
            session.recoverToRebuffer()
        case .audioAvailable:
            break
        }
        let state = lifecycle.state
        let generation = lifecycle.resetGeneration
        jitterFillFramesAtomic.store(UInt64((playoutController == nil
            ? (jitter?.fillPackets ?? 0) : (jitter?.contiguousPackets ?? 0)) *
                                            AudioDatagram.framesPerPacket))
        lock.unlock()
        diagnostics.log(
            .info,
            category: .audio,
            message: "audio_lifecycle",
            fields: [
                "event": Self.diagnosticName(for: event),
                "previous_state": "\(previousState)",
                "state": "\(state)",
                "reset_generation": "\(generation)"
            ]
        )
    }

    public func enterSilentRebuffer() {
        lock.lock()
        jitter?.enterSilentRebuffer()
        session.enterSilentRebuffer()
        lifecycle.enterSilentRebuffer()
        renderActiveAtomic.store(0)
        jitterFillFramesAtomic.store(0)
        renderRing.requestReset()
        let phase = session.phase
        let state = lifecycle.state
        lock.unlock()
        diagnostics.log(
            .info,
            category: .audio,
            message: "silent_rebuffer_entered",
            fields: [
                "event": "silent_rebuffer_entered",
                "phase": "\(phase)",
                "state": "\(state)"
            ]
        )
    }

    public func renderFrames(_ frameCount: Int) -> [Float] {
        guard frameCount > 0 else { return [] }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let output = renderRing.pop(frames: frameCount)
        renderRequestFramesAtomic.store(UInt64(frameCount))
        renderStartedAtAtomic.storeReleasing(startedAt)
        realtimeMetrics.recordRenderBuffer(
            fillFrames: renderRing.fillFrames,
            underflowFrames: frameCount - output.renderedFrames,
            overflowFrames: 0
        )
        return output.samples
    }

    private func pumpLocked() {
        guard jitter != nil, renderRing.isResetAcknowledged else { return }
        if playoutController != nil { pumpCoordinatedLocked(); return }
        while renderRing.fillFrames + AudioDatagram.framesPerPacket <= ringReserveFrames {
            if let packet = jitter?.consumeNext() {
                renderRing.push(Self.decodePCM(packet.pcm))
            } else if jitter?.hasFuturePacket == true,
                      let sequence = jitter?.expectedSequence,
                      let concealed = jitter?.concealMissing() {
                realtimeMetrics.recordConcealment()
                debugSessionDiagnostics.recordJitterDecision(
                    streamID: jitter!.streamID,
                    sequence: sequence,
                    decision: .concealed,
                    at: DispatchTime.now().uptimeNanoseconds,
                    fillPackets: jitter!.fillPackets
                )
                renderRing.push(Self.decodePCM(concealed))
            } else {
                break
            }
        }
        if jitter?.mode == .running, renderRing.fillFrames > 0 {
            lifecycle.handle(.audioAvailable)
            renderActiveAtomic.store(1)
        } else if renderRing.fillFrames == 0, jitter?.fillPackets == 0,
                  jitter?.mode == .running {
            jitter?.enterSilentRebuffer()
            session.enterSilentRebuffer()
            lifecycle.enterSilentRebuffer()
            renderActiveAtomic.store(0)
        }
    }

    private func sourcePosition(for sequence: UInt32) -> UInt64? {
        if let stored = timedPackets[sequence] { return stored.record.sourceFrame }
        guard let anchor = sourceAnchor else { return nil }
        let delta = Int64(Int32(bitPattern: sequence &- anchor.sequence)) * 120
        if delta < 0 { return anchor.frame >= UInt64(-delta) ? anchor.frame - UInt64(-delta) : nil }
        return anchor.frame <= UInt64.max - UInt64(delta) ? anchor.frame + UInt64(delta) : nil
    }

    private func pumpCoordinatedLocked() {
        let now = DispatchTime.now().uptimeNanoseconds
        let startedAt = renderStartedAtAtomic.loadAcquiring()
        let request = max(1, renderRequestFramesAtomic.load())
        let period = request * 1_000_000_000 / 48_000
        let elapsed = now >= startedAt ? now - startedAt : 0
        let untilNext = period > elapsed ? period - elapsed : 0
        // Cover callbacks due before the 5 ms preparation timer and its 1 ms leeway.
        let horizon: UInt64 = 6_000_000
        let demand = untilNext > horizon ? 0 : Int((horizon - untilNext) / period + 1) * Int(request)
        renderRing.setClockUncertainty(nanoseconds: clockMapping.uncertainty(at: now))
        guard let expected = jitter?.expectedSequence, let source = sourcePosition(for: expected) else { return }
        guard let decision = playoutController?.decision(now: now, nextSourceFrame: source,
            playableFrames: (jitter?.contiguousPackets ?? 0) * 120,
            stagedSourceFrames: renderRing.sourceFillFrames,
            uncertaintyNanoseconds: clockMapping.uncertainty(at: now),
            hasFuturePacket: jitter?.hasFuturePacket == true,
            minimumBufferMilliseconds: Double(request) / 48 + 6) else { return }
        let target = jitter?.mode == .running ? max(1, Int(ceil(decision.bufferTargetMilliseconds / 2.5))) :
            decision.startupTargetPackets(now: now)
        let recovery = max(target, Int(((playoutBudget?.maximumMilliseconds ?? 100) -
                                        (playoutBudget?.outputReserveMilliseconds ?? 10)) / 2.5))
        jitter?.setTargetPackets(target, recoveryPackets: recovery)
        targetFramesAtomic.store(UInt64(target * 120))
        dynamicCorrectionAtomic.store(decision.correction.bitPattern)
        ringReserveFrames = min(renderRing.capacityFrames, 2_048, max(120, target * 120))
        if decision.action == .resync, let budget = playoutBudget {
            let ordered = (jitter?.bufferedSequences ?? []).sorted { ($0 &- expected) < ($1 &- expected) }
            if let next = ordered.first(where: {
                guard let stored = timedPackets[$0] else { return false }
                return budget.prepareDeadline(capturedAt: stored.capturedAt,
                    uncertaintyNanoseconds: max(stored.uncertainty, clockMapping.uncertainty(at: now))) > now
            }) {
                jitter?.skip(to: next)
            } else if let last = ordered.last {
                jitter?.skip(to: SequenceNumber.next(last))
            }
            for sequence in jitter?.takeTrimmedSequences() ?? [] {
                timedPackets.removeValue(forKey: sequence)
                debugSessionDiagnostics.recordJitterDecision(streamID: jitter!.streamID,
                    sequence: sequence, decision: .trimmed, at: now, fillPackets: jitter!.fillPackets)
            }
        }
        _ = jitter?.startIfReady(allowGaps: decision.action == .conceal || decision.action == .resync)
        var prepared = 0
        while renderRing.fillFrames + 120 <= ringReserveFrames, prepared < 256,
              let sequence = jitter?.expectedSequence, let position = sourcePosition(for: sequence) {
            prepared += 1
            let stored = timedPackets[sequence]
            let captured = stored?.capturedAt ?? playoutController?.captureTime(sourceFrame: position)
            guard let captured, let budget = playoutBudget else { break }
            let deadline = budget.prepareDeadline(capturedAt: captured,
                uncertaintyNanoseconds: max(stored?.uncertainty ?? 0, clockMapping.uncertainty(at: now)))
            let presentation = now + untilNext + UInt64(renderRing.fillFrames) * 1_000_000_000 / 48_000
            if deadline <= presentation {
                jitter?.skip(to: SequenceNumber.next(sequence))
                timedPackets.removeValue(forKey: sequence)
                continue
            }
            if abs(decision.correction) > 0.001,
               (jitter?.contiguousPackets ?? 0) > 0, (jitter?.contiguousPackets ?? 0) < 6,
               renderRing.fillFrames > max(demand, Int(request) + 240) {
                break
            }
            if let packet = jitter?.consumeNext() {
                timedPackets.removeValue(forKey: sequence)
                var samples = Self.decodePCM(packet.pcm)
                var sourceEnd = position + 120
                var renderDeadline = deadline
                if abs(decision.correction) > 0.001,
                   renderRing.fillFrames + 840 <= renderRing.capacityFrames,
                   (jitter?.contiguousPackets ?? 0) >= 5 {
                    let following = (1...5).map { sequence &+ UInt32($0) }
                    let valid = following.allSatisfy { key in
                        guard let item = timedPackets[key] else { return false }
                        return budget.prepareDeadline(capturedAt: item.capturedAt,
                            uncertaintyNanoseconds: max(item.uncertainty, clockMapping.uncertainty(at: now))) > now
                    }
                    if valid {
                        for key in following {
                            guard let next = jitter?.consumeNext() else { break }
                            samples += Self.decodePCM(next.pcm)
                            if let item = timedPackets[key] {
                                let itemDeadline = budget.prepareDeadline(capturedAt: item.capturedAt,
                                    uncertaintyNanoseconds: max(item.uncertainty, clockMapping.uncertainty(at: now)))
                                let advance = (sourceEnd - position) * 1_000_000_000 / 48_000
                                renderDeadline = min(renderDeadline, itemDeadline > advance ? itemDeadline - advance : 0)
                            }
                            timedPackets.removeValue(forKey: key)
                            sourceEnd += 120
                        }
                    }
                }
                samples = timeStretch.process(samples, correction: decision.correction)
                // Uniform source labels can be newer than a splice's oldest contributing sample.
                let spliceMargin = UInt64(abs(Int(sourceEnd - position) - samples.count / 2)) * 1_000_000_000 / 48_000
                renderDeadline = renderDeadline > spliceMargin ? renderDeadline - spliceMargin : 0
                compressionSourceCoverage?.recordPrepared(sourceBegin: position, sourceEnd: sourceEnd)
                concealingAtomic.store(0)
                renderRing.pushTimed(concealment.accept(samples), sourceBegin: position,
                                      sourceEnd: sourceEnd, capturedAt: captured, deadline: renderDeadline)
            } else if jitter?.mode == .running,
                      (deadline <= now || renderRing.fillFrames < demand),
                      jitter?.concealMissing() != nil {
                realtimeMetrics.recordConcealment()
                debugSessionDiagnostics.recordJitterDecision(streamID: jitter!.streamID,
                    sequence: sequence, decision: .concealed, at: now, fillPackets: jitter!.fillPackets)
                concealingAtomic.store(1)
                renderRing.pushTimed(concealment.conceal(frames: 120), sourceBegin: position,
                                      sourceEnd: position + 120, capturedAt: captured, deadline: .max)
            } else { break }
        }
        jitterFillFramesAtomic.store(UInt64((jitter?.contiguousPackets ?? 0) * 120))
        if jitter?.mode == .running, renderRing.fillFrames > 0 {
            lifecycle.handle(.audioAvailable)
            renderActiveAtomic.store(1)
        } else if renderRing.fillFrames == 0, jitter?.fillPackets == 0, jitter?.mode == .running {
            jitter?.enterSilentRebuffer()
            timedPackets.removeAll(keepingCapacity: true)
            sourceAnchor = nil
        timeStretch.reset()
        concealment.reset()
        concealingAtomic.store(0)
        dynamicCorrectionAtomic.store(Double(0).bitPattern)
            session.enterSilentRebuffer()
            lifecycle.enterSilentRebuffer()
            renderActiveAtomic.store(0)
        }
    }

    private func startPumpTimerLocked() {
        guard pumpTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: pumpQueue)
        timer.schedule(deadline: .now() + .milliseconds(5),
                       repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pumpLocked()
            self.jitterFillFramesAtomic.store(UInt64((self.playoutController == nil
                ? (self.jitter?.fillPackets ?? 0) : (self.jitter?.contiguousPackets ?? 0)) *
                                                     AudioDatagram.framesPerPacket))
            self.lock.unlock()
        }
        pumpTimer = timer
        timer.resume()
    }

    private func startRealtimeReporter() {
        let timer = DispatchSource.makeTimerSource(queue: realtimeReporterQueue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.emitRealtimeDiagnostics()
        }
        timer.resume()
        realtimeReporter = timer
    }

    func emitRealtimeDiagnosticsForTesting() {
        emitRealtimeDiagnostics()
    }

    private func emitRealtimeDiagnostics() {
        guard lock.try() else {
            realtimeMetrics.recordReporterSkipped()
            return
        }
        let phase = session.phase
        let shouldReport = jitter != nil || phase != .awaitingConnect
        guard shouldReport else {
            lock.unlock()
            return
        }
        let buffer = jitter
        let streamID = buffer?.streamID ?? session.activeStreamID ?? session.pendingStreamID
        let lastSequence = lastReceivedSequence
        let expectedSequence = buffer?.expectedSequence
        let mode = buffer?.mode
        let targetPackets = buffer?.targetPackets ?? jitterTargetPackets
        let jitterFillPackets = buffer?.fillPackets ?? 0
        let renderFill = renderRing.fillFrames
        let lifecycleState = lifecycle.state
        let route = outputRoute
        let sampleRate = outputSampleRate
        let stretchInput = timeStretch.inputFrames
        let stretchOutput = timeStretch.outputFrames
        let requestedCorrection = dynamicCorrection
        let expiredFrames = renderRing.expiredFrames
        lock.unlock()

        let diagnosticsDropped = diagnostics.snapshot().asyncDroppedCount
        let snapshot = realtimeMetrics.snapshotAndReset(
            streamID: streamID,
            lastSequence: lastSequence,
            expectedSequence: expectedSequence,
            jitterMode: mode,
            jitterTargetPackets: targetPackets,
            jitterFillPackets: jitterFillPackets,
            renderFillFrames: renderFill,
            sessionPhase: phase,
            lifecycleState: lifecycleState,
            outputRoute: route,
            sampleRate: sampleRate,
            diagnosticsDropped: diagnosticsDropped
        )
        let level: DiagnosticsLevel = debugSessionDiagnostics.isRecording ? .info : .debug
        _ = diagnostics.logAsync(
            level,
            category: .realtime,
            message: "realtime_summary",
            fields: snapshot.fields.merging([
                "requested_correction": "\(requestedCorrection)",
                "stretch_input_frames": "\(stretchInput)",
                "stretch_output_frames": "\(stretchOutput)",
                "output_expired_frames": "\(expiredFrames)"
            ]) { _, value in value }
        )
    }

    private static func decodePCM(_ pcm: Data) -> [Float] {
        guard pcm.count == AudioDatagram.pcmByteCount else { return [] }
        var samples: [Float] = []
        samples.reserveCapacity(pcm.count / 4)
        var offset = 0
        while offset < pcm.count {
            let bits = UInt32(pcm[offset]) |
                (UInt32(pcm[offset + 1]) << 8) |
                (UInt32(pcm[offset + 2]) << 16) |
                (UInt32(pcm[offset + 3]) << 24)
            samples.append(Float(bitPattern: bits))
            offset += 4
        }
        return samples
    }

    private static func diagnosticName(for event: AudioLifecycleEvent) -> String {
        switch event {
        case .interruptionBegan: return "interruption_began"
        case .interruptionEnded: return "interruption_ended"
        case .routeChanged: return "route_changed"
        case .audioAvailable: return "audio_available"
        }
    }
}

#if canImport(Network)
import Network
import Security

public enum QuicReceiverState: Equatable, Sendable {
    case idle
    case connecting
    case ready
    case failed
    case closed
}

public enum QuicTransportError: Error, Equatable {
    case controlStreamUnavailable
    case malformedTLSIdentity
}

public enum TLSIdentityPolicy: Sendable {
    case pairing(onPeerSPKIHash: @Sendable (Data) -> Void)
    case remembered(spkiSHA256: Data)
}

public final class HearPortQuicTransport {
    public static let alpn = "hearport/1"
    public static let defaultPort: UInt16 = 52_137

    public typealias DataHandler = @Sendable (Data) -> Void
    public typealias StateHandler = @Sendable (QuicReceiverState) -> Void

    public private(set) var state: QuicReceiverState = .idle
    public var onControlData: DataHandler?
    public var onAudioDatagram: DataHandler?
    public var audioProgressTiming: (() -> AudioProgressTiming?)?
    public var onProbePacket: (@Sendable (Data, UInt64, Int, Int) -> Void)?
    public var onMusicRoundEnded: ((UInt32) -> Void)?
    public var onProbeTick: (@Sendable (UInt64) -> Void)?
    public var onProbeHeartbeat: (@Sendable (UInt64, UInt64) -> Void)?
    public var onReliableAudioGeneration: ((UInt32, UInt32) -> Bool)?
    public var onStateChange: StateHandler?
    public var onControlStreamCreated: (() -> Void)?

    private let queue = DispatchQueue(label: "com.hearport.quic")
    private let diagnostics: HearPortDiagnostics
    private var group: NWConnectionGroup?
    private var controlStream: NWConnection?
    private var controlReady = false
    private var datagramReady = false
    private var loggedFirstDatagram = false
    private let audioMode: AudioTransportMode
    private var reliableAccepted = false
    private var coordinatedAudio = false
    private var networkProbe = false
    private var musicTest = false
    private var musicReliable = false
    private var musicFramed = false
    private var liveFramed = false
    private var musicGeneration: UInt32 = 0
    private var probeTimer: DispatchSourceTimer?
    private var probeHeartbeatScheduledAt: UInt64 = 0
    private var expectedAudioStreamID: UInt32?
    private var audioStream: NWConnection?
    private var audioGeneration: UInt32 = 0
    private var progressSequence: (() -> UInt32?)?
    private var progressTimer: DispatchSourceTimer?
    private var attemptID = UUID()
    private var progressInFlight = false

    public init(diagnostics: HearPortDiagnostics = .shared,
                audioMode: AudioTransportMode = .datagram) {
        self.diagnostics = diagnostics
        self.audioMode = audioMode
        diagnostics.log(
            .debug,
            category: .transport,
            message: "transport_initialized",
            fields: ["event": "transport_initialized"]
        )
    }

    public func connect(
        host: String,
        port: UInt16 = defaultPort,
        tlsPolicy: TLSIdentityPolicy,
        endpoint suppliedEndpoint: NWEndpoint? = nil
    ) {
        let policyName: String
        switch tlsPolicy {
        case .pairing: policyName = "pairing"
        case .remembered: policyName = "remembered"
        }
        diagnostics.log(
            .info,
            category: .transport,
            message: "connect_requested",
            fields: [
                "event": "connect_requested",
                "host": host,
                "port": "\(port)",
                "tls_policy": policyName
            ]
        )
        cancel(notify: false)
        let attemptID = self.attemptID
        let endpoint = suppliedEndpoint ?? NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let quicOptions = NWProtocolQUIC.Options(alpn: [Self.alpn])
        quicOptions.direction = .bidirectional
        quicOptions.isDatagram = true
        // The transport limit includes the QUIC frame header, not just audio bytes.
        quicOptions.maxDatagramFrameSize = 65_535
        quicOptions.initialMaxStreamsUnidirectional =
            audioMode == .reliable ? 65_535 : 1
        sec_protocol_options_set_tls_resumption_enabled(
            quicOptions.securityProtocolOptions,
            false
        )
        sec_protocol_options_set_tls_tickets_enabled(
            quicOptions.securityProtocolOptions,
            false
        )
        sec_protocol_options_set_verify_block(
            quicOptions.securityProtocolOptions,
            { metadata, _, complete in
                guard self.attemptID == attemptID else { complete(false); return }
                guard let certificateData = Self.peerSPKI(from: metadata),
                      let spkiHash = try? PairingSecurity.windowsSPKIHash(certificateData)
                else {
                    self.diagnostics.log(
                        .warning,
                        category: .security,
                        message: "tls_identity_rejected",
                        fields: [
                            "event": "tls_identity_rejected",
                            "reason": "missing_or_malformed_peer_identity",
                            "tls_policy": policyName
                        ]
                    )
                    complete(false)
                    self.updateState(.failed); self.group?.cancel()
                    return
                }
                let accepted: Bool
                switch tlsPolicy {
                case let .pairing(onPeerSPKIHash):
                    onPeerSPKIHash(spkiHash)
                    accepted = true
                case let .remembered(expectedSPKIHash):
                    accepted = PairingSecurity.constantTimeEqual(spkiHash, expectedSPKIHash)
                }
                self.diagnostics.log(
                    accepted ? .info : .warning,
                    category: .security,
                    message: accepted ? "tls_identity_accepted" : "tls_identity_rejected",
                    fields: [
                        "event": accepted ? "tls_identity_accepted" : "tls_identity_rejected",
                        "spki_bytes": "\(spkiHash.count)",
                        "tls_policy": policyName
                    ]
                )
                complete(accepted)
                if !accepted { self.updateState(.failed); self.group?.cancel() }
            },
            queue
        )
        let parameters = NWParameters(quic: quicOptions)
        let multiplex = NWMultiplexGroup(to: endpoint)
        let connectionGroup = NWConnectionGroup(with: multiplex,
                                                 using: parameters)
        // Stream options must preserve the tunnel's TLS and transport parameters.
        let controlOptions = parameters.copy().defaultProtocolStack.transportProtocol as! NWProtocolQUIC.Options
        controlOptions.direction = .bidirectional
        controlOptions.isDatagram = false
        group = connectionGroup
        state = .connecting
        diagnostics.log(
            .info,
            category: .transport,
            message: "transport_connecting",
            fields: ["event": "transport_connecting", "host": host, "port": "\(port)"]
        )
        onStateChange?(.connecting)

        connectionGroup.stateUpdateHandler = { [weak self, weak connectionGroup] newState in
            guard let self, let connectionGroup,
                  let activeGroup = self.group,
                  activeGroup === connectionGroup else { return }
            switch newState {
            case .ready:
                self.datagramReady = true
                self.diagnostics.log(
                    .info,
                    category: .transport,
                    message: "datagram_group_ready",
                    fields: ["event": "datagram_group_ready"]
                )
                self.openControlStream(
                    connectionGroup: connectionGroup,
                    options: controlOptions
                )
            case let .waiting(error):
                self.diagnostics.log(
                    .warning,
                    category: .transport,
                    message: "transport_waiting",
                    fields: [
                        "event": "transport_waiting",
                        "error": "\(error)"
                    ]
                )
            case let .failed(error):
                self.diagnostics.log(
                    .error,
                    category: .transport,
                    message: "transport_failed",
                    fields: [
                        "event": "transport_failed",
                        "error": "\(error)"
                    ]
                )
                self.updateState(.failed)
            case .cancelled:
                self.updateState(.closed)
            default:
                break
            }
        }
        connectionGroup.newConnectionHandler = { [weak self, weak connectionGroup] connection in
            guard let self, let connectionGroup,
                  let activeGroup = self.group,
                  activeGroup === connectionGroup,
                  (self.networkProbe || (self.musicTest ? self.musicReliable : self.audioMode == .reliable)),
                  self.reliableAccepted, let streamID = self.expectedAudioStreamID else {
                connection.cancel()
                return
            }
            if self.networkProbe || self.liveFramed || (self.musicTest && self.musicFramed) {
                self.receiveProbe(on: connection,
                                  records: ReliableProbeRecords(expectedStreamID: streamID),
                                  connectionGroup: connectionGroup)
            } else {
                self.receiveAudio(on: connection,
                                  records: ReliableAudioRecords(expectedStreamID: streamID,
                                                                timed: self.coordinatedAudio),
                                  connectionGroup: connectionGroup)
            }
            connection.start(queue: self.queue)
        }
        connectionGroup.setReceiveHandler(
            maximumMessageSize: 1024,
            rejectOversizedMessages: true
        ) { [weak self, weak connectionGroup] _, data, isComplete in
            let receivedAt = DispatchTime.now().uptimeNanoseconds
            guard let self, let connectionGroup,
                  let activeGroup = self.group,
                  activeGroup === connectionGroup else { return }
            if let data {
                let isFirst = !self.loggedFirstDatagram
                self.loggedFirstDatagram = true
                if isFirst {
                    _ = self.diagnostics.logAsync(
                        .debug,
                        category: .audio,
                        message: "datagram_read",
                        fields: [
                            "event": "datagram_read",
                            "bytes": "\(data.count)",
                            "is_complete": "\(isComplete)"
                        ]
                    )
                }
                if self.networkProbe {
                    self.onProbePacket?(data, receivedAt, data.count, 1)
                } else if self.musicTest ? !self.musicReliable : self.audioMode == .datagram {
                    self.onAudioDatagram?(data)
                }
            }
        }
        connectionGroup.start(queue: queue)
    }

    func perform(_ action: @escaping () -> Void) { queue.async(execute: action) }

    public func sendControl(
        _ payload: Data,
        completion: @escaping @Sendable (NWError?) -> Void = { _ in }
    ) throws {
        let framed = try ControlFraming.encode(payload)
        guard let controlStream else { throw QuicTransportError.controlStreamUnavailable }
        diagnostics.log(
            .debug,
            category: .control,
            message: "control_write",
            fields: [
                "event": "control_write",
                "payload_bytes": "\(payload.count)",
                "framed_bytes": "\(framed.count)"
            ]
        )
        controlStream.send(content: framed,
                           contentContext: .defaultMessage,
                           isComplete: false,
                           completion: .contentProcessed { error in
                               completion(error)
                           })
    }

    public func cancel(notify: Bool = true) {
        attemptID = UUID()
        probeTimer?.cancel()
        probeTimer = nil
        progressTimer?.cancel()
        progressTimer = nil
        audioStream?.cancel()
        audioStream = nil
        expectedAudioStreamID = nil
        audioGeneration = 0
        progressSequence = nil
        progressInFlight = false
        reliableAccepted = false
        coordinatedAudio = false
        networkProbe = false
        musicTest = false; musicReliable = false; musicFramed = false; musicGeneration = 0
        liveFramed = false
        controlStream?.cancel()
        group?.cancel()
        controlStream = nil
        group = nil
        controlReady = false
        datagramReady = false
        loggedFirstDatagram = false
        diagnostics.log(
            .info,
            category: .transport,
            message: "transport_cancelled",
            fields: ["event": "transport_cancelled"]
        )
        if notify { updateState(.closed) } else { state = .idle }
    }

    public func acceptReliableAudio() {
        reliableAccepted = true
    }

    public func enableMusicTest() { musicTest = true; reliableAccepted = true }
    func configureLiveAudio(_ format: AudioStreamFormat) { liveFramed = format.opus }

    func prepareMusicRound(_ round: MusicTestRound) {
        audioStream?.cancel(); audioStream = nil
        progressTimer?.cancel(); progressTimer = nil; progressInFlight = false
        musicReliable = round.reliable
        musicFramed = round.isCompressionTest
        musicGeneration = round.generation
        audioGeneration = 0
    }

    public func enableNetworkProbe() {
        networkProbe = true
        reliableAccepted = true
        probeTimer?.cancel()
        probeHeartbeatScheduledAt = DispatchTime.now().uptimeNanoseconds + 100_000_000
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: DispatchTime(uptimeNanoseconds: probeHeartbeatScheduledAt),
                       repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            self.onProbeTick?(now)
            let scheduled = self.probeHeartbeatScheduledAt
            guard now >= scheduled else { return }
            self.onProbeHeartbeat?(now, scheduled)
            let elapsed = now > scheduled ? now - scheduled : 0
            self.probeHeartbeatScheduledAt = scheduled + (elapsed / 100_000_000 + 1) * 100_000_000
        }
        probeTimer = timer
        timer.resume()
    }

    public func noteProbeGeneration(_ generation: UInt32) {
        if audioGeneration == 0 || SequenceNumber.isBefore(audioGeneration, generation) {
            audioStream?.cancel()
            audioStream = nil
            audioGeneration = generation
        }
        startProgressTimer()
    }

    public func expectReliableAudio(streamID: UInt32,
                                    latestReceivedSequence: @escaping () -> UInt32?) {
        progressTimer?.cancel()
        progressTimer = nil
        audioStream?.cancel()
        audioStream = nil
        audioGeneration = 0
        expectedAudioStreamID = streamID
        progressSequence = latestReceivedSequence
    }

    public func acceptCoordinatedAudio() { coordinatedAudio = true }

    private func receiveProbe(on stream: NWConnection, records: ReliableProbeRecords,
                              connectionGroup: NWConnectionGroup) {
        stream.receive(minimumIncompleteLength: 1, maximumLength: 65_540) {
            [weak self] data, _, isComplete, error in
            let receivedAt = DispatchTime.now().uptimeNanoseconds
            guard let self, let activeGroup = self.group,
                  activeGroup === connectionGroup else { return }
            guard self.expectedAudioStreamID == records.expectedStreamID else {
                stream.cancel()
                return
            }
            var records = records
            do {
                let packets = try records.append(data ?? Data())
                if self.musicTest, let generation = records.generation,
                   SequenceNumber.isBefore(generation, self.musicGeneration) {
                    stream.cancel(); return
                }
                if self.musicTest, self.musicFramed, let generation = records.generation,
                   generation != self.musicGeneration {
                    stream.cancel(); return
                }
                if let generation = records.generation, (self.audioGeneration == 0 || SequenceNumber.isBefore(self.audioGeneration, generation) ||
                    (self.audioGeneration == generation && self.audioStream == nil)) {
                    self.audioStream?.cancel()
                    if self.liveFramed && self.onReliableAudioGeneration?(records.expectedStreamID, generation) != true {
                        throw ReliableAudioRecordsError.invalidPreface
                    }
                    self.audioStream = stream
                    self.audioGeneration = generation
                    if self.liveFramed || (self.musicTest && self.musicFramed) { self.startProgressTimer() }
                }
                guard self.audioStream === stream || records.generation == nil else {
                    stream.cancel()
                    return
                }
                for packet in packets {
                    if self.liveFramed || (self.musicTest && self.musicFramed) {
                        self.onAudioDatagram?(packet)
                    } else {
                        self.onProbePacket?(packet, receivedAt, data?.count ?? 0, packets.count)
                    }
                }
                if isComplete || error != nil {
                    try records.finish()
                    if self.musicTest && self.musicFramed, let generation = records.generation {
                        self.onMusicRoundEnded?(generation)
                    }
                    if self.audioStream === stream { self.audioStream = nil }
                    stream.cancel()
                    return
                }
                self.receiveProbe(on: stream, records: records,
                                  connectionGroup: connectionGroup)
            } catch {
                self.diagnostics.log(.error, category: .transport,
                                     message: "reliable_probe_invalid",
                                     fields: ["event": "reliable_probe_invalid",
                                              "error": "\(error)"])
                stream.cancel()
            }
        }
    }

    private func receiveAudio(on stream: NWConnection, records: ReliableAudioRecords,
                              connectionGroup: NWConnectionGroup) {
        stream.receive(minimumIncompleteLength: 1, maximumLength: 65_540) {
            [weak self] data, _, isComplete, error in
            guard let self, let activeGroup = self.group,
                  activeGroup === connectionGroup else { return }
            guard self.expectedAudioStreamID == records.expectedStreamID else {
                stream.cancel()
                return
            }
            var records = records
            do {
                let packets = try records.append(data ?? Data())
                if self.musicTest, let generation = records.generation,
                   SequenceNumber.isBefore(generation, self.musicGeneration) {
                    stream.cancel(); return
                }
                if let generation = records.generation, (self.audioGeneration == 0 || SequenceNumber.isBefore(self.audioGeneration, generation)) {
                    self.audioStream?.cancel()
                    guard self.onReliableAudioGeneration?(records.expectedStreamID,
                                                          generation) == true else {
                        throw ReliableAudioRecordsError.invalidPreface
                    }
                    self.audioStream = stream
                    self.audioGeneration = generation
                    self.startProgressTimer()
                    _ = self.diagnostics.logAsync(
                        .info, category: .transport, message: "reliable_audio_generation",
                        fields: ["event": "reliable_audio_generation",
                                 "stream_id": "\(records.expectedStreamID)",
                                 "generation": "\(generation)"])
                }
                guard self.audioStream === stream || records.generation == nil else {
                    stream.cancel()
                    return
                }
                for (index, packet) in packets.enumerated() {
                    self.onAudioDatagram?(records.timedPackets.isEmpty
                        ? packet.encoded : records.timedPackets[index].encoded)
                }
                if isComplete {
                    do {
                        try records.finish()
                    } catch ReliableAudioRecordsError.incompleteRecord {
                        guard let generation = records.generation else {
                            throw ReliableAudioRecordsError.incompleteRecord
                        }
                        if self.audioStream === stream { self.audioStream = nil }
                        stream.cancel()
                        self.diagnostics.log(.warning, category: .transport,
                                             message: "reliable_audio_flow_interrupted",
                                             fields: ["event": "reliable_audio_flow_interrupted",
                                                      "generation": "\(generation)"])
                        return
                    }
                    if self.audioStream === stream {
                        self.audioStream = nil
                        self.diagnostics.log(.warning, category: .transport,
                                             message: "reliable_audio_flow_ended",
                                             fields: ["event": "reliable_audio_flow_ended",
                                                      "generation": "\(self.audioGeneration)"])
                    }
                    stream.cancel()
                    return
                }
                if let error {
                    if self.audioStream === stream {
                        self.audioStream = nil
                    }
                    self.diagnostics.log(.warning, category: .transport,
                                         message: "reliable_audio_read_failed",
                                         fields: ["event": "reliable_audio_read_failed",
                                                  "error": "\(error)"])
                    stream.cancel()
                    return
                }
                self.receiveAudio(on: stream, records: records,
                                  connectionGroup: connectionGroup)
            } catch {
                self.diagnostics.log(.error, category: .transport,
                                     message: "reliable_audio_invalid",
                                     fields: ["event": "reliable_audio_invalid",
                                              "error": "\(error)"])
                self.updateState(.failed)
                self.cancel()
            }
        }
    }

    private func startProgressTimer() {
        guard progressTimer == nil, let connectionGroup = group else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = coordinatedAudio ? 25 : 100
        timer.schedule(deadline: .now() + .milliseconds(interval),
                       repeating: .milliseconds(interval))
        timer.setEventHandler { [weak self] in
            guard let self, let activeGroup = self.group,
                  activeGroup === connectionGroup, !self.progressInFlight,
                  let streamID = self.expectedAudioStreamID,
                  self.audioGeneration != 0 else { return }
            do {
                let message = ControlEnvelope(.audioProgress(
                    streamID: streamID, generation: self.audioGeneration,
                    latestReceivedSequence: self.progressSequence?(), timing: self.audioProgressTiming?()))
                self.progressInFlight = true
                try self.sendControl(message.encoded()) { [weak self] _ in
                    self?.queue.async { [weak self] in
                        guard let self, let activeGroup = self.group,
                              activeGroup === connectionGroup else { return }
                        self.progressInFlight = false
                    }
                }
            } catch {
                self.progressInFlight = false
            }
        }
        progressTimer = timer
        timer.resume()
    }

    private func openControlStream(
        connectionGroup: NWConnectionGroup,
        options: NWProtocolQUIC.Options
    ) {
        diagnostics.log(
            .debug,
            category: .control,
            message: "control_stream_open_requested",
            fields: ["event": "control_stream_open_requested", "direction": "bidirectional"]
        )
        guard let control = NWConnection(from: connectionGroup, using: options) else {
            diagnostics.log(
                .error,
                category: .transport,
                message: "flow_open_failed",
                fields: ["event": "flow_open_failed"]
            )
            updateState(.failed)
            return
        }
        controlStream = control
        control.stateUpdateHandler = { [weak self, weak control] state in
            guard let self, let control, let current = self.controlStream,
                  current === control else { return }
            switch state {
            case .setup, .preparing:
                self.diagnostics.log(
                    .debug,
                    category: .transport,
                    message: "control_flow_state",
                    fields: [
                        "event": "control_flow_state",
                        "state": "\(state)"
                    ]
                )
            case .ready:
                self.controlReady = true
                self.diagnostics.log(
                    .info,
                    category: .transport,
                    message: "control_flow_ready",
                    fields: ["event": "control_flow_ready"]
                )
                self.onControlStreamCreated?()
                self.updateReadyIfPossible()
            case let .waiting(error):
                self.diagnostics.log(
                    .warning,
                    category: .transport,
                    message: "control_flow_waiting",
                    fields: [
                        "event": "control_flow_waiting",
                        "error": "\(error)"
                    ]
                )
            case let .failed(error):
                self.diagnostics.log(
                    .error,
                    category: .transport,
                    message: "control_flow_failed",
                    fields: [
                        "event": "control_flow_failed",
                        "error": "\(error)"
                    ]
                )
                self.updateState(.failed)
            case .cancelled:
                self.diagnostics.log(
                    .debug,
                    category: .transport,
                    message: "control_flow_state",
                    fields: [
                        "event": "control_flow_state",
                        "state": "cancelled"
                    ]
                )
            default:
                break
            }
        }
        control.start(queue: queue)
        receiveControl(on: control)
        diagnostics.log(
            .debug,
            category: .control,
            message: "control_stream_created",
            fields: ["event": "control_stream_created"]
        )
    }

    private func updateReadyIfPossible() {
        if controlReady && datagramReady {
            updateState(.ready)
        }
    }

    private func receiveControl(on stream: NWConnection) {
        stream.receive(minimumIncompleteLength: 1, maximumLength: 65_540) {
            [weak self] data, _, isComplete, error in
            guard let self, let current = self.controlStream,
                  current === stream else { return }
            if let data {
                self.diagnostics.log(
                    .debug,
                    category: .control,
                    message: "control_read",
                    fields: ["event": "control_read", "bytes": "\(data.count)"]
                )
                self.onControlData?(data)
            }
            if let error {
                self.diagnostics.log(
                    .warning,
                    category: .transport,
                    message: "control_read_failed",
                    fields: ["event": "control_read_failed", "error": "\(error)"]
                )
            }
            guard error == nil, !isComplete else { return }
            self.receiveControl(on: stream)
        }
    }

    private func updateState(_ newState: QuicReceiverState) {
        let previous = state
        state = newState
        diagnostics.log(
            .info,
            category: .transport,
            message: "transport_state_changed",
            fields: [
                "event": "transport_state_changed",
                "previous_state": "\(previous)",
                "state": "\(newState)"
            ]
        )
        onStateChange?(newState)
    }

    private static func peerSPKI(from metadata: sec_protocol_metadata_t) -> Data? {
        var certificateData: Data?
        guard sec_protocol_metadata_access_peer_certificate_chain(metadata, { certificate in
            let reference = sec_certificate_copy_ref(certificate).takeRetainedValue()
            certificateData = SecCertificateCopyData(reference) as Data?
        }) else {
            return nil
        }
        guard let certificateData else { return nil }
        return extractSPKI(from: certificateData)
    }

    private struct DERValue {
        let tag: UInt8
        let fullRange: Range<Int>
        let contentRange: Range<Int>
    }

    private static func readDER(_ bytes: [UInt8], from offset: inout Int) -> DERValue? {
        guard offset < bytes.count else { return nil }
        let start = offset
        let tag = bytes[offset]
        offset += 1
        guard offset < bytes.count else { return nil }
        let firstLengthByte = bytes[offset]
        offset += 1
        let length: Int
        if firstLengthByte & 0x80 == 0 {
            length = Int(firstLengthByte)
        } else {
            let lengthBytes = Int(firstLengthByte & 0x7f)
            guard lengthBytes > 0, lengthBytes <= 4,
                  offset + lengthBytes <= bytes.count else { return nil }
            var decoded = 0
            for _ in 0..<lengthBytes {
                decoded = (decoded << 8) | Int(bytes[offset])
                offset += 1
            }
            length = decoded
        }
        let contentStart = offset
        let contentEnd = contentStart + length
        guard contentEnd <= bytes.count else { return nil }
        offset = contentEnd
        return DERValue(
            tag: tag,
            fullRange: start..<contentEnd,
            contentRange: contentStart..<contentEnd
        )
    }

    private static func extractSPKI(from certificate: Data) -> Data? {
        let bytes = Array(certificate)
        var outerOffset = 0
        guard let outer = readDER(bytes, from: &outerOffset), outer.tag == 0x30 else {
            return nil
        }
        var tbsOffset = outer.contentRange.lowerBound
        guard let tbs = readDER(bytes, from: &tbsOffset), tbs.tag == 0x30 else {
            return nil
        }
        var cursor = tbs.contentRange.lowerBound
        if cursor < tbs.contentRange.upperBound, bytes[cursor] == 0xa0 {
            guard readDER(bytes, from: &cursor) != nil else { return nil }
        }
        for _ in 0..<5 {
            guard readDER(bytes, from: &cursor) != nil else { return nil }
        }
        guard let subjectPublicKeyInfo = readDER(bytes, from: &cursor),
              subjectPublicKeyInfo.tag == 0x30 else {
            return nil
        }
        return Data(bytes[subjectPublicKeyInfo.fullRange])
    }
}
#endif
