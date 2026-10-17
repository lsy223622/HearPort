#if canImport(SwiftUI) && canImport(Network) && canImport(AVFAudio) && os(iOS)
import AVFAudio
import Network
import SwiftUI

@MainActor public struct HearPortApp: View {
    private let diagnostics = HearPortDiagnostics.shared
    @AppStorage(ConnectionPreferences.lastHostKey) private var lastHost = ""
    @AppStorage("hearport.rememberedHost") private var rememberedHost = ""
    @State private var selectedEndpoint: ConnectionEndpoint?
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
    @State private var connectionEstablished = false
    @State private var completedTestStatus: String?
    @State private var receiver = HearPortReceiver()
    @StateObject private var connectionManager = ReceiverConnectionCoordinator()
    @State private var pendingControls: [UUID: ReceiverControlSession] = [:]
    @State private var activePath: ConnectionPath = .network
    @State private var control: ReceiverControlSession?
    @State private var audioOutput: PlatformAudioOutputController?
    @AppStorage("hearport.detailedLogging") private var detailedLogging = false
    @AppStorage("hearport.autoConnect") private var autoConnect = false
    @AppStorage("hearport.audioTransportMode") private var audioTransportModeRaw = AudioTransportMode.datagram.rawValue
    @AppStorage("hearport.jitterStartupPackets") private var jitterBufferTargetPackets = 8
    @AppStorage("hearport.targetLatencyMs") private var targetLatencyMs = 50
    @AppStorage("hearport.maximumLatencyMs") private var maximumLatencyMs = 100
    @State private var activeTargetLatencyMs = 50
    @State private var activeMaximumLatencyMs = 100
    @State private var diagnosticsSnapshot = HearPortDiagnostics.shared.snapshot()
    @State private var exportedDiagnosticsURL: URL?
    @State private var diagnosticsStatus: String?
    @State private var showingClearConfirmation = false
    @State private var showingConnectionSetup = false
    @State private var calibrationResult: CalibrationResult? = CalibrationResult.load()
    @State private var sendingReport = false
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        NavigationStack {
            homeView
            .navigationTitle("HearPort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("HearPort")
                        .font(.system(size: 32, weight: .semibold))
                }
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
        .background(Color(uiColor: .systemGroupedBackground))
        .tint(Color.primary)
        .sheet(isPresented: $showingConnectionSetup) {
            NavigationStack {
                connectionSetupView
            }
            .tint(Color.primary)
        }
        .onAppear {
            connectionManager.onRequest = { id, route in beginConnection(id: id, route: route) }
            connectionManager.onCancel = { id in
                if let candidate = pendingControls.removeValue(forKey: id) { candidate.cancel() }
                if id == connectionID {
                    control?.end(reason: 2); control = nil
                    try? audioOutput?.stop(); audioOutput = nil
                }
            }
            connectionManager.onSearching = {
                if completedTestStatus == nil { showConnectionSearch() }
            }
            connectionManager.start()
            if control == nil {
                status = Self.localize("Disconnected")
            }
            if !didLoadRememberedCredential {
                didLoadRememberedCredential = true
                host = lastHost
                do {
                    let remembered = try KeychainRememberedCredentialStore().load()
                    hasRememberedCredential = remembered != nil
                    connectionManager.setRememberedIdentity(remembered?.windowsSPKISHA256)
                    if hasRememberedCredential && rememberedHost.isEmpty {
                        rememberedHost = lastHost
                    }
                    authMode = ConnectionPreferences.defaultAuthMode(
                        hasRememberedCredential: hasRememberedCredential
                    )
                    if autoConnect && hasRememberedCredential {
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
        .onChange(of: scenePhase) { phase in
            if phase == .background { control?.interruptCalibration() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            control?.interruptCalibration(forOutputChange: true)
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
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if !isConnecting && audioOutput == nil &&
                        control?.isNetworkProbe != true {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Connect to a PC")
                                .font(.largeTitle.weight(.bold))
                            Text("Bring Windows audio to this iPad.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    statusCard

                    if !isConnecting && audioOutput == nil &&
                        control?.isNetworkProbe != true &&
                        !lastHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Last connection")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 16) {
                                connectionLabel(Text(lastHost), systemImage: "desktopcomputer")
                                Spacer(minLength: 16)
                                Button {
                                    host = lastHost
                                    if hasRememberedCredential && lastHost == rememberedHost {
                                        authMode = .remembered
                                        connect()
                                    } else {
                                        authMode = .oneTime
                                        showingConnectionSetup = true
                                    }
                                } label: {
                                    Text("Connect")
                                        .foregroundStyle(Color(uiColor: .systemBackground))
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(isConnecting || audioOutput != nil ||
                                          control?.isNetworkProbe == true)
                            }
                            .padding(20)
                            .background(Color(uiColor: .secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 16))
                        }
                    }

                    if !isConnecting && audioOutput == nil && control?.isNetworkProbe != true && !connectionManager.endpoints.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Available connections").font(.subheadline).foregroundStyle(.secondary)
                            ForEach(connectionManager.endpoints) { endpoint in
                                Button {
                                    selectedEndpoint = endpoint
                                    if hasRememberedCredential { authMode = .remembered; connect(selected: endpoint) }
                                    else { showingConnectionSetup = true }
                                } label: {
                                    connectionLabel(Text(endpoint.path == .usb ? "USB" : endpoint.host),
                                                    systemImage: endpoint.path == .usb ? "cable.connector" : "desktopcomputer")
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                                }.buttonStyle(.plain)
                            }
                        }
                    }

                    if !isConnecting && audioOutput == nil &&
                        control?.isNetworkProbe != true {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Other connection options")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button {
                                showingConnectionSetup = true
                            } label: {
                                connectionLabel(Text("Enter PC address"), systemImage: "plus")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(20)
                                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                                in: RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                            Text("Use the address shown on your Windows PC. Pairing requires its six-digit code.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: 960)
                .padding(.horizontal, 28)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .background(Color(uiColor: .systemGroupedBackground))
        }
    }

    private func connectionLabel(_ title: Text, systemImage: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 36)
            title
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(minHeight: 34)
    }

    private var statusCard: some View {
        VStack(spacing: 14) {
            Group {
                if connectionError == nil {
                    Image("HearPortSymbol", bundle: .main)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 44, height: 44)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 34))
                        .foregroundStyle(.red)
                }
            }
            .frame(width: 72, height: 72)
            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Circle())

            Text(status)
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.center)

            if control != nil {
                Text((activePath == .usb ? "USB · " : Self.localize("Network") + " · ") + currentHost)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if isConnecting {
                Text("Searching network and USB…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Choose a PC below to connect.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if isConnecting {
                ProgressView()
                    .padding(.top, 4)
            }

            if audioOutput != nil {
                Divider()
                    .padding(.vertical, 8)
                HStack(spacing: 24) {
                    VStack(spacing: 4) {
                        Text("Transport")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(Self.label(for: activeAudioMode))
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: 4) {
                        Text("Buffer target")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(activeTargetLatencyMs) / \(activeMaximumLatencyMs) ms")
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            if control != nil || audioOutput != nil || isConnecting {
                Button("Disconnect", role: .destructive) {
                    disconnect()
                }
                .buttonStyle(.bordered)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .frame(minHeight: isConnecting || audioOutput != nil ? 340 : 280)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 20))
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
                    if hasRememberedCredential && (host == rememberedHost || connectionManager.hasUSB || !connectionManager.endpoints.isEmpty) {
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
                    connect(selected: selectedEndpoint)
                    showingConnectionSetup = false
                }
                .disabled((host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && connectionManager.endpoints.isEmpty) ||
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
                    Text("Datagram").tag(AudioTransportMode.datagram.rawValue)
                    Text("Reliable stream").tag(AudioTransportMode.reliable.rawValue)
                }
                Stepper("Normal target: \(targetLatencyMs) ms", value: $targetLatencyMs,
                        in: 10...max(10, maximumLatencyMs), step: 10)
                Stepper("Maximum total delay: \(maximumLatencyMs) ms", value: $maximumLatencyMs,
                        in: max(20, targetLatencyMs)...2_000, step: 10)
            } header: {
                Text("Playback")
            } footer: {
                Text("The target and maximum include transport, processing and output. Changes take effect on the next connection. A higher maximum can tolerate longer interruptions.")
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
                NavigationLink("Environment calibration") {
                    CalibrationResultsView(result: calibrationResult) { profile in
                        if calibrationResult?.apply(profile: profile) == true {
                            audioTransportModeRaw = UserDefaults.standard.string(forKey: "hearport.audioTransportMode") ?? AudioTransportMode.datagram.rawValue
                            targetLatencyMs = UserDefaults.standard.integer(forKey: "hearport.targetLatencyMs")
                            maximumLatencyMs = UserDefaults.standard.integer(forKey: "hearport.maximumLatencyMs")
                        }
                    }
                }
                NavigationLink {
                    diagnosticsView
                } label: {
                    Label("Diagnostics", systemImage: "waveform.path.ecg")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
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
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear { refreshDiagnostics() }
    }

    private func connect(selected: ConnectionEndpoint? = nil) {
        guard authMode == .remembered || PairingSecurity.validatePIN(pin) else {
            status = Self.localize("Enter the 6-digit PIN shown on Windows"); return
        }
        completedTestStatus = nil; connectionError = nil
        isConnecting = true; status = Self.localize("Searching network and USB…")
        connectionManager.setMaximumLatency(maximumLatencyMs)
        connectionManager.connect(manualHost: host.trimmingCharacters(in: .whitespacesAndNewlines), selected: selected)
    }

    private func beginConnection(id: UUID, route: ConnectionEndpoint) {
        let endpoint = route.host
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
        let activeConnectionID = id
        if control == nil {
            isConnecting = true; connectionError = nil
            status = Self.localize(route.path == .usb ? "Connecting via USB…" : "Connecting via network…")
        }
        let audioMode = AudioTransportMode(rawValue: audioTransportModeRaw) ?? .datagram
        let normalizedJitter = JitterBufferConfiguration(
            targetPackets: audioMode.bufferTargetPackets(selected: jitterBufferTargetPackets)
        )
        jitterBufferTargetPackets = normalizedJitter.targetPackets
        let activeReceiver = HearPortReceiver(
            bufferTargetPackets: normalizedJitter.targetPackets,
            diagnostics: diagnostics
        )
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
        activeReceiver.debugSessionDiagnostics.configureConnection(path: route.path, id: id)
        let session = ReceiverControlSession(
            receiver: activeReceiver,
            audioMode: audioMode,
            provider: PairingSecurity.defaultSpake2Provider()
        )
        let target = targetLatencyMs, maximum = maximumLatencyMs
        session.requestedBudget = try! PlayoutBudget(targetMilliseconds: Double(target),
            maximumMilliseconds: Double(maximum), outputReserveMilliseconds: 1)
        let prepareOutputReserve: () throws -> Double = {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setPreferredIOBufferDuration(0.005)
            try audioSession.setActive(true)
            let reserve = ceil((audioSession.outputLatency + audioSession.ioBufferDuration) * 1_000) + 1
            return reserve
        }
        session.prepareCalibrationOutputReserve = prepareOutputReserve
        session.calibrationContext = {
            let output = AVAudioSession.sharedInstance()
            return CalibrationContext(device: UIDevice.current.model,
                operatingSystem: UIDevice.current.systemName + " " + UIDevice.current.systemVersion,
                output: output.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","), sampleRate: output.sampleRate)
        }
        session.preparePlayoutBudget = {
            try PlayoutBudget(targetMilliseconds: Double(target), maximumMilliseconds: Double(maximum),
                              outputReserveMilliseconds: prepareOutputReserve())
        }
        var authenticatedIdentity: Data?
        session.onAuthenticated = { [weak session] identity, features in
            DispatchQueue.main.async {
                guard let session, pendingControls[id] === session else { return }
                authenticatedIdentity = identity
                if requestedAuthMode == .pair {
                    hasRememberedCredential = true; authMode = .remembered; pin = ""
                    connectionManager.setRememberedIdentity(identity)
                }
                guard connectionManager.authenticated(id, identity: identity, features: features) else { return }
                connectionID = id; control = session; receiver = activeReceiver
                pendingControls.removeValue(forKey: id)
                currentHost = endpoint; activePath = route.path
                connectionEstablished = false; connectionError = nil; completedTestStatus = nil
                activeAudioMode = audioMode; activeBufferTargetPackets = normalizedJitter.targetPackets
                activeTargetLatencyMs = target; activeMaximumLatencyMs = maximum
                sendingReport = false; isConnecting = true
                status = Self.localize(route.path == .usb ? "Connecting via USB…" : "Connecting via network…")
                diagnostics.log(.info, category: .transport, message: "physical_path_selected",
                    fields: ["physical_path": route.path.rawValue, "connection_id": id.uuidString])
                session.activate()
            }
        }
        session.onSessionEnded = { reason in
            DispatchQueue.main.async {
                guard connectionID == id || (reason == 1 && authenticatedIdentity.map { connectionManager.acceptsStop(from: $0) } == true) else { return }
                if reason == 1 {
                    let completed = completedTestStatus
                    control?.cancel(); control = nil
                    connectionManager.stop(); connectionID = UUID()
                    isConnecting = false; connectionError = nil
                    status = completed ?? Self.localize("PC stopped the connection")
                } else { connectionManager.ended(id) }
            }
        }
        session.onDiagnosticSessionStarted = {
            DispatchQueue.main.async { if connectionID == id { connectionManager.pinActive() } }
        }
        session.onCalibrationProgress = { progress in
            DispatchQueue.main.async {
                guard connectionID == activeConnectionID, completedTestStatus == nil, !sendingReport else { return }
                let stage = Self.localize(progress.stage == "analyzing" ? "Analyzing calibration" : progress.stage == "validation" ?
                    "Validating recommendations" : progress.stage == "interrupted" ? "Calibration interrupted" : "Sampling network")
                status = stage + (progress.stage == "analyzing" ? " · \(progress.completed)/\(progress.total)" : " · \(progress.index)/\(progress.count)")
            }
        }
        session.onCalibrationResult = { result in
            DispatchQueue.main.async {
                guard connectionID == activeConnectionID else { return }
                if result.save() { calibrationResult = result }
                else if calibrationResult == nil { calibrationResult = result }
            }
        }
        session.onTransportState = { newState in
            DispatchQueue.main.async {
                if newState == .failed || newState == .closed { connectionManager.ended(id) }
                guard connectionID == activeConnectionID else { return }
                if newState == .failed || newState == .closed {
                    isConnecting = false
                    try? audioOutput?.stop()
                    audioOutput = nil
                }
                if newState == .failed || newState == .closed {
                    if completedTestStatus == nil && connectionManager.isWaiting {
                        showConnectionSearch()
                    } else {
                        status = completedTestStatus ?? connectionError ??
                            (connectionEstablished ? Self.localize("Connection ended. Reconnect to continue.") : Self.label(for: newState))
                    }
                } else {
                    status = connectionError ?? Self.label(for: newState)
                }
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
                if authenticatedIdentity == nil && connectionManager.isWaiting && control == nil && requestedAuthMode != .remembered {
                    connectionManager.stop(); isConnecting = false
                    connectionError = Self.localize(message); status = connectionError ?? Self.localize("Connection failed")
                    return
                }
                connectionManager.ended(id)
                guard connectionID == activeConnectionID else { return }
                guard completedTestStatus == nil else { return }
                if connectionManager.isWaiting { showConnectionSearch(); return }
                isConnecting = false
                connectionError = Self.localize(message)
                status = connectionError ?? Self.localize("Connection failed")
                refreshDiagnostics()
            }
        }
        session.onReady = { [weak session] in
            DispatchQueue.main.async {
                guard connectionID == activeConnectionID else { return }
                isConnecting = false
                connectionEstablished = true
                connectionError = nil
                if requestedAuthMode == .pair {
                    authMode = .remembered
                    hasRememberedCredential = true
                    if route.path == .network, case .hostPort = route.endpoint { rememberedHost = endpoint }
                    pin = ""
                }
                if route.path == .network, case .hostPort = route.endpoint {
                    lastHost = endpoint; if hasRememberedCredential { rememberedHost = endpoint }
                }
                if session?.isNetworkProbe == true {
                    status = Self.localize("Network test running")
                    refreshDiagnostics()
                    return
                }
                do {
                    let output = PlatformAudioOutputController(receiver: activeReceiver)
                    try output.start()
                    audioOutput = output
                    status = session?.musicTestRound.map { Self.label(for: $0) } ??
                        Self.localize(session?.isMusicTest == true ? "Music test running" : "Playing")
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
        session.onMusicTestRound = { round in
            DispatchQueue.main.async {
                guard connectionID == activeConnectionID, completedTestStatus == nil else { return }
                status = Self.label(for: round)
                refreshDiagnostics()
            }
        }
        session.onDiagnosticReportSending = {
            DispatchQueue.main.async {
                guard connectionID == activeConnectionID else { return }
                connectionManager.pinActive()
                sendingReport = true
                status = Self.localize("Test ended. Preparing and sending the report…")
                refreshDiagnostics()
            }
        }
        session.onDiagnosticReportReceived = { reason in
            DispatchQueue.main.async {
                guard connectionID == activeConnectionID else { return }
                let message = Self.localize(reason == 1
                    ? "Test complete. Report saved on the PC."
                    : "Test ended. Report saved on the PC.")
                connectionManager.completed()
                completedTestStatus = message
                connectionError = nil
                isConnecting = false
                try? audioOutput?.stop()
                audioOutput = nil
                status = message
                refreshDiagnostics()
            }
        }
        pendingControls[id] = session
        session.connect(host: endpoint, port: route.port, mode: requestedAuthMode, pin: pin, endpoint: route.endpoint, deferActivation: true)
    }

    private func showConnectionSearch() {
        isConnecting = true; connectionError = nil
        status = Self.localize("Searching network and USB…")
    }

    private func disconnect() {
        control?.end(reason: 1)
        connectionManager.stop()
        let hadActiveSession = control != nil || audioOutput != nil
        connectionID = UUID()
        isConnecting = false
        connectionError = nil
        connectionEstablished = false
        completedTestStatus = nil
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

    private static func label(for round: MusicTestRound) -> String {
        String(format: localize("Music test %d/8 · %@ · %@"), round.index,
               round.reliable ? "Reliable" : "Datagram",
               localize(round.adaptive ? "Adaptive" : "Fixed"))
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
