import Foundation
#if canImport(UIKit) && os(iOS)
import UIKit
#endif

private struct DebugPacketTraceRecord {
    let receivedAt: UInt64
    let streamID: UInt32
    let sequence: UInt32
    let disposition: UInt8
    let jitterResult: UInt8
    let fillPackets: UInt32
}

private struct DebugSessionMetadata {
    let sessionID: Data
    let streamID: UInt32
    let durationSeconds: UInt32
    let startedAt: UInt64
    let networkProbe: Bool
    let networkProbeRepeat: Bool
    let coordinatedPlan: CoordinatedProbePlan?
    let physicalPath: String
    let connectionID: String
}

enum NetworkProbePlan {
    struct Round {
        let variant: Int
        let payloadBytes: Int
        let packetsPerSecond: Int
        let burstPackets: Int
        let reliable: Bool
        let repeatIndex: Int
    }

    private static let variants: [(bytes: Int, rate: Int, burst: Int)] = [
        (968, 400, 4), (968, 400, 1), (488, 400, 4),
        (968, 200, 1), (488, 400, 1)
    ]

    static func rounds(streamID: UInt32) -> [Round] {
        var state = streamID ^ 0xa5a5_5a5a
        if state == 0 { state = 1 }
        var rounds: [Round] = []
        rounds.reserveCapacity(20)
        var order = Array(0..<variants.count)
        for remaining in stride(from: order.count, through: 2, by: -1) {
            state ^= state &<< 13
            state ^= state >> 17
            state ^= state &<< 5
            order.swapAt(remaining - 1, Int(state % UInt32(remaining)))
        }
        for repeatIndex in 1...2 {
            for offset in 0..<order.count {
                for mode in 0..<2 {
                    let variant = order[repeatIndex == 1 ? offset : order.count - 1 - offset]
                    let spec = variants[variant]
                    rounds.append(Round(
                        variant: variant, payloadBytes: spec.bytes,
                        packetsPerSecond: spec.rate, burstPackets: spec.burst,
                        reliable: mode != repeatIndex - 1, repeatIndex: repeatIndex
                    ))
                }
            }
        }
        return rounds
    }
}

private struct DebugProbePacketRecord {
    let receivedAt: UInt64
    let recordedAt: UInt64
    let callbackBytes: Int
    let callbackPackets: Int
    let streamID: UInt32
    let sequence: UInt32
    let payloadBytes: Int
    let capturedAt, sourceFrame, mappedCapturedAt, uncertainty: UInt64
    let generation: UInt32
    let kind: UInt16
}

enum DebugJitterDecision: String {
    case concealed
    case trimmed
}

private struct DebugJitterDecisionRecord {
    let at: UInt64
    let streamID: UInt32
    let sequence: UInt32
    let decision: DebugJitterDecision
    let fillPackets: UInt32
}

public final class DebugSessionDiagnostics: @unchecked Sendable {
    public static let defaultCapacity = 1_000_000
    public let reportTransfer: DebugReportTransfer

    private let capacity: Int
    private let bufferTargetPackets: Int
    private let diagnostics: HearPortDiagnostics
    private let lock = NSLock()
    private let recording = AtomicUInt64()
    private let dropped = AtomicUInt64()
    private let clockUnavailablePackets = AtomicUInt64()
    private var clockExchanges: [String] = []
    private var physicalPath = "network"
    private var connectionID = ""
    public func configureConnection(path: ConnectionPath, id: UUID) {
        lock.lock(); defer { lock.unlock() }
        physicalPath = path.rawValue; connectionID = id.uuidString
    }
    private var session: DebugSessionMetadata?
    private var records: [DebugPacketTraceRecord] = []
    private var jitterDecisions: [DebugJitterDecisionRecord] = []
    private var probePackets: [DebugProbePacketRecord] = []
    private var coordinatedPlan: CoordinatedProbePlan?
    private var calibration: EnvironmentCalibrationSession?
    private var calibrationResult: CalibrationResult?
    private var probeBudget = try! PlayoutBudget(targetMilliseconds: 50, maximumMilliseconds: 100,
                                                outputReserveMilliseconds: 10)
    private var consumer: ProbeConsumer?
    private var consumerRound = -1
    private var consumerGeneration: UInt32 = 0
    private var playback: [String] = []
    private var lastPlaybackAt: UInt64 = 0
    private var accumulatedPlayed = 0, accumulatedConcealed = 0
    private var accumulatedSkipped: UInt64 = 0
    private var accumulatedWaiting = 0
    private var probeStartedAt: UInt64?
    private var maximumAge = 0.0
    private var probeHeartbeats: [(at: UInt64, scheduledAt: UInt64)] = []

