import Foundation
import os

public enum DiagnosticsLevel: Int, CaseIterable, Comparable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public static func < (lhs: DiagnosticsLevel, rhs: DiagnosticsLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    fileprivate var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }
}

public enum DiagnosticsCategory: String, CaseIterable, Sendable {
    case app
    case transport
    case pairing
    case control
    case audio
    case realtime
    case security
}

public struct DiagnosticsSnapshot: Equatable, Sendable {
    public let entryCount: Int
    public let activeBytes: Int
    public let rotatedFileCount: Int
    public let level: DiagnosticsLevel
    public let asyncQueueDepth: Int
    public let asyncDroppedCount: UInt64

    public init(entryCount: Int,
                activeBytes: Int,
                rotatedFileCount: Int,
                level: DiagnosticsLevel,
                asyncQueueDepth: Int = 0,
                asyncDroppedCount: UInt64 = 0) {
        self.entryCount = entryCount
        self.activeBytes = activeBytes
        self.rotatedFileCount = rotatedFileCount
        self.level = level
        self.asyncQueueDepth = asyncQueueDepth
        self.asyncDroppedCount = asyncDroppedCount
    }
}

final class DiagnosticsAsyncQueue<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private let wake = DispatchSemaphore(value: 0)
    private let capacity: Int
    private var elements: [Element] = []
    private var closed = false
    private let dropped = AtomicUInt64()

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        elements.reserveCapacity(self.capacity)
    }

    @discardableResult
    func tryEnqueue(_ element: Element) -> Bool {
        guard lock.try() else {
            dropped.increment()
            return false
        }
        defer { lock.unlock() }
        guard !closed, elements.count < capacity else {
            dropped.increment()
            return false
        }
        elements.append(element)
        wake.signal()
        return true
    }

    func dequeue() -> Element? {
        lock.lock()
        defer { lock.unlock() }
        guard !elements.isEmpty else { return nil }
        return elements.removeFirst()
    }

    func wait() {
        _ = wake.wait(timeout: .distantFuture)
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
        wake.signal()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return elements.count
    }

    var droppedCount: UInt64 {
        dropped.load()
    }
}

private struct AsyncDiagnosticEvent: Sendable {
    let level: DiagnosticsLevel
    let category: DiagnosticsCategory
    let message: String
    let fields: [String: String]
}

public final class HearPortDiagnostics: @unchecked Sendable {
    public static let shared = HearPortDiagnostics()

    private static let sensitiveKeyFragments = [
        "pin", "password", "secret", "token", "key", "credential",
        "scalar", "point", "confirmation", "mac", "payload", "pcm"
    ]

    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let directory: URL
    private let activeURL: URL
    private let maxFileBytes: Int
    private let maxRotatedFiles: Int
    private let clock: () -> Date
    private let formatter: ISO8601DateFormatter
    private let osLogger = Logger(subsystem: "com.hearport.receiver",
                                  category: "diagnostics")
    private var configuredLevel: DiagnosticsLevel = .info
    private let configuredLevelAtomic = AtomicUInt64(UInt64(DiagnosticsLevel.info.rawValue))
    private var tail: [String] = []
    private let tailLimit = 2_000
    private let asyncQueue: DiagnosticsAsyncQueue<AsyncDiagnosticEvent>
    private let asyncWriterQueue = DispatchQueue(
        label: "com.hearport.receiver.diagnostics-writer",
        qos: .utility
    )
    private let asyncWriterStop = AtomicUInt64()
    private let asyncWriterGroup = DispatchGroup()

    public init(directory: URL? = nil,
                maxFileBytes: Int = 1_048_576,
                maxRotatedFiles: Int = 3,
                asyncQueueCapacity: Int = 512,
                clock: @escaping () -> Date = Date.init) {
        let baseDirectory = directory ?? Self.defaultDirectory()
        self.directory = baseDirectory
        self.activeURL = baseDirectory.appendingPathComponent("hearport.log")
        self.maxFileBytes = max(1, maxFileBytes)
        self.maxRotatedFiles = max(0, maxRotatedFiles)
        self.clock = clock
        asyncQueue = DiagnosticsAsyncQueue(capacity: asyncQueueCapacity)
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try? fileManager.createDirectory(at: baseDirectory,
                                         withIntermediateDirectories: true)
        loadTail()
        asyncWriterQueue.async { [weak self] in
            Self.runAsyncWriter(
                queue: self?.asyncQueue,
                stop: self?.asyncWriterStop,
                group: self?.asyncWriterGroup
            ) { [weak self] event in
                self?.log(event.level,
                          category: event.category,
                          message: event.message,
                          fields: event.fields)
            }
        }
    }

