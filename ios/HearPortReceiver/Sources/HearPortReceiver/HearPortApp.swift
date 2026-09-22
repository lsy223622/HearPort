#if canImport(SwiftUI) && canImport(Network) && canImport(AVFAudio) && os(iOS)
import AVFAudio
import Network
import SwiftUI

public struct HearPortApp: View {
    private let diagnostics = HearPortDiagnostics.shared
    @State private var host = ""
    @State private var pin = ""
    @State private var authMode: AuthMode = .pair
    @State private var status = "Disconnected"
    @State private var receiver = HearPortReceiver()
    @State private var control: ReceiverControlSession?
    @State private var audioOutput: PlatformAudioOutputController?
    @AppStorage("hearport.detailedLogging") private var detailedLogging = false
    @AppStorage("hearport.jitterStartupPackets") private var jitterStartupPackets = 8
    @State private var diagnosticsSnapshot = HearPortDiagnostics.shared.snapshot()
    @State private var exportedDiagnosticsURL: URL?
    @State private var diagnosticsStatus: String?
    @State private var showingClearConfirmation = false

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section("Windows PC") {
                    TextField("Hostname or IP address", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Authentication", selection: $authMode) {
                        Text("Pair new PC").tag(AuthMode.pair)
                        Text("One-time").tag(AuthMode.oneTime)
                        Text("Remembered").tag(AuthMode.remembered)
                    }
                    if authMode != .remembered {
                        TextField("6-digit PIN", text: $pin)
                            .keyboardType(.numberPad)
                    }
                    Button("Connect") {
                        connect()
                    }
                    .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text(status)
                        .foregroundStyle(.secondary)
                }

