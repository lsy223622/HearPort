#if canImport(SwiftUI) && canImport(Network) && canImport(AVFAudio) && os(iOS)
import AVFAudio
import Network
import SwiftUI

public struct HearPortApp: View {
    private let diagnostics = HearPortDiagnostics.shared
    @AppStorage(ConnectionPreferences.lastHostKey) private var lastHost = ""
    @AppStorage("hearport.rememberedHost") private var rememberedHost = ""
    @State private var host = ""
    @State private var currentHost = ""
    @State private var connectionID = UUID()
    @State private var isConnecting = false
    @State private var activeAudioMode: AudioTransportMode = .datagram
    @State private var activeBufferTargetPackets = JitterBufferConfiguration.defaultTargetPackets
    @State private var pin = ""
    @State private var authMode: AuthMode = .pair
    @State private var hasRememberedCredential = false
    @State private var didLoadRememberedCredential = false
    @State private var status = "Disconnected"
    @State private var connectionError: String?
    @State private var receiver = HearPortReceiver()
    @State private var control: ReceiverControlSession?
    @State private var audioOutput: PlatformAudioOutputController?
    @AppStorage("hearport.detailedLogging") private var detailedLogging = false
    @AppStorage("hearport.autoConnect") private var autoConnect = false
    @AppStorage("hearport.audioTransportMode") private var audioTransportModeRaw = AudioTransportMode.datagram.rawValue
    @AppStorage("hearport.jitterStartupPackets") private var jitterBufferTargetPackets = 8
    @State private var diagnosticsSnapshot = HearPortDiagnostics.shared.snapshot()
    @State private var exportedDiagnosticsURL: URL?
    @State private var diagnosticsStatus: String?
    @State private var showingClearConfirmation = false
    @State private var showingConnectionSetup = false

    public init() {}