    public init(capacity: Int = DebugSessionDiagnostics.defaultCapacity,
                bufferTargetPackets: Int = 8,
                reportTransfer: DebugReportTransfer = DebugReportTransfer(),
                diagnostics: HearPortDiagnostics = .shared) {
        self.capacity = max(1, capacity)
        self.bufferTargetPackets = max(1, bufferTargetPackets)
        self.reportTransfer = reportTransfer
        self.diagnostics = diagnostics
    }

    public var isRecording: Bool { recording.load() != 0 }

    public func begin(sessionID: Data, streamID: UInt32, durationSeconds: UInt32,
                      networkProbe: Bool = false,
                      networkProbeRepeat: Bool = false) {
        precondition(sessionID.count == 16 && streamID != 0)
        lock.lock()
        records.removeAll(keepingCapacity: true)
        jitterDecisions.removeAll(keepingCapacity: true)
        probePackets.removeAll(keepingCapacity: true)
        probeHeartbeats.removeAll(keepingCapacity: true)
        playback.removeAll(keepingCapacity: true)
        clockExchanges.removeAll(keepingCapacity: true)
        clockUnavailablePackets.store(0)
        consumer = nil; consumerRound = -1; consumerGeneration = 0
        lastPlaybackAt = 0; accumulatedPlayed = 0; accumulatedConcealed = 0
        accumulatedSkipped = 0; accumulatedWaiting = 0; maximumAge = 0; probeStartedAt = nil
        if networkProbe {
            probePackets.reserveCapacity(capacity)
            probeHeartbeats.reserveCapacity(min(capacity, Int(durationSeconds) * 10 + 10))
        } else {
            records.reserveCapacity(capacity)
            jitterDecisions.reserveCapacity(capacity)
        }
        dropped.store(0)
        session = DebugSessionMetadata(
            sessionID: sessionID,
            streamID: streamID,
            durationSeconds: durationSeconds,
            startedAt: DispatchTime.now().uptimeNanoseconds,
            networkProbe: networkProbe,
            networkProbeRepeat: networkProbeRepeat,
            coordinatedPlan: coordinatedPlan,
            physicalPath: physicalPath, connectionID: connectionID
        )
        recording.store(1)
        lock.unlock()
        _ = diagnostics.logAsync(
            .info,
            category: .realtime,
            message: "debug_capture_started",
            fields: [
                "event": "debug_capture_started",
                "session_id": Self.hex(sessionID),
                "stream_id": "\(streamID)",
                "duration_seconds": "\(durationSeconds)",
                "trace_capacity": "\(capacity)"
            ]
        )
    }

    func recordClockExchange(localSent: UInt64, remoteReceived: UInt64, remoteSent: UInt64,
                             localReceived: UInt64, accepted: Bool,
                             mappingAge: UInt64?, uncertainty: UInt64) {
        guard recording.load() != 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard recording.load() != 0 else { return }
        guard clockExchanges.count < capacity else { dropped.increment(); return }
        clockExchanges.append("\(localSent)\t\(remoteReceived)\t\(remoteSent)\t\(localReceived)\t\(accepted ? 1 : 0)\t\(mappingAge.map(String.init) ?? "none")\t\(uncertainty)")
    }

    func recordClockUnavailablePacket() {
        if recording.load() != 0 { clockUnavailablePackets.increment() }
    }