                Section("Jitter buffer") {
                    Picker("Startup buffer", selection: $jitterStartupPackets) {
                        ForEach(JitterBufferConfiguration.supportedStartupPacketCounts, id: \.self) { packets in
                            let configuration = JitterBufferConfiguration(startupPackets: packets)
                            Text("\(Self.jitterLabel(for: packets)) · \(packets) packets (\(configuration.startupLatencyMilliseconds) ms)")
                                .tag(packets)
                        }
                    }
                    let configuration = JitterBufferConfiguration(startupPackets: jitterStartupPackets)
                    Text("Estimated startup delay: \(configuration.startupLatencyMilliseconds) ms")
                        .foregroundStyle(.secondary)
                    Text("Larger buffers tolerate bursty delivery but increase startup latency.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Applies on next connection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Diagnostics") {
                    HStack {
                        Label("Logging level", systemImage: "waveform.path.ecg")
                        Spacer()
                        Text(Self.label(for: diagnosticsSnapshot.level))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Retained entries")
                        Spacer()
                        Text("\(diagnosticsSnapshot.entryCount)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Active log size")
                        Spacer()
                        Text(Self.byteLabel(diagnosticsSnapshot.activeBytes))
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Detailed logging", isOn: $detailedLogging)
                    Text("Secrets, authentication material, and raw audio are excluded from logs.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        exportDiagnostics()
                    } label: {
                        Label("Export diagnostics", systemImage: "doc.text.magnifyingglass")
                    }
                    if let exportedDiagnosticsURL {
                        ShareLink(
                            item: exportedDiagnosticsURL,
                            subject: Text("HearPort diagnostics"),
                            message: Text("HearPort troubleshooting log")
                        ) {
                            Label("Share exported log", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button("Clear diagnostics", role: .destructive) {
                        showingClearConfirmation = true
                    }
                    if let diagnosticsStatus {
                        Text(diagnosticsStatus)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("HearPort")
        }
        .onAppear {
            status = "Disconnected"
            jitterStartupPackets = JitterBufferConfiguration(
                startupPackets: jitterStartupPackets
            ).startupPackets
            diagnostics.level = detailedLogging ? .debug : .info
            refreshDiagnostics()
        }
        .onChange(of: detailedLogging) { enabled in
            diagnostics.level = enabled ? .debug : .info
            diagnostics.log(
                .info,
                category: .app,
                message: "ui_logging_level_changed",
                fields: ["event": "ui_logging_level_changed", "level": enabled ? "debug" : "info"]
            )
            refreshDiagnostics()
        }
        .confirmationDialog(
            "Clear retained diagnostics?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                clearDiagnostics()
            }
            Button("Cancel", role: .cancel) {}
        }
        .onDisappear {
            control?.cancel()
            try? audioOutput?.stop()
            audioOutput = nil
        }
    }

    private func connect() {
        let endpoint = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if authMode != .remembered && !PairingSecurity.validatePIN(pin) {
            status = "Enter the 6-digit PIN shown on Windows"
            diagnostics.log(
                .warning,
                category: .app,
                message: "ui_connect_rejected",
                fields: ["event": "ui_connect_rejected", "reason": "invalid_pin_format"]
            )
            refreshDiagnostics()
            return
        }
        control?.cancel()
        try? audioOutput?.stop()
        audioOutput = nil
        let normalizedJitter = JitterBufferConfiguration(startupPackets: jitterStartupPackets)
        jitterStartupPackets = normalizedJitter.startupPackets
        let activeReceiver = HearPortReceiver(
            startupPackets: normalizedJitter.startupPackets,
            diagnostics: diagnostics
        )
        receiver = activeReceiver
        diagnostics.log(
            .info,
            category: .app,
            message: "ui_connect_requested",
            fields: [
                "event": "ui_connect_requested",
                "host": endpoint,
                "auth_mode": "\(authMode)"
            ]
        )
        let session = ReceiverControlSession(
            receiver: activeReceiver,
            provider: PairingSecurity.defaultSpake2Provider()
        )
        session.onTransportState = { newState in
            DispatchQueue.main.async {
                status = Self.label(for: newState)
                refreshDiagnostics()
            }
        }
        session.onError = { message in
            diagnostics.log(
                .warning,
                category: .app,
                message: "ui_connection_error",
                fields: ["event": "ui_connection_error", "message_bytes": "\(message.utf8.count)"]
            )
            DispatchQueue.main.async {
                status = message
                refreshDiagnostics()
            }
        }
        session.onReady = {
            DispatchQueue.main.async {
                do {
                    let output = PlatformAudioOutputController(receiver: activeReceiver)
                    try output.start()
                    audioOutput = output
                    status = "Playing"
                    diagnostics.log(
                        .info,
                        category: .app,
                        message: "ui_playback_started",
                        fields: ["event": "ui_playback_started"]
                    )
                } catch {
                    status = "Audio output unavailable"
                    diagnostics.log(
                        .error,
                        category: .app,
                        message: "ui_playback_start_failed",
                        fields: [
                            "event": "ui_playback_start_failed",
                            "error_type": "\(type(of: error))"
                        ]
                    )
                }
                refreshDiagnostics()
            }
        }
        control = session
        session.connect(host: endpoint, mode: authMode, pin: pin)
    }

    private func refreshDiagnostics() {
        diagnosticsSnapshot = diagnostics.snapshot()
    }

    private func exportDiagnostics() {
        diagnostics.log(
            .info,
            category: .app,
            message: "ui_export_requested",
            fields: ["event": "ui_export_requested"]
        )
        do {
            exportedDiagnosticsURL = try diagnostics.export()
            diagnosticsStatus = "Diagnostics export is ready to share."
        } catch {
            exportedDiagnosticsURL = nil
            diagnosticsStatus = "Unable to export diagnostics."
        }
        refreshDiagnostics()
    }

    private func clearDiagnostics() {
        do {
            try diagnostics.clear()
            exportedDiagnosticsURL = nil
            diagnosticsStatus = "Diagnostics cleared."
        } catch {
            diagnosticsStatus = "Unable to clear diagnostics."
        }
        refreshDiagnostics()
    }

    private static func label(for state: QuicReceiverState) -> String {
        switch state {
        case .idle: return "Disconnected"
        case .connecting: return "Connecting"
        case .ready: return "Connected"
        case .failed: return "Connection failed"
        case .closed: return "Disconnected"
        }
    }

    private static func label(for level: DiagnosticsLevel) -> String {
        switch level {
        case .debug: return "Debug"
        case .info: return "Info"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }

    private static func jitterLabel(for packets: Int) -> String {
        switch packets {
        case 4: return "Low latency"
        case 8: return "Balanced"
        case 16: return "Stable"
        case 32: return "Strong stability"
        case 64: return "Very stable"
        case 128: return "Maximum stability"
        default: return "Custom"
        }
    }

    private static func byteLabel(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

public typealias HearPortReceiverView = HearPortApp
#endif