    public var body: some View {
        NavigationStack {
            homeView
            .navigationTitle("HearPort")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        settingsView
                    } label: {
                        Image(systemName: "gearshape")
                            .accessibilityLabel(Text("Settings"))
                    }
                }
            }
        }
        .tint(Color.primary)
        .sheet(isPresented: $showingConnectionSetup) {
            NavigationStack {
                connectionSetupView
            }
            .tint(Color.primary)
        }
        .onAppear {
            if control == nil {
                status = Self.localize("Disconnected")
            }
            if !didLoadRememberedCredential {
                didLoadRememberedCredential = true
                host = lastHost
                do {
                    hasRememberedCredential = try KeychainRememberedCredentialStore().load() != nil
                    if hasRememberedCredential && rememberedHost.isEmpty {
                        rememberedHost = lastHost
                    }
                    authMode = ConnectionPreferences.defaultAuthMode(
                        hasRememberedCredential: hasRememberedCredential
                    )
                    if autoConnect && hasRememberedCredential &&
                        !lastHost.isEmpty && lastHost == rememberedHost {
                        connect()
                    }
                } catch {
                    authMode = .pair
                    diagnostics.log(
                        .warning,
                        category: .security,
                        message: "remembered_credential_load_failed",
                        fields: [
                            "event": "remembered_credential_load_failed",
                            "error_type": "\(type(of: error))"
                        ]
                    )
                }
            }
            jitterBufferTargetPackets = JitterBufferConfiguration(
                targetPackets: jitterBufferTargetPackets
            ).targetPackets
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
        .onChange(of: host) { newHost in
            if authMode == .remembered && newHost != rememberedHost {
                authMode = .pair
            }
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
            disconnect()
        }
    }

    private var homeView: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: connectionError == nil ? "speaker.wave.2.fill" : "exclamationmark.triangle")
                        .foregroundStyle(connectionError == nil ?
                                         (audioOutput == nil ? Color.secondary : Color.green) : Color.red)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(status)
                            .font(.headline)
                        if control == nil {
                            Text("Connect a Windows PC to play its audio here.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(currentHost)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 10)
                if control != nil || audioOutput != nil {
                    LabeledContent("Transport", value: Self.label(for: activeAudioMode))
                    LabeledContent("Buffer target", value: Self.bufferDescription(for: activeBufferTargetPackets))
                    Button("Disconnect", role: .destructive) {
                        disconnect()
                    }
                }
            }

            if !lastHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("Last connection") {
                    HStack {
                        Label(lastHost, systemImage: "desktopcomputer")
                        Spacer(minLength: 16)
                        Button("Connect") {
                            host = lastHost
                            if hasRememberedCredential && lastHost == rememberedHost {
                                authMode = .remembered
                                connect()
                            } else {
                                authMode = .oneTime
                                showingConnectionSetup = true
                            }
                        }
                        .disabled(isConnecting || audioOutput != nil)
                    }
                }
            }

            Section {
                Button {
                    showingConnectionSetup = true
                } label: {
                    Label("Enter PC address", systemImage: "plus")
                }
            } header: {
                Text("Other connection options")
            } footer: {
                Text("Use the address shown on your Windows PC. Pairing requires its six-digit code.")
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var connectionSetupView: some View {
        Form {
            Section("Windows PC") {
                TextField("Hostname or IP address", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("Connection method") {
                Picker("Authentication", selection: $authMode) {
                    if hasRememberedCredential && host == rememberedHost {
                        Text("Remembered").tag(AuthMode.remembered)
                    }
                    Text("Pair and remember").tag(AuthMode.pair)
                    Text("One-time").tag(AuthMode.oneTime)
                }
                if authMode != .remembered {
                    TextField("6-digit PIN", text: $pin)
                        .keyboardType(.numberPad)
                    Text("Enter the code displayed by HearPort on Windows.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Connect") {
                    connect()
                    showingConnectionSetup = false
                }
                .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          (authMode != .remembered && !PairingSecurity.validatePIN(pin)))
            }
        }
        .navigationTitle("Connect to a PC")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { showingConnectionSetup = false }
            }
        }
    }

    private var settingsView: some View {
        Form {
            Section {
                Picker("Audio transport mode", selection: $audioTransportModeRaw) {
                    Text("Low latency").tag(AudioTransportMode.datagram.rawValue)
                    Text("Stability").tag(AudioTransportMode.reliable.rawValue)
                }
                Picker("Buffer target", selection: $jitterBufferTargetPackets) {
                    ForEach(JitterBufferConfiguration.supportedTargetPacketCounts, id: \.self) { packets in
                        Text("\(Self.jitterLabel(for: packets)) · \(Self.bufferDescription(for: packets))")
                            .tag(packets)
                    }
                }
            } header: {
                Text("Playback")
            } footer: {
                Text("Both modes use the selected buffer target. Changes take effect on the next connection. A larger buffer may reduce interruptions but adds delay.")
            }
            Section {
                Toggle("Connect on launch", isOn: $autoConnect)
                    .tint(.green)
            } header: {
                Text("Connection")
            } footer: {
                Text("Uses the last connected PC when its pairing is saved.")
            }
            Section("Support") {
                NavigationLink {
                    diagnosticsView
                } label: {
                    Label("Diagnostics", systemImage: "waveform.path.ecg")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var diagnosticsView: some View {
        Form {
            Section {
                LabeledContent("Logging level", value: Self.label(for: diagnosticsSnapshot.level))
                LabeledContent("Retained entries", value: "\(diagnosticsSnapshot.entryCount)")
                LabeledContent("Active log size", value: Self.byteLabel(diagnosticsSnapshot.activeBytes))
                Toggle("Detailed logging", isOn: $detailedLogging)
                    .tint(.green)
            } header: {
                Text("Current log")
            } footer: {
                Text("Secrets, authentication material, and raw audio are excluded from logs.")
            }
            Section("Actions") {
                Button {
                    exportDiagnostics()
                } label: {
                    Label("Export diagnostics", systemImage: "square.and.arrow.down")
                }
                if let exportedDiagnosticsURL {
                    ShareLink(item: exportedDiagnosticsURL,
                              subject: Text("HearPort diagnostics"),
                              message: Text("HearPort troubleshooting log")) {
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
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshDiagnostics() }
    }

    private func connect() {
        let endpoint = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedAuthMode = authMode
        if requestedAuthMode != .remembered && !PairingSecurity.validatePIN(pin) {
            status = Self.localize("Enter the 6-digit PIN shown on Windows")
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
        connectionID = UUID()
        let activeConnectionID = connectionID
        isConnecting = true
        connectionError = nil
        currentHost = endpoint
        let audioMode = AudioTransportMode(rawValue: audioTransportModeRaw) ?? .datagram
        let normalizedJitter = JitterBufferConfiguration(
            targetPackets: audioMode.bufferTargetPackets(selected: jitterBufferTargetPackets)
        )
        jitterBufferTargetPackets = normalizedJitter.targetPackets
        activeAudioMode = audioMode
        activeBufferTargetPackets = normalizedJitter.targetPackets
        let activeReceiver = HearPortReceiver(
            bufferTargetPackets: normalizedJitter.targetPackets,
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
                "auth_mode": "\(requestedAuthMode)",
                "audio_mode": audioMode.rawValue
            ]
        )
        let session = ReceiverControlSession(
            receiver: activeReceiver,
            audioMode: audioMode,
            provider: PairingSecurity.defaultSpake2Provider()
        )
        session.onTransportState = { newState in
            DispatchQueue.main.async {
                guard connectionID == activeConnectionID else { return }
                if newState == .failed || newState == .closed {
                    isConnecting = false
                    try? audioOutput?.stop()
                    audioOutput = nil
                }
                status = connectionError ?? Self.label(for: newState)
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
                guard connectionID == activeConnectionID else { return }
                isConnecting = false
                connectionError = Self.localize(message)
                status = connectionError ?? Self.localize("Connection failed")
                refreshDiagnostics()
            }
        }
        session.onReady = {
            DispatchQueue.main.async {
                guard connectionID == activeConnectionID else { return }
                isConnecting = false
                connectionError = nil
                if requestedAuthMode == .pair {
                    authMode = .remembered
                    hasRememberedCredential = true
                    rememberedHost = endpoint
                    pin = ""
                }
                lastHost = endpoint
                do {
                    let output = PlatformAudioOutputController(receiver: activeReceiver)
                    try output.start()
                    audioOutput = output
                    status = Self.localize("Playing")
                    diagnostics.log(
                        .info,
                        category: .app,
                        message: "ui_playback_started",
                        fields: ["event": "ui_playback_started"]
                    )
                } catch {
                    status = Self.localize("Audio output unavailable")
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
        session.connect(host: endpoint, mode: requestedAuthMode, pin: pin)
    }

    private func disconnect() {
        let hadActiveSession = control != nil || audioOutput != nil
        connectionID = UUID()
        isConnecting = false
        connectionError = nil
        control?.cancel()
        control = nil
        try? audioOutput?.stop()
        audioOutput = nil
        currentHost = ""
        status = Self.localize("Disconnected")
        if hadActiveSession {
            diagnostics.log(
                .info,
                category: .app,
                message: "ui_disconnected",
                fields: ["event": "ui_disconnected"]
            )
        }
        refreshDiagnostics()
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
            diagnosticsStatus = Self.localize("Diagnostics export is ready to share.")
        } catch {
            exportedDiagnosticsURL = nil
            diagnosticsStatus = Self.localize("Unable to export diagnostics.")
        }
        refreshDiagnostics()
    }

    private func clearDiagnostics() {
        do {
            try diagnostics.clear()
            exportedDiagnosticsURL = nil
            diagnosticsStatus = Self.localize("Diagnostics cleared.")
        } catch {
            diagnosticsStatus = Self.localize("Unable to clear diagnostics.")
        }
        refreshDiagnostics()
    }

    private static func label(for state: QuicReceiverState) -> String {
        switch state {
        case .idle: return localize("Disconnected")
        case .connecting: return localize("Connecting")
        case .ready: return localize("Connected")
        case .failed: return localize("Connection failed")
        case .closed: return localize("Disconnected")
        }
    }

    private static func label(for level: DiagnosticsLevel) -> String {
        switch level {
        case .debug: return localize("Debug")
        case .info: return localize("Info")
        case .warning: return localize("Warning")
        case .error: return localize("Error")
        }
    }

    private static func label(for mode: AudioTransportMode) -> String {
        switch mode {
        case .datagram: return localize("Low latency")
        case .reliable: return localize("Stability")
        }
    }

    private static func jitterLabel(for packets: Int) -> String {
        switch packets {
        case 4: return localize("Low latency")
        case 8: return localize("Balanced")
        case 16: return localize("Stable")
        case 32: return localize("Strong stability")
        case 64: return localize("Very stable")
        case 128: return localize("Maximum stability")
        default: return localize("Custom")
        }
    }

    private static func byteLabel(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func bufferDescription(for packets: Int) -> String {
        let configuration = JitterBufferConfiguration(targetPackets: packets)
        return String(format: localize("%d packets · %d ms"),
                      configuration.targetPackets,
                      configuration.targetLatencyMilliseconds)
    }

    private static func localize(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, comment: "")
    }
}

public typealias HearPortReceiverView = HearPortApp
#endif