    deinit {
        asyncWriterStop.exchange(1)
        asyncQueue.close()
    }

    public var level: DiagnosticsLevel {
        get {
            DiagnosticsLevel(rawValue: Int(configuredLevelAtomic.load())) ?? .info
        }
        set {
            lock.lock()
            configuredLevel = newValue
            configuredLevelAtomic.exchange(UInt64(newValue.rawValue))
            lock.unlock()
        }
    }

    public func log(_ level: DiagnosticsLevel,
                    category: DiagnosticsCategory,
                    message: String,
                    fields: [String: String] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        guard level >= configuredLevel else { return }

        let safeMessage = Self.redactMessage(message)
        let safeFields = fields.keys.sorted().map { key in
            let value = Self.isSensitiveKey(key)
                ? "<redacted>"
                : Self.redactMessage(fields[key] ?? "")
            return "\(key)=\(value)"
        }
        let suffix = safeFields.isEmpty ? "" : " | \(safeFields.joined(separator: " "))"
        let line = "\(formatter.string(from: clock())) [\(level.label)] [\(category.rawValue)] \(safeMessage)\(suffix)"
        tail.append(line)
        if tail.count > tailLimit {
            tail.removeFirst(tail.count - tailLimit)
        }
        appendLocked(line)
        emitToUnifiedLog(line, level: level)
    }

    @discardableResult
    public func logAsync(_ level: DiagnosticsLevel,
                         category: DiagnosticsCategory,
                         message: String,
                         fields: [String: String] = [:]) -> Bool {
        guard level.rawValue >= Int(configuredLevelAtomic.load()) else {
            return true
        }
        let event = AsyncDiagnosticEvent(
            level: level,
            category: category,
            message: message,
            fields: fields
        )
        asyncWriterGroup.enter()
        guard asyncQueue.tryEnqueue(event) else {
            asyncWriterGroup.leave()
            return false
        }
        return true
    }

    @discardableResult
    public func flushAsync(timeout: TimeInterval = 1.0) -> Bool {
        let deadline = DispatchTime.now() + max(0, timeout)
        return asyncWriterGroup.wait(timeout: deadline) == .success
    }

    private static func runAsyncWriter(
        queue: DiagnosticsAsyncQueue<AsyncDiagnosticEvent>?,
        stop: AtomicUInt64?,
        group: DispatchGroup?,
        write: @escaping (AsyncDiagnosticEvent) -> Void
    ) {
        guard let queue, let stop, let group else { return }
        while stop.load() == 0 {
            guard let event = queue.dequeue() else {
                queue.wait()
                continue
            }
            write(event)
            group.leave()
        }

        while let event = queue.dequeue() {
            write(event)
            group.leave()
        }
    }