    public func recordProbePacket(_ data: Data,
                                  receivedAt: UInt64 = DispatchTime.now().uptimeNanoseconds,
                                  callbackBytes: Int? = nil, callbackPackets: Int = 1,
                                  mappedCapturedAt: UInt64? = nil, uncertainty: UInt64 = 0) {
        guard recording.load() != 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard recording.load() != 0, let session, session.networkProbe else { return }
        guard data.count >= 8 else { dropped.increment(); return }
        let streamID = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard streamID == session.streamID else { dropped.increment(); return }
        let timed = session.coordinatedPlan != nil || calibration != nil ? try? TimedAudioRecord(encoded: data) : nil
        if (session.coordinatedPlan != nil || calibration != nil) && timed == nil { dropped.increment(); return }
        let sequence = timed?.sequence ?? data.dropFirst(4).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        if let calibration, let timed {
            calibration.receive(timed, capturedAt: mappedCapturedAt, uncertainty: uncertainty,
                receivedAt: receivedAt, processedAt: DispatchTime.now().uptimeNanoseconds)
        }
        if let timed, let plan = session.coordinatedPlan, let mappedCapturedAt {
            if probeStartedAt == nil {
                let sourceTime = UInt64(Double(timed.sourceFrame) / 48_000 * 1e9) +
                    (timed.sourceFrame / (30 * 48_000)) * UInt64(plan.recoverySeconds) * 1_000_000_000
                if mappedCapturedAt >= sourceTime { probeStartedAt = mappedCapturedAt - sourceTime }
            }
            advanceProbeRound(at: receivedAt, plan: plan)
            var first: UInt32 = 0
            for (index, round) in plan.rounds.enumerated() {
                let last = first + UInt32(round.packetsPerSecond * 30)
                if (first..<last).contains(sequence) {
                    if index < consumerRound { break }
                    if index != consumerRound {
                        consumerRound = index
                        consumer = ProbeConsumer(round: round, budget: probeBudget,
                            firstSequence: first, sourceFrame: UInt64(index) * 30 * 48_000)
                    }
                    consumer?.receive(timed, capturedAt: mappedCapturedAt, uncertainty: uncertainty, now: receivedAt)
                    consumerGeneration = consumer?.generation ?? 0
                    break
                }
                first = last
            }
        }
        guard probePackets.count < capacity else { dropped.increment(); return }
        probePackets.append(DebugProbePacketRecord(
            receivedAt: receivedAt,
            recordedAt: DispatchTime.now().uptimeNanoseconds,
            callbackBytes: callbackBytes ?? data.count,
            callbackPackets: callbackPackets,
            streamID: streamID,
            sequence: sequence,
            payloadBytes: data.count,
            capturedAt: timed?.capturedAt ?? 0, sourceFrame: timed?.sourceFrame ?? 0,
            mappedCapturedAt: mappedCapturedAt ?? 0, uncertainty: uncertainty,
            generation: timed?.generation ?? 0, kind: timed?.kind.rawValue ?? 0
        ))
    }

    public func configureProbePlan(_ plan: CoordinatedProbePlan?) {
        lock.lock(); coordinatedPlan = plan; lock.unlock()
    }

    func configureCalibration(_ setup: CalibrationMessage?) {
        lock.lock()
        let previous = calibration
        calibration = setup.map { EnvironmentCalibrationSession(setup: $0) }
        calibrationResult = nil
        lock.unlock()
        previous?.cancel()
    }

    func calibrationSession() -> EnvironmentCalibrationSession? {
        lock.lock(); defer { lock.unlock() }
        return calibration
    }

    func completedCalibration() -> CalibrationResult? {
        lock.lock(); defer { lock.unlock() }
        return calibrationResult
    }

    public func configureProbeBudget(_ budget: PlayoutBudget) {
        lock.lock(); probeBudget = budget; lock.unlock()
    }

    func probeProgress() -> (sequence: UInt32?, played: UInt64?, buffered: UInt32)? {
        lock.lock(); defer { lock.unlock() }
        if let calibration { return calibration.feedback() }
        guard let consumer else { return nil }
        return (consumer.latestReceivedSequence, consumer.playedSourceFrame,
                UInt32(consumer.bufferedFrames / 48))
    }

