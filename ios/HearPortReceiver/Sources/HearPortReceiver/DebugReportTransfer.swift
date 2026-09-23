import Foundation

public enum DebugReportTransferError: Error, Equatable {
    case invalidSessionID
    case invalidFormatVersion
    case reportTooLarge
    case pendingReportExists
    case noPendingReport
    case sessionIDMismatch
    case invalidChunkSize
    case corruptPendingReport
}

public struct PendingDiagnosticReport: Equatable, Sendable {
    public let sessionID: Data
    public let formatVersion: UInt32
    public let data: Data

    public init(sessionID: Data, formatVersion: UInt32, data: Data) {
        self.sessionID = sessionID
        self.formatVersion = formatVersion
        self.data = data
    }
}

private struct StoredDiagnosticReport: Codable {
    let sessionID: Data
    let formatVersion: UInt32
    let data: Data
}

public final class DebugReportTransfer: @unchecked Sendable {
    public static let maximumReportBytes = 32 * 1024 * 1024

    private let directory: URL
    private let reportURL: URL
    private let partialURL: URL
    private let maximumBytes: Int
    private let lock = NSLock()
    private let fileManager = FileManager.default

    public init(directory: URL? = nil,
                maximumReportBytes: Int = DebugReportTransfer.maximumReportBytes) {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        self.directory = directory ?? supportDirectory
            .appendingPathComponent("HearPort/Diagnostics/Outgoing", isDirectory: true)
        reportURL = self.directory.appendingPathComponent("pending-report.plist")
        partialURL = self.directory.appendingPathComponent("pending-report.partial")
        maximumBytes = max(1, maximumReportBytes)
    }

    @discardableResult
    public func store(sessionID: Data,
                      formatVersion: UInt32,
                      data: Data) throws -> URL {
        guard sessionID.count == 16 else { throw DebugReportTransferError.invalidSessionID }
        guard formatVersion != 0 else { throw DebugReportTransferError.invalidFormatVersion }
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw DebugReportTransferError.reportTooLarge
        }

        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !fileManager.fileExists(atPath: reportURL.path) else {
            throw DebugReportTransferError.pendingReportExists
        }

        let stored = StoredDiagnosticReport(
            sessionID: sessionID,
            formatVersion: formatVersion,
            data: data
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let encoded = try encoder.encode(stored)
        try encoded.write(to: partialURL, options: .atomic)
        try fileManager.moveItem(at: partialURL, to: reportURL)
        return reportURL
    }

    public func pendingReport() throws -> PendingDiagnosticReport? {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: reportURL.path) else { return nil }
        return try readPendingReportLocked()
    }

    public func makeChunks(maxBytes requestedMaxBytes: Int? = nil) throws -> [Data] {
        let maxBytes = requestedMaxBytes ?? diagnosticReportChunkMaxBytes
        guard maxBytes > 0, maxBytes <= diagnosticReportChunkMaxBytes else {
            throw DebugReportTransferError.invalidChunkSize
        }
        guard let report = try pendingReport() else {
            throw DebugReportTransferError.noPendingReport
        }
        return stride(from: 0, to: report.data.count, by: maxBytes).map { start in
            let end = min(start + maxBytes, report.data.count)
            return report.data.subdata(in: start..<end)
        }
    }

    public func acknowledge(sessionID: Data) throws {
        guard sessionID.count == 16 else { throw DebugReportTransferError.invalidSessionID }
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: reportURL.path) else {
            throw DebugReportTransferError.noPendingReport
        }
        let report = try readPendingReportLocked()
        guard report.sessionID == sessionID else {
            throw DebugReportTransferError.sessionIDMismatch
        }
        try fileManager.removeItem(at: reportURL)
    }

    private func readPendingReportLocked() throws -> PendingDiagnosticReport {
        do {
            let encoded = try Data(contentsOf: reportURL)
            let stored = try PropertyListDecoder().decode(StoredDiagnosticReport.self, from: encoded)
            guard stored.sessionID.count == 16, stored.formatVersion != 0,
                  !stored.data.isEmpty, stored.data.count <= maximumBytes else {
                throw DebugReportTransferError.corruptPendingReport
            }
            return PendingDiagnosticReport(
                sessionID: stored.sessionID,
                formatVersion: stored.formatVersion,
                data: stored.data
            )
        } catch let error as DebugReportTransferError {
            throw error
        } catch {
            throw DebugReportTransferError.corruptPendingReport
        }
    }
}