    public func snapshot() -> DiagnosticsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return DiagnosticsSnapshot(
            entryCount: tail.count,
            activeBytes: fileSizeLocked(activeURL),
            rotatedFileCount: rotatedURLsLocked()
                .filter { fileManager.fileExists(atPath: $0.path) }
                .count,
            level: configuredLevel,
            asyncQueueDepth: asyncQueue.count,
            asyncDroppedCount: asyncQueue.droppedCount
        )
    }

    public func recentLines(limit: Int = 200) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard limit > 0 else { return [] }
        return Array(tail.suffix(limit))
    }

    public func export() throws -> URL {
        guard flushAsync() else {
            throw NSError(domain: "HearPortDiagnostics",
                          code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "Diagnostics writer did not drain in time"])
        }
        lock.lock()
        defer { lock.unlock() }

        let exportURL = fileManager.temporaryDirectory
            .appendingPathComponent("HearPort-diagnostics-\(UUID().uuidString).log")
        var output = [
            "HearPort diagnostics",
            "Generated: \(formatter.string(from: clock()))",
            "Log level: \(configuredLevel.label.lowercased())",
            "Retained entries: \(tail.count)",
            "Async queue depth: \(asyncQueue.count)",
            "Async entries dropped: \(asyncQueue.droppedCount)",
            "",
            "Environment:"
        ]
        output.append(contentsOf: Self.environmentSummary())
        output.append(contentsOf: [
            "",
            "--- retained log files ---"
        ])

        var retainedFileCount = 0
        for url in Array(rotatedURLsLocked().reversed()) + [activeURL] {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                continue
            }
            retainedFileCount += 1
            output.append("\n--- \(url.lastPathComponent) ---")
            output.append(text.trimmingCharacters(in: .newlines))
        }

        if retainedFileCount == 0 {
            output.append("\n--- in-memory tail ---")
            output.append(contentsOf: tail)
        }
        try output.joined(separator: "\n").appending("\n")
            .write(to: exportURL, atomically: true, encoding: .utf8)
        return exportURL
    }

    public func clear() throws {
        guard flushAsync() else {
            throw NSError(domain: "HearPortDiagnostics",
                          code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "Diagnostics writer did not drain in time"])
        }
        lock.lock()
        defer { lock.unlock() }
        for url in [activeURL] + rotatedURLsLocked() where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        tail.removeAll(keepingCapacity: true)
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("HearPort/Logs", isDirectory: true)
    }

    private static func environmentSummary() -> [String] {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? "unknown"
        let appBuild = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
            ?? "unknown"
        return [
            "platform=\(platformName)",
            "os_version=\(osVersion)",
            "app_version=\(appVersion)",
            "app_build=\(appBuild)"
        ]
    }

    private static var platformName: String {
        #if os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #elseif os(Windows)
        return "Windows"
        #else
        return "unknown"
        #endif
    }

    private func loadTail() {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: activeURL),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        tail = Array(text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .suffix(tailLimit))
    }

    private func appendLocked(_ line: String) {
        var data = Data((line + "\n").utf8)
        if data.count > maxFileBytes {
            let prefix = String(line.prefix(max(1, maxFileBytes - 1))) + "\n"
            data = Data(prefix.utf8)
        }

        let currentSize = fileSizeLocked(activeURL)
        if currentSize > 0 && currentSize + data.count > maxFileBytes {
            rotateLocked()
        }
        if !fileManager.fileExists(atPath: activeURL.path) {
            fileManager.createFile(atPath: activeURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: activeURL) else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
        }
    }

    private func rotateLocked() {
        for index in stride(from: maxRotatedFiles, through: 1, by: -1) {
            let source = rotatedURL(index: index - 1)
            let destination = rotatedURL(index: index)
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.moveItem(at: source, to: destination)
            }
        }
        if fileManager.fileExists(atPath: activeURL.path) {
            if maxRotatedFiles > 0 {
                try? fileManager.moveItem(at: activeURL,
                                          to: rotatedURL(index: 0))
            } else {
                try? fileManager.removeItem(at: activeURL)
            }
        }
    }

    private func rotatedURLsLocked() -> [URL] {
        guard maxRotatedFiles > 0 else { return [] }
        return (0..<maxRotatedFiles).map(rotatedURL(index:))
    }

    private func rotatedURL(index: Int) -> URL {
        directory.appendingPathComponent("hearport.log.\(index)")
    }

    private func fileSizeLocked(_ url: URL) -> Int {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func emitToUnifiedLog(_ line: String, level: DiagnosticsLevel) {
        switch level {
        case .debug:
            osLogger.debug("\(line, privacy: .public)")
        case .info:
            osLogger.info("\(line, privacy: .public)")
        case .warning:
            osLogger.warning("\(line, privacy: .public)")
        case .error:
            osLogger.error("\(line, privacy: .public)")
        }
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return sensitiveKeyFragments.contains { normalized.contains($0) }
    }

    private static func redactMessage(_ message: String) -> String {
        message.split(whereSeparator: { $0.isWhitespace }).map { token in
            guard let equals = token.firstIndex(of: "=") else { return String(token) }
            let key = String(token[..<equals])
            return Self.isSensitiveKey(key)
                ? "\(key)=<redacted>"
                : String(token)
        }.joined(separator: " ")
    }
}