    private func advanceProbeRound(at now: UInt64, plan: CoordinatedProbePlan) {
        guard let start = probeStartedAt, now >= start else { return }
        let index = min(plan.rounds.count - 1, Int((now - start) / (UInt64(30 + plan.recoverySeconds) * 1_000_000_000)))
        guard index > consumerRound else { return }
        if consumerRound >= 0 {
            playback.append("\(consumerRound + 1)\t\(now)\t\(consumer?.playedSourceFrame ?? 0)\t\(consumer?.bufferedFrames ?? 0)\t0\t0\t\(accumulatedPlayed)\t\(accumulatedConcealed)\t\(accumulatedSkipped)\t\(maximumAge)\t\(consumer?.repairedPackets ?? 0)\t\(accumulatedWaiting)")
        }
        accumulatedPlayed = 0; accumulatedConcealed = 0; accumulatedWaiting = 0
        accumulatedSkipped = 0; maximumAge = 0
        let first = plan.rounds.prefix(index).reduce(UInt32(0)) { $0 + UInt32($1.packetsPerSecond * 30) }
        consumer = ProbeConsumer(round: plan.rounds[index], budget: probeBudget,
            firstSequence: first, sourceFrame: UInt64(index) * 30 * 48_000)
        consumerRound = index; consumerGeneration = 0
    }

    func tickProbe(at now: UInt64, roundTrip: UInt64, uncertainty: UInt64 = 0) -> ControlMessage? {
        lock.lock(); defer { lock.unlock() }
        guard recording.load() != 0, let session else { return nil }
        if let calibration {
            calibration.tick(at: DispatchTime.now().uptimeNanoseconds, uncertainty: uncertainty)
            return nil
        }
        if let plan = session.coordinatedPlan {
            advanceProbeRound(at: now, plan: plan)
            if let start = probeStartedAt, now >= start,
               Double(now - start) / 1e9 > Double(plan.activeDurationSeconds) + probeBudget.maximumMilliseconds / 1_000 {
                return nil
            }
        }
        if let plan = session.coordinatedPlan, let start = probeStartedAt, now >= start,
           (now - start) % (UInt64(30 + plan.recoverySeconds) * 1_000_000_000) >=
                30_000_000_000 + UInt64(probeBudget.maximumMilliseconds * 1_000_000) { return nil }
        guard var current = consumer else { return nil }
        current.updateUncertainty(uncertainty)
        let request = current.requestRepair(now: now, roundTrip: roundTrip)
        let result = current.tick(now: now)
        consumer = current
        accumulatedPlayed += result.playedFrames
        accumulatedConcealed += result.concealedFrames
        accumulatedWaiting += result.waitingFrames
        accumulatedSkipped += result.skippedFrames
        maximumAge = max(maximumAge, result.sourceAgeMilliseconds ?? 0)
        if now >= lastPlaybackAt && now - lastPlaybackAt >= 100_000_000 {
            if playback.count < capacity {
                playback.append("\(consumerRound + 1)\t\(now)\t\(current.playedSourceFrame ?? 0)\t\(current.bufferedFrames)\t\(result.targetMilliseconds)\t\(result.correction)\t\(accumulatedPlayed)\t\(accumulatedConcealed)\t\(accumulatedSkipped)\t\(maximumAge)\t\(current.repairedPackets)\t\(accumulatedWaiting)")
            } else { dropped.increment() }
            lastPlaybackAt = now; accumulatedPlayed = 0; accumulatedConcealed = 0
            accumulatedSkipped = 0; accumulatedWaiting = 0; maximumAge = 0
        }
        guard let request else { return nil }
        return .repairRequest(streamID: session.streamID, generation: consumerGeneration,
                              remainingMilliseconds: request.1, sequences: [request.0])
    }

    public func recordProbeHeartbeat(at: UInt64, scheduledAt: UInt64) {
        guard recording.load() != 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard recording.load() != 0, session?.networkProbe == true else { return }
        guard probeHeartbeats.count < capacity else { dropped.increment(); return }
        probeHeartbeats.append((at: at, scheduledAt: scheduledAt))
    }

