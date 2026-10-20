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
    @State private var testCompletedNormally = true
    @State private var receiver = HearPortReceiver()
    @StateObject private var connectionManager = ReceiverConnectionCoordinator()
    @State private var pendingControls: [UUID: ReceiverControlSession] = [:]
    @State private var activePath: ConnectionPath = .network
    @State private var control: ReceiverControlSession?
    @State private var audioOutput: PlatformAudioOutputController?
    @AppStorage("hearport.detailedLogging") private var detailedLogging = false
    @AppStorage("hearport.autoConnect") private var autoConnect = false
    @AppStorage("hearport.usbAudio.transport") private var usbTransportModeRaw = AudioTransportMode.reliable.rawValue
    @AppStorage("hearport.audioTransportMode") private var audioTransportModeRaw = AudioTransportMode.datagram.rawValue
    @AppStorage("hearport.jitterStartupPackets") private var jitterBufferTargetPackets = 8
    @AppStorage("hearport.targetLatencyMs") private var targetLatencyMs = 50
    @AppStorage("hearport.maximumLatencyMs") private var maximumLatencyMs = 100
    @AppStorage("hearport.networkAudio.codec") private var networkCodec = "opus"
    @AppStorage("hearport.networkAudio.bitrate") private var networkBitrate = 256_000
    @AppStorage("hearport.networkAudio.frames") private var networkFrames = 240
    @AppStorage("hearport.usbAudio.codec") private var usbCodec = "pcm"
    @AppStorage("hearport.usbAudio.bitrate") private var usbBitrate = 256_000
    @AppStorage("hearport.usbAudio.frames") private var usbFrames = 240
    @State private var activeAudioFormat: AudioStreamFormat = .pcm
    @State private var activeTargetLatencyMs = 50
    @State private var activeMaximumLatencyMs = 100
    @State private var diagnosticsSnapshot = HearPortDiagnostics.shared.snapshot()
    @State private var exportedDiagnosticsURL: URL?
    @State private var exportingDiagnostics = false
    @State private var diagnosticsStatus: String?
    @State private var showingClearConfirmation = false
    @State private var showingConnectionSetup = false
    @State private var calibrationResult: CalibrationResult? = CalibrationResult.load()
    @State private var calibrationRunResult: CalibrationResult?
    @State private var adaptiveResult = AdaptiveCalibrationResult.load()
    @State private var adaptiveRunResult: AdaptiveCalibrationResult?
    @State private var calibrationProgress: CalibrationProgressSnapshot?
    @State private var calibrationNow: UInt64 = 0
    @State private var sendingReport = false
    @State private var canvasSheet: CanvasSheet?
    @State private var currentComputerName = ""
    @State private var currentComputerIdentity = ""
    @State private var calibrationRequestID: UUID?
    @State private var calibrationStartStatus: String?
    @State private var retainingConnection = false
    @State private var qualityTracker = LinkStabilityTracker()
    @State private var linkSample: LinkTimingSample?
    @State private var musicRound: MusicTestRound?
    @State private var testRunning = false
    @State private var roundStartedAt: TimeInterval = 0
    @State private var roundElapsed: TimeInterval = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum CanvasSheet: String, Identifiable {
        case settings, details, recommendations
        var id: String { rawValue }
    }

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
                    Button { canvasSheet = .settings } label: {
                        Image(systemName: "gearshape")
                            .accessibilityLabel(Text("Settings"))
                    }
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .tint(Color.primary)
        .background {
            NarrowFormSheet(item: $canvasSheet) { sheet in
                NavigationStack {
                    Group {
                        switch sheet {
                        case .settings: settingsView
                        case .details: connectionDetailsView
                        case .recommendations: calibrationResults
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") { canvasSheet = nil }
                        }
                    }
                }
                .tint(Color.primary)
            }
        }
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
            if phase == .active { connectionManager.resumeUSBDiscovery() }
            if phase == .background { control?.interruptCalibration() }
            if phase != .active { qualityTracker = LinkStabilityTracker(); linkSample = nil }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            guard scenePhase == .active else { return }
            if connectionEstablished && control != nil && !sendingReport && completedTestStatus == nil && !isConnecting {
                let sample = receiver.linkTimingSample()
                linkSample = sample
                qualityTracker.observe(sample)
            } else { qualityTracker = LinkStabilityTracker(); linkSample = nil }
            if calibrationProgress != nil { calibrationNow = DispatchTime.now().uptimeNanoseconds }
            if musicRound != nil { roundElapsed = max(0, ProcessInfo.processInfo.systemUptime - roundStartedAt) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            control?.interruptCalibration(forOutputChange: true)
        }
        .onChange(of: host) { newHost in
            if authMode == .remembered && newHost != rememberedHost {
                authMode = .pair
            }
        }
        .onDisappear {
            disconnect()
        }
    }

    private var presentationStage: ConnectionPresentationStage {
        .resolve(completed: completedTestStatus != nil, reporting: sendingReport,
            recovering: retainingConnection && isConnecting, connecting: isConnecting,
            playing: audioOutput != nil,
            testing: testRunning)
    }

    private var showsConnections: Bool { presentationStage == .idle }
    private var symbolConnected: Bool {
        [.playing, .testing, .reporting, .recovering].contains(presentationStage)
    }
    private var canvasTitle: String {
        switch presentationStage {
        case .idle:
            if connectionError != nil { return Self.localize("Connection failed") }
            return status == Self.localize("Disconnected") ? Self.localize("Connect to a PC") : status
        case .connecting: return Self.localize("Connecting")
        case .recovering: return Self.localize(calibrationRequestID == nil ? "Restoring connection" : "Starting calibration…")
        case .playing: return Self.localize("Playing")
        case .testing:
            if calibrationRequestID != nil { return Self.localize("Starting calibration…") }
            if let round = musicRound {
                if round.isCompressionTest {
                    return String(format: Self.localize("Compression test · %d / %d"),
                                  round.index, round.roundCount)
                }
                return String(format: Self.localize("Music test · %d / 8"), round.index)
            }
            return Self.localize(control?.isEnvironmentCalibration == true ? "Automatic test and recommendations" : "Network test running")
        case .reporting: return Self.localize("Sending report")
        case .completed:
            if let result = adaptiveRunResult { return Self.localize(result.canApply ? "Recommendations ready" : "Test ended") }
            if let result = calibrationRunResult {
                return Self.localize(result.usable ? "Recommendations ready" : "Test ended")
            }
            return Self.localize(testCompletedNormally ? "Test complete" : "Test ended")
        }
    }
    private var canvasSubtitle: String {
        switch presentationStage {
        case .idle: return connectionError ?? Self.localize("Bring Windows audio to this iPad.")
        case .connecting: return Self.localize("Searching network and USB…")
        case .reporting: return Self.localize("Waiting for the PC to confirm receipt.")
        case .completed: return completedTestStatus ?? ""
        default: return calibrationStartStatus ?? currentComputerName
        }
    }

    private var homeView: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 28) {
                    // Keep the same symbol and heading in the hierarchy across every stage.
                    VStack(spacing: 16) {
                        ConnectionStatusSymbol(connected: symbolConnected, path: activePath,
                            quality: qualityTracker.quality, recovering: presentationStage == .recovering, connecting: isConnecting)
                            .frame(width: showsConnections ? 160 : 190, height: showsConnections ? 160 : 190)
                            .padding(.top, showsConnections ? 4 : 22)
                        Text(canvasTitle)
                            .font(.largeTitle.weight(.bold))
                            .multilineTextAlignment(.center)
                            .contentTransition(.opacity)
                            .accessibilityAddTraits(.isHeader)
                        Text(canvasSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                        canvasLinkStatus
                        if presentationStage == .connecting || presentationStage == .recovering || presentationStage == .reporting {
                            ProgressView().padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 10)

                    if showsConnections {
                        availableConnections
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else if presentationStage == .completed {
                        if calibrationRunResult != nil || adaptiveRunResult != nil {
                            Button { canvasSheet = .recommendations } label: {
                                Text("Review recommendations").font(.headline)
                                    .padding(.horizontal, 24).padding(.vertical, 14)
                                    .foregroundStyle(Color(uiColor: .systemBackground))
                                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                            if sendingReport {
                                Text("Recommendations are saved on this iPad. A diagnostic copy is being sent to the PC.")
                                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                            Button("Back to connections") { disconnect() }
                        } else {
                            Button { disconnect() } label: {
                                Text("Back to connections").font(.headline)
                                    .padding(.horizontal, 24).padding(.vertical, 14)
                                    .foregroundStyle(Color(uiColor: .systemBackground))
                                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                        }
                    } else {
                        playbackSummary
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, geometry.size.width < 500 ? 20 : 40)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .top)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: presentationStage)
            }
            .background(Color(uiColor: .systemGroupedBackground))
        }
    }

    @ViewBuilder private var canvasLinkStatus: some View {
        if showsConnections {
            if connectionManager.hasUSB {
                Label("USB available", systemImage: "cable.connector")
                    .font(.subheadline).foregroundStyle(.teal)
            }
        } else if presentationStage == .recovering {
            Label("Searching network and USB…", systemImage: "arrow.triangle.2.circlepath")
                .font(.subheadline).foregroundStyle(.secondary)
        } else if presentationStage == .completed {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.teal).accessibilityHidden(true)
        } else if symbolConnected {
            HStack(spacing: 8) {
                Label(Self.localize(activePath == .usb ? "USB" : "Local network"),
                      systemImage: activePath == .usb ? "cable.connector" : "wifi")
                if audioOutput != nil && presentationStage != .reporting {
                    Text("·")
                    Text(qualityTracker.quality.title)
                }
            }
            .font(.subheadline)
            .foregroundStyle(qualityTracker.quality.color(for: activePath))
        }
    }

    private var availableConnections: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Available connections").font(.subheadline).foregroundStyle(.secondary)
            ForEach(connectionManager.computers) { computer in
                Button { selectConnection(computer.preferredEndpoint) } label: {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 14) {
                            connectionRouteIcon(computer)
                            Text(computer.title).font(.headline).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text(connectionRoutes(computer)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 14) {
                            connectionRouteIcon(computer)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(computer.title).font(.headline).lineLimit(2).truncationMode(.middle)
                                Text(connectionRoutes(computer)).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(minHeight: 34).padding(20).background(canvasSurface).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if !lastHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !lastHostIsDiscovered {
                Button {
                    selectedEndpoint = nil; host = lastHost
                    if hasRememberedCredential && lastHost == rememberedHost {
                        authMode = .remembered; connect()
                    } else { authMode = .oneTime; showingConnectionSetup = true }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "wifi").font(.title2).frame(width: 36)
                        Text("Last connection").font(.headline)
                        Spacer(minLength: 12)
                        Text(lastHost).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }.frame(minHeight: 34).padding(20).background(canvasSurface).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Button {
                selectedEndpoint = nil; showingConnectionSetup = true
            } label: {
                Label("Enter PC address", systemImage: "plus")
                    .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).frame(minHeight: 48)
            }.buttonStyle(.plain)
            Text("Use the address shown on your Windows PC. Pairing requires its six-digit code.")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center).multilineTextAlignment(.center)
        }
    }

    private func connectionRouteIcon(_ computer: ComputerConnectionTarget) -> some View {
        HStack(spacing: 2) {
            if computer.hasUSB { Image(systemName: "cable.connector") }
            if computer.hasNetwork {
                Image(systemName: "wifi")
            }
        }
        .font(computer.hasUSB && computer.hasNetwork ? .body : .title2)
        .frame(width: 36).accessibilityHidden(true)
    }

    private func connectionRoutes(_ computer: ComputerConnectionTarget) -> String {
        let network = computer.networkAddress ?? Self.localize("Local network")
        if computer.hasUSB { return computer.hasNetwork ? "USB | " + network : "USB" }
        return network
    }

    private var lastHostIsDiscovered: Bool {
        connectionManager.computers.contains { computer in
            computer.networkAddress == lastHost ||
                (hasRememberedCredential && lastHost == rememberedHost && computer.title == connectionManager.rememberedComputerName)
        }
    }

    private func selectConnection(_ endpoint: ConnectionEndpoint) {
        selectedEndpoint = endpoint
        if hasRememberedCredential { authMode = .remembered; connect(selected: endpoint) }
        else {
            if endpoint.path == .network { host = endpoint.host }
            authMode = .pair; showingConnectionSetup = true
        }
    }

    private var canvasSurface: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var playbackSummary: some View {
        VStack(alignment: .leading, spacing: 18) {
            if presentationStage == .testing {
                if let round = musicRound {
                    VStack(alignment: .leading, spacing: 10) {
                        if round.isCompressionTest {
                            Text(Self.label(for: round)).font(.headline)
                        } else {
                            Text(Self.localize(round.reliable ? "Reliable stream" : "Datagram") +
                                 " · " + Self.localize(round.adaptive ? "Adaptive" : "Fixed"))
                                .font(.headline)
                        }
                        ProgressView(value: min(Double(round.seconds), roundElapsed), total: Double(round.seconds))
                            .tint(.teal)
                        Text(round.isCompressionTest
                            ? String(format: Self.localize("Round remaining %.0f s"),
                                     max(0, Double(round.seconds) - roundElapsed))
                            : String(format: Self.localize("Round elapsed %.0f / %d s"),
                                     min(Double(round.seconds), roundElapsed), round.seconds))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else if let progress = calibrationProgress {
                    calibrationProgressView(progress)
                } else {
                    Text(status).font(.subheadline).foregroundStyle(.secondary)
                }
                Divider()
            }
            if presentationStage == .reporting {
                Text("The report is being prepared and transferred. Keep HearPort open.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if calibrationProgress == nil {
                HStack(alignment: .firstTextBaseline) {
                    Text("Playback budget").foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text("\(activeTargetLatencyMs) / \(activeMaximumLatencyMs) ms").monospacedDigit()
                }.font(.subheadline)
                Text("Target / maximum · configured, not measured latency")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { playbackActions }
                VStack(alignment: .leading, spacing: 12) { playbackActions }
            }
        }
        .padding(24).background(canvasSurface)
    }

    @ViewBuilder private var playbackActions: some View {
        Button { canvasSheet = .settings } label: {
            Label("Playback settings", systemImage: "slider.horizontal.3").frame(minHeight: 44)
        }
        .disabled(presentationStage == .reporting)
        Spacer(minLength: 0)
        Button { canvasSheet = .details } label: {
            Label("Connection details", systemImage: "info.circle").frame(minHeight: 44)
        }
        Button("Disconnect", role: .destructive) { disconnect() }
            .frame(minHeight: 44)

    }

    private var connectionDetailsView: some View {
        Form {
            Section("Current connection") {
                LabeledContent("Windows PC", value: currentComputerName)
                LabeledContent("Path", value: Self.localize(activePath == .usb ? "USB" : "Local network"))
                LabeledContent("Transport", value: (musicRound?.reliable ?? (activeAudioMode == .reliable)) ? "Reliable stream" : "Datagram")
                if musicRound == nil { LabeledContent("Audio format", value: activeAudioFormat.label) }
                if connectionEstablished && !isConnecting { Label("Identity verified", systemImage: "checkmark.shield") }
            }
            Section {
                LabeledContent("Link stability") { Text(qualityTracker.quality.title).foregroundStyle(qualityTracker.quality.color(for: activePath)) }
                LabeledContent("Round-trip time", value: linkSample?.roundTripMilliseconds.map { String(format: "%.1f ms", $0) } ?? "—")
                LabeledContent("Delay variation", value: qualityTracker.variationMilliseconds.map { String(format: "%.1f ms", $0) } ?? "—")
                LabeledContent("Probe samples", value: "\(qualityTracker.sampleCount)")
            } header: { Text("Recent link timing") } footer: {
                Text("Stability uses the absolute RTT variation of recent independent probes, including during silence. Variation is the P90–P10 difference over 12 seconds. Missing probe responses also lower stability. A steady high RTT can be stable; RTT is not end-to-end playback latency.")
            }
            Section("Active playback budget") {
                LabeledContent("Normal target", value: "\(activeTargetLatencyMs) ms")
                LabeledContent("Maximum total delay", value: "\(activeMaximumLatencyMs) ms")
            }
        }
        .navigationTitle("Connection details").navigationBarTitleDisplayMode(.inline)
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

    private var playbackSettingsSection: some View {
            Section {
                audioFormatLink("Network audio", codec: $networkCodec, bitrate: $networkBitrate, frames: $networkFrames, transport: $audioTransportModeRaw)
                audioFormatLink("USB audio", codec: $usbCodec, bitrate: $usbBitrate, frames: $usbFrames, transport: $usbTransportModeRaw)
                MillisecondsControl("Normal target", value: $targetLatencyMs, range: 10...max(10, maximumLatencyMs))
                MillisecondsControl("Maximum total delay", value: $maximumLatencyMs, range: max(20, targetLatencyMs)...2_000)
            } header: {
                Text("Playback")
            } footer: {
                Text("The target and maximum include transport, processing and output. Changes take effect on the next connection. A higher maximum can tolerate longer interruptions.")
            }
    }

    private func audioFormatLink(_ title: LocalizedStringKey, codec: Binding<String>,
                                 bitrate: Binding<Int>, frames: Binding<Int>, transport: Binding<String>) -> some View {
        NavigationLink {
            Form {
                Section {
                    Picker("Audio transport mode", selection: transport) {
                        Text("Datagram").tag(AudioTransportMode.datagram.rawValue)
                        Text("Reliable stream").tag(AudioTransportMode.reliable.rawValue)
                    }
                    Picker("Audio encoding", selection: codec) {
                        Text("PCM").tag("pcm")
                        Text("Opus").tag("opus")
                    }
                    if codec.wrappedValue == "opus" {
                        Picker("Opus bitrate", selection: bitrate) {
                            Text("192 kb/s").tag(192_000)
                            Text("256 kb/s").tag(256_000)
                        }
                        Picker("Audio per packet", selection: frames) {
                            Text("2.5 ms").tag(120)
                            Text("5 ms").tag(240)
                            Text("10 ms").tag(480)
                        }
                    }
                } footer: {
                    Text("Longer packets reduce packet frequency and need more collection time. All processing uses the selected total delay budget. Changes take effect on the next connection.")
                }
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        } label: {
            LabeledContent(title, value: codec.wrappedValue == "opus" ?
                "Opus · \(bitrate.wrappedValue / 1000) kb/s · \(Double(frames.wrappedValue) / 48) ms" : "PCM")
        }
    }

    private var calibrationLink: some View {
        NavigationLink("Automatic test and recommendations") { calibrationResults }
    }

    @ViewBuilder private var calibrationResults: some View {
        if let calibrationRunResult {
            CalibrationResultsView(result: calibrationRunResult, apply: { profile in
                _ = calibrationRunResult.apply(profile: profile)
            })
        } else {
            AdaptiveCalibrationView(result: adaptiveRunResult ?? adaptiveResult,
                canStart: canStartCalibration, starting: calibrationRequestID != nil,
                status: calibrationStartStatus, start: startCalibration, apply: {
                    guard (adaptiveRunResult ?? adaptiveResult)?.apply() == true else { return false }
                    audioTransportModeRaw = UserDefaults.standard.string(forKey: "hearport.audioTransportMode") ?? AudioTransportMode.datagram.rawValue
                    targetLatencyMs = UserDefaults.standard.integer(forKey: "hearport.targetLatencyMs")
                    maximumLatencyMs = UserDefaults.standard.integer(forKey: "hearport.maximumLatencyMs")
                    networkCodec = UserDefaults.standard.string(forKey: "hearport.networkAudio.codec") ?? "opus"
                    networkBitrate = UserDefaults.standard.object(forKey: "hearport.networkAudio.bitrate") as? Int ?? 256_000
                    networkFrames = UserDefaults.standard.object(forKey: "hearport.networkAudio.frames") as? Int ?? 240
                    return true
                })
        }
    }

    @ViewBuilder private func calibrationProgressView(_ progress: CalibrationProgressSnapshot) -> some View {
        if progress.adaptive {
            Text(progress.validating ? LocalizedStringKey("Verifying selected settings") : LocalizedStringKey("Searching suitable settings")).font(.headline)
            if progress.validating {
                Text("Verification \(progress.validationIndex) / 2").font(.subheadline).monospacedDigit()
            } else { Text("Observation step \(progress.index)").font(.subheadline).monospacedDigit() }
            if let p = progress.parameters {
                Text(p.format.label)
                Text("\(p.reliable ? "Reliable" : "Datagram") · \(p.budget.target)/\(p.budget.maximum) ms")
            }
            let remaining = progress.remainingRoundSeconds(at: calibrationNow)
            ProgressView(value: Double(progress.seconds - remaining), total: Double(progress.seconds)).tint(.teal)
            if progress.roundStartedAt == 0 { Text("Waiting for test traffic…") }
            else if remaining > 0 { Text("This round: \(remaining) seconds remaining").monospacedDigit() }
            else { Text("Evaluating this observation and choosing the next step…") }
            if let ratio = progress.liveGapRatio {
                Text("Current window: gaps \(ratio * 100, specifier: "%.3f")% · longest \(progress.liveLongestGap, specifier: "%.1f") ms")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text(LocalizedStringKey(progress.action)).font(.footnote).foregroundStyle(.secondary)
            let estimate = progress.adaptiveRemainingSeconds(at: calibrationNow)
            Text("Estimated remaining: \(estimate.lowerBound)–\(estimate.upperBound) seconds; updated after each observation.")
                .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            DisclosureGroup("Test details") {
                Text("Received \(progress.receivedPackets) packets").monospacedDigit()
                if let ratio = progress.lastGapRatio, let longest = progress.lastLongestGap {
                    Text("Previous window: gaps \(ratio * 100, specifier: "%.3f")% · longest \(longest, specifier: "%.1f") ms")
                }
                Text("Estimated remaining: \(progress.minimumWindows)–\(progress.maximumWindows) observation windows, including this one. Final verification uses longer windows.")
            }.font(.caption).foregroundStyle(.secondary)
        } else if progress.stage == "analyzing" {
            Text("Analyzing recommendations").font(.headline)
            if progress.total > 0 {
                ProgressView(value: Double(progress.completed), total: Double(progress.total)).tint(.teal)
                Text("Compared \(progress.completed) / \(progress.total) candidates")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else { ProgressView() }
            Text("Validation rounds will be selected after analysis.").font(.footnote).foregroundStyle(.secondary)
        } else if progress.stage == "interrupted" {
            Text("Calibration interrupted")
        } else if progress.index > 0 {
            let remaining = progress.remainingRoundSeconds(at: calibrationNow)
            Text(progress.stage == "validation" ? "Validating recommendations" : "Sampling network").font(.headline)
            Text("Round \(progress.phaseIndex) / \(progress.phaseCount)").font(.subheadline)
            ProgressView(value: Double(progress.seconds - remaining), total: Double(progress.seconds)).tint(.teal)
            if remaining > 0 {
                Text("This round: \(remaining) seconds remaining").monospacedDigit()
            } else { Text("Finishing this round and draining queued data…") }
            let range = progress.remainingTrafficSeconds(at: calibrationNow)
            if range.upperBound > 0 {
                if range.lowerBound == range.upperBound {
                    Text("Estimated traffic remaining: \(range.upperBound) seconds")
                        .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("Estimated traffic remaining: \(range.lowerBound)–\(range.upperBound) seconds")
                        .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text("Analysis and report transfer take additional time. Identical recommendations share validation rounds.")
                .font(.caption).foregroundStyle(.secondary)
        } else { Text("Starting calibration…") }
    }

    private var canStartCalibration: Bool {
        hasRememberedCredential && authMode == .remembered && connectionEstablished &&
            !isConnecting && audioOutput != nil && !testRunning && !sendingReport &&
            completedTestStatus == nil && (activePath == .network || connectionManager.computers.contains {
                $0.identity == currentComputerIdentity && $0.hasNetwork
            })
    }

    private func startCalibration(goal: Int, seconds: Int, maximum: Int) {
        guard canStartCalibration, let control else { return }
        let id = UUID()
        calibrationRequestID = id; calibrationStartStatus = nil
        adaptiveRunResult = nil; calibrationRunResult = nil; calibrationProgress = nil
        testRunning = true
        control.requestEnvironmentCalibration(seconds: seconds, maximum: maximum, goal: goal) { accepted in
            DispatchQueue.main.async {
                guard calibrationRequestID == id else { return }
                if accepted { canvasSheet = nil }
                else {
                    calibrationRequestID = nil; testRunning = false
                    calibrationStartStatus = Self.localize("Could not start calibration. Reconnect and try again.")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            guard calibrationRequestID == id else { return }
            calibrationRequestID = nil; testRunning = false
            calibrationStartStatus = Self.localize("The PC did not start calibration. Reconnect and try again.")
            status = calibrationStartStatus ?? Self.localize("Connection failed")
        }
    }

    private var settingsView: some View {
        Form {
            playbackSettingsSection
            Section {
                Toggle("Connect on launch", isOn: $autoConnect)
                    .tint(.green)
            } header: {
                Text("Connection")
            } footer: {
                Text("Uses the last connected PC when its pairing is saved.")
            }
            Section("Support") {
                calibrationLink
                NavigationLink {
                    diagnosticsView
                } label: {
                    Text("Diagnostics")
                }
            }
            Section {
                NavigationLink("About HearPort") {
                    Form {
                        Section("HearPort") {
                            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                            LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")
                            LabeledContent("Author", value: "lsy223622")
                            Link(destination: URL(string: "https://github.com/lsy223622/HearPort")!) {
                                LabeledContent("GitHub repository", value: "lsy223622/HearPort")
                            }
                        }
                    }.navigationTitle("About HearPort").navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .frame(maxWidth: 600)
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
                    Label(exportingDiagnostics ? LocalizedStringKey("Exporting diagnostics…") : LocalizedStringKey("Export diagnostics"), systemImage: "square.and.arrow.down")
                }.disabled(exportingDiagnostics)
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
                .confirmationDialog("Clear retained diagnostics?", isPresented: $showingClearConfirmation, titleVisibility: .visible) {
                    Button("Clear", role: .destructive) { clearDiagnostics() }
                    Button("Cancel", role: .cancel) {}
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
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear { refreshDiagnostics() }
    }

    private func connect(selected: ConnectionEndpoint? = nil) {
        guard authMode == .remembered || PairingSecurity.validatePIN(pin) else {
            status = Self.localize("Enter the 6-digit PIN shown on Windows"); return
        }
        completedTestStatus = nil; connectionError = nil
        adaptiveRunResult = nil; calibrationRunResult = nil; calibrationProgress = nil
        sendingReport = false; retainingConnection = false
        calibrationRequestID = nil; calibrationStartStatus = nil
        musicRound = nil; testRunning = false; currentComputerName = ""
        qualityTracker = LinkStabilityTracker(); linkSample = nil
        isConnecting = true; status = Self.localize("Searching network and USB…")
        connectionManager.setMaximumLatency(maximumLatencyMs)
        connectionManager.connect(manualHost: host.trimmingCharacters(in: .whitespacesAndNewlines),
            selected: selected, useRememberedIdentity: authMode == .remembered)
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
        let audioMode = AudioTransportMode.load(usb: route.path == .usb)
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
        session.requestedFormat = AudioStreamFormat.load(usb: route.path == .usb)
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
                activePath = route.path
                currentComputerName = "HearPort-" + identity.prefix(6).map { String(format: "%02x", $0) }.joined()
                currentComputerIdentity = identity.map { String(format: "%02x", $0) }.joined()
                if features & ControlFeature.environmentCalibration != 0 {
                    calibrationRequestID = nil; calibrationStartStatus = nil
                }
                qualityTracker = LinkStabilityTracker(); linkSample = nil; musicRound = nil; testRunning = false
                calibrationProgress = nil; calibrationRunResult = nil; adaptiveRunResult = nil
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
                    if calibrationRequestID != nil {
                        control?.cancel(); control = nil
                        try? audioOutput?.stop(); audioOutput = nil
                        testRunning = false
                        connectionManager.ended(id); showConnectionSearch()
                        return
                    }
                    let completed = completedTestStatus
                    control?.cancel(); control = nil
                    connectionManager.stop(); connectionID = UUID()
                    isConnecting = false; connectionError = nil
                    sendingReport = false; testRunning = false
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
                calibrationProgress = progress
                calibrationNow = DispatchTime.now().uptimeNanoseconds
                status = Self.localize(progress.stage == "analyzing" ? "Analyzing recommendations" : progress.stage == "validation" ?
                    "Validating recommendations" : progress.stage == "interrupted" ? "Calibration interrupted" : "Sampling network")
            }
        }
        session.onAdaptiveCalibrationResult = { result in
            DispatchQueue.main.async {
                guard connectionID == activeConnectionID else { return }
                adaptiveRunResult = result
                if result.canApply { adaptiveResult = result }
                connectionManager.completed()
                completedTestStatus = Self.localize(result.canApply ? "Recommendations are ready to apply." :
                    "Validation did not confirm the goal; test again when conditions settle.")
                testCompletedNormally = result.complete
                testRunning = false; isConnecting = false; sendingReport = false
                canvasSheet = .recommendations
            }
        }
        session.onCalibrationResult = { result in
            DispatchQueue.main.async {
                guard connectionID == activeConnectionID else { return }
                let firstResult = calibrationRunResult == nil
                calibrationRunResult = result
                connectionManager.completed()
                if result.save() { calibrationResult = result }
                completedTestStatus = Self.localize(result.usable ? "Choose a profile to apply its settings." :
                    "This test could not produce validated recommendations. Review the results before testing again.")
                testCompletedNormally = result.complete
                testRunning = false; isConnecting = false
                if firstResult { canvasSheet = .recommendations }
            }
        }
        session.onTransportState = { newState in
            DispatchQueue.main.async {
                if newState == .failed || newState == .closed { connectionManager.ended(id) }
                guard connectionID == activeConnectionID else { return }
                if newState == .failed || newState == .closed {
                    isConnecting = false
                    sendingReport = false; testRunning = false
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
                guard completedTestStatus == nil else { sendingReport = false; return }
                let reportInterrupted = sendingReport
                sendingReport = false; testRunning = false
                try? audioOutput?.stop(); audioOutput = nil
                control?.cancel(); control = nil
                if connectionManager.isWaiting { showConnectionSearch(); return }
                isConnecting = false
                connectionError = Self.localize(reportInterrupted ? "Report transfer interrupted. Receipt not confirmed." : message)
                status = connectionError ?? Self.localize("Connection failed")
                refreshDiagnostics()
            }
        }
        session.onAudioFormat = { format in
            DispatchQueue.main.async {
                guard connectionID == id else { return }
                activeAudioFormat = format
                diagnostics.log(.info, category: .audio, message: "ui_audio_format_negotiated",
                    fields: ["physical_path": route.path.rawValue, "format": format.label])
            }
        }
        session.onReady = { [weak session] in
            DispatchQueue.main.async {
                guard connectionID == activeConnectionID, completedTestStatus == nil else { return }
                // Ready also resumes playback after the PC acknowledges an older retained report.
                sendingReport = false
                isConnecting = false
                connectionEstablished = true
                activeAudioFormat = session?.activeFormat ?? .pcm
                retainingConnection = true
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
                    testRunning = true
                    status = Self.localize("Network test running")
                    refreshDiagnostics()
                    return
                }
                do {
                    let output = PlatformAudioOutputController(receiver: activeReceiver)
                    try output.start()
                    audioOutput = output
                    testRunning = session?.isMusicTest == true
                    musicRound = session?.musicTestRound
                    roundStartedAt = ProcessInfo.processInfo.systemUptime; roundElapsed = 0
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
                guard connectionID == activeConnectionID, completedTestStatus == nil, !sendingReport else { return }
                musicRound = round
                roundStartedAt = ProcessInfo.processInfo.systemUptime; roundElapsed = 0
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
                let message = calibrationRunResult != nil ? (completedTestStatus ?? "") : Self.localize(reason == 1
                    ? "Test complete. Report saved on the PC."
                    : "Test ended. Report saved on the PC.")
                connectionManager.completed()
                completedTestStatus = message
                testRunning = false
                testCompletedNormally = reason == 1
                sendingReport = false
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
        adaptiveRunResult = nil; calibrationRunResult = nil; calibrationProgress = nil
        sendingReport = false; retainingConnection = false; musicRound = nil; testRunning = false
        qualityTracker = LinkStabilityTracker(); linkSample = nil
        currentComputerName = ""
        currentComputerIdentity = ""; calibrationRequestID = nil; calibrationStartStatus = nil
        control?.cancel()
        control = nil
        try? audioOutput?.stop()
        audioOutput = nil
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
        guard !exportingDiagnostics else { return }
        exportingDiagnostics = true
        diagnosticsStatus = Self.localize("Exporting diagnostics…")
        diagnostics.log(
            .info,
            category: .app,
            message: "ui_export_requested",
            fields: ["event": "ui_export_requested"]
        )
        let log = diagnostics
        connectionManager.recordUSBStatus {
            DispatchQueue.global(qos: .utility).async {
                let result = Result { try log.export() }
                DispatchQueue.main.async {
                    exportingDiagnostics = false
                    switch result {
                    case let .success(url):
                        exportedDiagnosticsURL = url
                        diagnosticsStatus = Self.localize("Diagnostics export is ready to share.")
                    case .failure:
                        exportedDiagnosticsURL = nil
                        diagnosticsStatus = Self.localize("Unable to export diagnostics.")
                    }
                    refreshDiagnostics()
                }
            }
        }
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
        if round.isCompressionTest {
            let codec: String
            switch round.profile {
            case 0: codec = localize("Float PCM")
            case 1: codec = localize("PCM16")
            default: codec = String(format: localize("Opus · %d kbps"), round.bitrateKbps)
            }
            return String(format: localize("Compression %d/%d · repeat %d/2 · %@ · %@ · %@"),
                round.index, round.roundCount, round.repeatIndex, codec,
                localize(round.reliable ? "Reliable stream" : "Datagram"),
                localize(round.adaptive ? "Adaptive" : "Fixed"))
        }
        return String(format: localize("Music test %d/8 · %@ · %@"), round.index,
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
