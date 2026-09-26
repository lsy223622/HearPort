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
    public static let defaultCapacity = 240_000
    public let reportTransfer: DebugReportTransfer

    private let capacity: Int
    private let bufferTargetPackets: Int
    private let diagnostics: HearPortDiagnostics
    private let lock = NSLock()
    private let recording = AtomicUInt64()
    private let dropped = AtomicUInt64()
    private var session: DebugSessionMetadata?
    private var records: [DebugPacketTraceRecord] = []
    private var jitterDecisions: [DebugJitterDecisionRecord] = []

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

    public func begin(sessionID: Data, streamID: UInt32, durationSeconds: UInt32) {
        precondition(sessionID.count == 16 && streamID != 0)
        lock.lock()
        records.removeAll(keepingCapacity: true)
        records.reserveCapacity(capacity)
        jitterDecisions.removeAll(keepingCapacity: true)
        jitterDecisions.reserveCapacity(capacity)
        dropped.store(0)
        session = DebugSessionMetadata(
            sessionID: sessionID,
            streamID: streamID,
            durationSeconds: durationSeconds,
            startedAt: DispatchTime.now().uptimeNanoseconds
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
        let dropCount: UInt64
        lock.lock()
        guard recording.load() != 0, let current = session else {
            lock.unlock()
            throw DebugSessionDiagnosticsError.noActiveSession
        }
        recording.store(0)
        metadata = current
        capturedRecords = records
        capturedJitterDecisions = jitterDecisions
        dropCount = dropped.load()
        lock.unlock()

        do {
            let diagnosticURL = try diagnostics.export()
            defer { try? FileManager.default.removeItem(at: diagnosticURL) }
            let safeDiagnostics = try String(contentsOf: diagnosticURL, encoding: .utf8)
            let report = Self.makeReport(
                metadata: metadata,
                records: capturedRecords,
                jitterDecisions: capturedJitterDecisions,
                dropCount: dropCount,
                reason: reason,
                safeDiagnostics: safeDiagnostics,
                bufferTargetPackets: bufferTargetPackets
            )
            let reportURL = try reportTransfer.store(
                sessionID: metadata.sessionID,
                formatVersion: 1,
                data: Data(report.utf8)
            )

            lock.lock()
            if session?.sessionID == metadata.sessionID {
                records.removeAll(keepingCapacity: true)
                jitterDecisions.removeAll(keepingCapacity: true)
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
                                   dropCount: UInt64,
                                   reason: String,
                                   safeDiagnostics: String,
                                   bufferTargetPackets: Int) -> String {
        let finishedAt = DispatchTime.now().uptimeNanoseconds
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let appBuildID = Bundle.main.infoDictionary?["HearPortBuildID"] as? String ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let device = deviceModel()
        var lines = [
            "HearPort receiver diagnostic report",
            "format_version=1",
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
            "",
            "packet_trace_v1",
            "received_at_ns\tstream_id\tsequence\tdisposition\tjitter_result\tfill_packets"
        ]
        lines.reserveCapacity(records.count + jitterDecisions.count + 26)
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