    public func recordPacket(streamID: UInt32,
                             sequence: UInt32,
                             receivedAt: UInt64,
                             disposition: AudioDisposition,
                             jitterResult: JitterInsertResult?,
                             fillPackets: Int) {
        guard recording.load() != 0 else { return }
        guard lock.try() else {
            dropped.increment()
            return
        }
        defer { lock.unlock() }
        guard recording.load() != 0, session != nil else { return }
        guard records.count + jitterDecisions.count < capacity else {
            dropped.increment()
            return
        }
        records.append(DebugPacketTraceRecord(
            receivedAt: receivedAt,
            streamID: streamID,
            sequence: sequence,
            disposition: Self.dispositionCode(disposition),
            jitterResult: Self.jitterCode(jitterResult),
            fillPackets: UInt32(clamping: max(0, fillPackets))
        ))
    }

    func recordJitterDecision(streamID: UInt32,
                              sequence: UInt32,
                              decision: DebugJitterDecision,
                              at: UInt64,
                              fillPackets: Int) {
        guard recording.load() != 0 else { return }
        guard lock.try() else {
            dropped.increment()
            return
        }
        defer { lock.unlock() }
        guard recording.load() != 0, session != nil else { return }
        guard records.count + jitterDecisions.count < capacity else {
            dropped.increment()
            return
        }
        jitterDecisions.append(DebugJitterDecisionRecord(
            at: at,
            streamID: streamID,
            sequence: sequence,
            decision: decision,
            fillPackets: UInt32(clamping: max(0, fillPackets))
        ))
    }

    @discardableResult
    public func finish(reason: String, diagnostics: HearPortDiagnostics) throws -> URL {
        try finalize(reason: reason, diagnostics: diagnostics)
    }

    @discardableResult
    public func persistPartial(reason: String) throws -> URL {
        try finalize(reason: reason, diagnostics: diagnostics)
    }

    private func finalize(reason: String, diagnostics: HearPortDiagnostics) throws -> URL {
        let metadata: DebugSessionMetadata
        let capturedRecords: [DebugPacketTraceRecord]
        let capturedJitterDecisions: [DebugJitterDecisionRecord]
        let capturedProbePackets: [DebugProbePacketRecord]
        let capturedProbeHeartbeats: [(at: UInt64, scheduledAt: UInt64)]
        let dropCount: UInt64
        let capturedPlayback: [String]
        let capturedBudget: PlayoutBudget
        let capturedClockExchanges: [String]
        let clockUnavailableCount: UInt64
        let capturedCalibration: EnvironmentCalibrationSession?
        lock.lock()
        guard recording.load() != 0, let current = session else {
            lock.unlock()
            throw DebugSessionDiagnosticsError.noActiveSession
        }
        recording.store(0)
        metadata = current
        capturedRecords = records
        capturedJitterDecisions = jitterDecisions
        capturedProbePackets = probePackets
        capturedProbeHeartbeats = probeHeartbeats
        dropCount = dropped.load()
        capturedPlayback = playback
        capturedBudget = probeBudget
        capturedClockExchanges = clockExchanges
        clockUnavailableCount = clockUnavailablePackets.load()
        capturedCalibration = calibration
        lock.unlock()

        do {
            let diagnosticURL = try diagnostics.export()
            defer { try? FileManager.default.removeItem(at: diagnosticURL) }
            let safeDiagnostics = try String(contentsOf: diagnosticURL, encoding: .utf8)
            if dropCount > 0 { capturedCalibration?.cancel() }
            let calibrationResult = capturedCalibration?.result(at: DispatchTime.now().uptimeNanoseconds,
                completed: reason == "duration_expired")
            let report = Self.makeReport(
                metadata: metadata,
                records: capturedRecords,
                jitterDecisions: capturedJitterDecisions,
                probePackets: capturedProbePackets,
                probeHeartbeats: capturedProbeHeartbeats,
                playback: capturedPlayback,
                clockExchanges: capturedClockExchanges,
                clockUnavailableCount: clockUnavailableCount,
                budget: capturedBudget,
                dropCount: dropCount,
                reason: reason,
                safeDiagnostics: safeDiagnostics,
                bufferTargetPackets: bufferTargetPackets,
                calibrationResult: calibrationResult
            )
            let reportURL = try reportTransfer.store(
                sessionID: metadata.sessionID,
                formatVersion: 1,
                data: Data(report.utf8)
            )

            lock.lock()
            self.calibrationResult = calibrationResult
            if session?.sessionID == metadata.sessionID {
                records.removeAll(keepingCapacity: true)
                jitterDecisions.removeAll(keepingCapacity: true)
                probePackets.removeAll(keepingCapacity: true)
                probeHeartbeats.removeAll(keepingCapacity: true)
                session = nil
            }
            lock.unlock()
            _ = diagnostics.logAsync(
                .info,
                category: .realtime,
                message: "debug_capture_persisted",
                fields: [
                    "event": "debug_capture_persisted",
                    "session_id": Self.hex(metadata.sessionID),
                    "trace_records": "\(capturedRecords.count)",
                    "trace_dropped": "\(dropCount)",
                    "report_bytes": "\(report.utf8.count)"
                ]
            )
            return reportURL
        } catch {
            recording.store(1)
            throw error
        }
    }

    private static func makeReport(metadata: DebugSessionMetadata,
                                   records: [DebugPacketTraceRecord],
                                   jitterDecisions: [DebugJitterDecisionRecord],
                                   probePackets: [DebugProbePacketRecord],
                                   probeHeartbeats: [(at: UInt64, scheduledAt: UInt64)],
                                   playback: [String],
                                   clockExchanges: [String],
                                   clockUnavailableCount: UInt64,
                                   budget: PlayoutBudget,
                                   dropCount: UInt64,
                                   reason: String,
                                   safeDiagnostics: String,
                                   bufferTargetPackets: Int,
                                   calibrationResult: CalibrationResult? = nil) -> String {
        let finishedAt = DispatchTime.now().uptimeNanoseconds
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let appBuildID = Bundle.main.infoDictionary?["HearPortBuildID"] as? String ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let device = deviceModel()
        var lines = [
            "HearPort receiver diagnostic report",
            "format_version=1",
            "physical_path=\(metadata.physicalPath)",
            "connection_id=\(metadata.connectionID)",
            "session_id=\(hex(metadata.sessionID))",
            "stream_id=\(metadata.streamID)",
            "duration_seconds=\(metadata.durationSeconds)",
            "app_version=\(safeField(appVersion))",
            "app_build=\(safeField(appBuild))",
            "app_build_id=\(safeField(appBuildID))",
            "device=\(safeField(device))",
            "os_version=\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)",
            "buffer_target_packets=\(bufferTargetPackets)",
            "started_at_uptime_ns=\(metadata.startedAt)",
            "finished_at_uptime_ns=\(finishedAt)",
            "elapsed_ns=\(finishedAt &- metadata.startedAt)",
            "end_reason=\(safeField(reason))",
            "trace_records=\(records.count)",
            "jitter_decision_records=\(jitterDecisions.count)",
            "trace_dropped=\(dropCount)",
            "clock_unmapped_packets=\(clockUnavailableCount)"
        ]
        lines.reserveCapacity(records.count + jitterDecisions.count + probePackets.count + 30)
        lines.append("\nclock_exchange_v1")
        lines.append("local_sent_ns\tremote_received_ns\tremote_sent_ns\tlocal_received_ns\taccepted\tmapping_age_ns\tuncertainty_ns")
        lines.append(contentsOf: clockExchanges)
        if let calibrationResult {
            lines.append("probe_mode=environment_calibration")
            if let data = try? JSONEncoder().encode(calibrationResult), let json = String(data: data, encoding: .utf8) {
                lines.append("\ncalibration_result_json_v1")
                lines.append(json)
            }
            lines.append("\n" + calibrationResult.reportSections)
            lines.append("\ncalibration_trace_v1")
            lines.append("received_at_ns\tstream_id\tsequence\tpayload_bytes\trecorded_at_ns\tcaptured_at_ns\tsource_frame\tgeneration\tmapped_captured_at_ns\tuncertainty_ns")
            for p in probePackets {
                lines.append("\(p.receivedAt)\t\(p.streamID)\t\(p.sequence)\t\(p.payloadBytes)\t\(p.recordedAt)\t\(p.capturedAt)\t\(p.sourceFrame)\t\(p.generation)\t\(p.mappedCapturedAt)\t\(p.uncertainty)")
            }
            lines.append("\napp_diagnostics_v1")
            lines.append(safeDiagnostics.trimmingCharacters(in: .newlines))
            return lines.joined(separator: "\n") + "\n"
        }
        if metadata.networkProbe {
            lines.insert("probe_mode=network", at: 5)
            if metadata.coordinatedPlan != nil {
                lines.append("target_ms=\(budget.targetMilliseconds)")
                lines.append("maximum_ms=\(budget.maximumMilliseconds)")
                lines.append("output_reserve_ms=\(budget.outputReserveMilliseconds)")
                lines.append("consumer=online_source_frames_v1")
            }
            lines.insert("probe_trace_records=\(probePackets.count)", at: 6)
            let specs: [NetworkProbePlan.Round]
            if let plan = metadata.coordinatedPlan {
                specs = plan.rounds.map { NetworkProbePlan.Round(variant: $0.variant,
                    payloadBytes: $0.payloadBytes, packetsPerSecond: $0.packetsPerSecond,
                    burstPackets: $0.burstPackets, reliable: $0.reliable, repeatIndex: $0.repeatIndex) }
                lines.append("probe_plan=coordinated_manifest_v4")
                lines.append("recovery_seconds=\(plan.recoverySeconds)")
                lines.append("\nnetwork_probe_rounds_v4")
                lines.append("round\ttransport\trepeat\tvariant\tseconds\tpayload_bytes\tpackets_per_second\tburst_packets\tfirst_sequence\tplanned\treceived\tunique\tduplicates\tnot_received\twrong_size\tcontroller\trepair\tcorrection_percent")
            } else if metadata.networkProbeRepeat {
                specs = NetworkProbePlan.rounds(streamID: metadata.streamID)
                lines.append("probe_plan=paired_reverse_repeat_v3")
                lines.append("\nnetwork_probe_rounds_v3")
                lines.append("round\ttransport\trepeat\tvariant\tseconds\tpayload_bytes\tpackets_per_second\tburst_packets\tfirst_sequence\tplanned\treceived\tunique\tduplicates\tnot_received\twrong_size")
            } else {
                let legacy: [(Int, Int, Int)] = [
                    (968, 400, 4), (968, 400, 1), (488, 400, 4), (968, 200, 1),
                    (968, 400, 4), (968, 400, 1), (488, 400, 4), (968, 200, 1)
                ]
                specs = legacy.enumerated().map { index, spec in
                    NetworkProbePlan.Round(
                        variant: index % 4, payloadBytes: spec.0,
                        packetsPerSecond: spec.1, burstPackets: spec.2,
                        reliable: index >= 4, repeatIndex: 1
                    )
                }
                lines.append("\nnetwork_probe_rounds_v1")
                lines.append("round\ttransport\tseconds\tpayload_bytes\tpackets_per_second\tburst_packets\tfirst_sequence\tplanned\treceived\tunique\tduplicates\tnot_received\twrong_size")
            }
            var firstSequence = 0
            for (index, spec) in specs.enumerated() {
                let planned = spec.packetsPerSecond * 30
                let lastSequence = firstSequence + planned
                let received = probePackets.filter {
                    (firstSequence..<lastSequence).contains(Int($0.sequence)) && $0.kind != 1
                }
                let unique = Set(received.map(\.sequence)).count
                let wrongSize = received.filter { $0.payloadBytes != spec.payloadBytes }.count
                let transport = spec.reliable ? "reliable_stream" : "datagram"
                let prefix = metadata.networkProbeRepeat
                    ? "\(index + 1)\t\(transport)\t\(spec.repeatIndex)\t\(spec.variant)"
                    : "\(index + 1)\t\(transport)"
                var row = "\(prefix)\t30\t\(spec.payloadBytes)\t\(spec.packetsPerSecond)\t\(spec.burstPackets)\t\(firstSequence)\t\(planned)\t\(received.count)\t\(unique)\t\(received.count - unique)\t\(planned - unique)\t\(wrongSize)"
                if let plan = metadata.coordinatedPlan {
                    let policy = plan.rounds[index]
                    row += "\t\(policy.controller)\t\(policy.repair)\t\(policy.correctionPercent)"
                }
                lines.append(row)
                firstSequence = lastSequence
            }
            lines.append(metadata.coordinatedPlan == nil ? "\nnetwork_probe_trace_v2" : "\nnetwork_probe_trace_v3")
            var header = "received_at_ns\tstream_id\tsequence\tpayload_bytes\trecorded_at_ns\tcallback_bytes\tcallback_packets"
            if metadata.coordinatedPlan != nil { header += "\tcaptured_at_ns\tsource_frame\tgeneration\tkind\tmapped_captured_at_ns\tuncertainty_ns" }
            lines.append(header)
            for packet in probePackets {
                var row = "\(packet.receivedAt)\t\(packet.streamID)\t\(packet.sequence)\t\(packet.payloadBytes)\t\(packet.recordedAt)\t\(packet.callbackBytes)\t\(packet.callbackPackets)"
                if metadata.coordinatedPlan != nil { row += "\t\(packet.capturedAt)\t\(packet.sourceFrame)\t\(packet.generation)\t\(packet.kind)\t\(packet.mappedCapturedAt)\t\(packet.uncertainty)" }
                lines.append(row)
            }
            if metadata.coordinatedPlan != nil {
                lines.append("\nnetwork_probe_playback_v1")
                lines.append("round\tat_ns\tplayed_source_frame\tbuffered_frames\ttarget_ms\tcorrection\tplayed_frames\tconcealed_frames\tskipped_frames\tmaximum_age_ms\trepaired_packets\twaiting_frames")
                lines.append(contentsOf: playback)
            }
            lines.append("\nnetwork_probe_heartbeat_v1")
            lines.append("at_ns\tscheduled_at_ns")
            for heartbeat in probeHeartbeats {
                lines.append("\(heartbeat.at)\t\(heartbeat.scheduledAt)")
            }
            lines.append("\napp_diagnostics_v1")
            lines.append(safeDiagnostics.trimmingCharacters(in: .newlines))
            return lines.joined(separator: "\n") + "\n"
        }
        lines.append("\npacket_trace_v1")
        lines.append("received_at_ns\tstream_id\tsequence\tdisposition\tjitter_result\tfill_packets")
        for record in records {
            lines.append([
                String(record.receivedAt),
                String(record.streamID),
                String(record.sequence),
                dispositionName(record.disposition),
                jitterName(record.jitterResult),
                String(record.fillPackets)
            ].joined(separator: "\t"))
        }
        lines.append("\njitter_decision_trace_v1")
        lines.append("at_ns\tstream_id\tsequence\tdecision\tfill_packets")
        for decision in jitterDecisions {
            lines.append([
                String(decision.at),
                String(decision.streamID),
                String(decision.sequence),
                decision.decision.rawValue,
                String(decision.fillPackets)
            ].joined(separator: "\t"))
        }
        lines.append("\napp_diagnostics_v1")
        lines.append(safeDiagnostics.trimmingCharacters(in: .newlines))
        return lines.joined(separator: "\n") + "\n"
    }

    private static func dispositionCode(_ disposition: AudioDisposition) -> UInt8 {
        switch disposition {
        case .accepted: return 1
        case .pendingAudioDiscarded: return 2
        case .oldStreamDiscarded: return 3
        }
    }

    private static func jitterCode(_ result: JitterInsertResult?) -> UInt8 {
        switch result {
        case .inserted: return 1
        case .duplicate: return 2
        case .late: return 3
        case .wrongStream: return 4
        case .capacityExceeded: return 5
        case nil: return 0
        }
    }

    private static func dispositionName(_ code: UInt8) -> String {
        switch code {
        case 1: return "accepted"
        case 2: return "pending_discarded"
        case 3: return "old_stream_discarded"
        default: return "unknown"
        }
    }

    private static func jitterName(_ code: UInt8) -> String {
        switch code {
        case 1: return "inserted"
        case 2: return "duplicate"
        case 3: return "late"
        case 4: return "wrong_stream"
        case 5: return "capacity_exceeded"
        default: return "none"
        }
    }

    private static func safeField(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            scalar == "\t" || scalar == "\r" || scalar == "\n" ? "_" : String(scalar)
        }.joined()
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func deviceModel() -> String {
        #if canImport(UIKit) && os(iOS)
        return UIDevice.current.model
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }
}

public enum DebugSessionDiagnosticsError: Error, Equatable {
    case noActiveSession
}
