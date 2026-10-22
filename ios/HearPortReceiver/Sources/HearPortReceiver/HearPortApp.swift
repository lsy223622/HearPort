#if canImport(SwiftUI) && canImport(Network) && canImport(AVFAudio) && os(iOS)
import AVFAudio
import Network
import SwiftUI

@MainActor public struct HearPortApp: View {
    @ObservedObject private var runtime = ReceiverRuntime.shared
    @ObservedObject private var coordinator = ReceiverRuntime.shared.connectionManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init() {}
    public var body: some View {
        runtime.canvas
            .onAppear { runtime.updateScene(scenePhase, reduceMotion: reduceMotion) }
            .onChange(of: scenePhase) { runtime.updateScene($0, reduceMotion: reduceMotion) }
            .onChange(of: reduceMotion) { runtime.updateScene(scenePhase, reduceMotion: $0) }
    }
}

@MainActor public final class ReceiverRuntime: ObservableObject {
    public static let shared = ReceiverRuntime()
    private let diagnostics = HearPortDiagnostics.shared
    @Published private var lastHost = "" { didSet { UserDefaults.standard.set(lastHost, forKey: ConnectionPreferences.lastHostKey) } }
    @Published private var rememberedHost = "" { didSet { UserDefaults.standard.set(rememberedHost, forKey: "hearport.rememberedHost") } }
    @Published private var selectedEndpoint: ConnectionEndpoint?
    @Published private var host = ""
    @Published private var connectionID = UUID()
    @Published private var isConnecting = false
    @Published private var activeAudioMode: AudioTransportMode = .datagram
    @Published private var activeBufferTargetPackets = JitterBufferConfiguration.defaultTargetPackets
    @Published private var pin = ""
    @Published private var authMode: AuthMode = .pair
    @Published private var hasRememberedCredential = false
    @Published private var didLoadRememberedCredential = false
    @Published private var status = "Disconnected"
    @Published private var connectionError: String?
    @Published private var connectionEstablished = false
    @Published private var completedTestStatus: String?
    @Published private var testCompletedNormally = true
    @Published private var receiver = HearPortReceiver()
    let connectionManager = ReceiverConnectionCoordinator()
    @Published private var pendingControls: [UUID: ReceiverControlSession] = [:]
    @Published private var activePath: ConnectionPath = .network
    @Published private var activeNetworkEndpoint = ""
    @Published private var canvasHasAppeared = false
    @Published private var control: ReceiverControlSession?
    @Published private var audioOutput: PlatformAudioOutputController?
    @Published private var audioOutputState: AudioOutputState?
    @Published private var pairingNeedsAttention = false
    @Published private var detailedLogging = false { didSet { UserDefaults.standard.set(detailedLogging, forKey: "hearport.detailedLogging") } }
    @Published private var autoConnect = false { didSet { UserDefaults.standard.set(autoConnect, forKey: "hearport.autoConnect") } }
    @Published private var usbTransportModeRaw = AudioTransportMode.reliable.rawValue { didSet { UserDefaults.standard.set(usbTransportModeRaw, forKey: "hearport.usbAudio.transport") } }
    @Published private var audioTransportModeRaw = AudioTransportMode.datagram.rawValue { didSet { UserDefaults.standard.set(audioTransportModeRaw, forKey: "hearport.audioTransportMode") } }
    @Published private var jitterBufferTargetPackets = 8 { didSet { UserDefaults.standard.set(jitterBufferTargetPackets, forKey: "hearport.jitterStartupPackets") } }
    @Published private var networkTargetLatencyMs = 50 { didSet { UserDefaults.standard.set(networkTargetLatencyMs, forKey: PlaybackLatencyPreferences.networkTargetKey) } }
    @Published private var networkMaximumLatencyMs = 100 { didSet { UserDefaults.standard.set(networkMaximumLatencyMs, forKey: PlaybackLatencyPreferences.networkMaximumKey) } }
    @Published private var usbTargetLatencyMs = 50 { didSet { UserDefaults.standard.set(usbTargetLatencyMs, forKey: PlaybackLatencyPreferences.usbTargetKey) } }
    @Published private var usbMaximumLatencyMs = 100 { didSet { UserDefaults.standard.set(usbMaximumLatencyMs, forKey: PlaybackLatencyPreferences.usbMaximumKey) } }
    @Published private var networkCodec = "opus" { didSet { UserDefaults.standard.set(networkCodec, forKey: "hearport.networkAudio.codec") } }
    @Published private var networkBitrate = 256_000 { didSet { UserDefaults.standard.set(networkBitrate, forKey: "hearport.networkAudio.bitrate") } }
    @Published private var networkFrames = 240 { didSet { UserDefaults.standard.set(networkFrames, forKey: "hearport.networkAudio.frames") } }
    @Published private var usbCodec = "pcm" { didSet { UserDefaults.standard.set(usbCodec, forKey: "hearport.usbAudio.codec") } }
    @Published private var usbBitrate = 256_000 { didSet { UserDefaults.standard.set(usbBitrate, forKey: "hearport.usbAudio.bitrate") } }
    @Published private var usbFrames = 240 { didSet { UserDefaults.standard.set(usbFrames, forKey: "hearport.usbAudio.frames") } }
    @Published private var activeAudioFormat: AudioStreamFormat = .pcm
    @Published private var activeTargetLatencyMs = 50
    @Published private var activeMaximumLatencyMs = 100
    @Published private var diagnosticsSnapshot = HearPortDiagnostics.shared.snapshot()
    @Published private var exportedDiagnosticsURL: URL?
    @Published private var exportingDiagnostics = false
    @Published private var diagnosticsStatus: String?
    @Published private var showingClearConfirmation = false
    @Published private var calibrationResult: CalibrationResult? = CalibrationResult.load()
    @Published private var calibrationRunResult: CalibrationResult?
    @Published private var adaptiveResult = AdaptiveCalibrationResult.load()
    @Published private var adaptiveRunResult: AdaptiveCalibrationResult?
    @Published private var calibrationProgress: CalibrationProgressSnapshot?
    @Published private var calibrationNow: UInt64 = 0
    @Published private var sendingReport = false
    @Published private var canvasSheet: CanvasSheet?
    @Published private var calibrationTarget: ComputerConnectionTarget?
    @Published private var pendingCalibration: (goal: Int, seconds: Int, maximum: Int)?
    @Published private var completedAdaptiveConnection: UUID?
    @Published private var unpairTarget: ComputerConnectionTarget?
    @Published private var keepScreenAwake = false { didSet { UserDefaults.standard.set(keepScreenAwake, forKey: "hearport.keepScreenAwake") } }
    @Published private var currentComputerName = ""
    @Published private var currentComputerIdentity = ""
    @Published private var calibrationRequestID: UUID?
    @Published private var calibrationStartStatus: String?
    @Published private var retainingConnection = false
    @Published private var qualityTracker = LinkStabilityTracker()
    @Published private var linkSample: LinkTimingSample?
    @Published private var musicRound: MusicTestRound?
    @Published private var testRunning = false
    @Published private var roundStartedAt: TimeInterval = 0
    @Published private var roundElapsed: TimeInterval = 0
    private var scenePhase: ScenePhase = .active
    private var reduceMotion = false

    private enum CanvasSheet: String, Identifiable {
        case settings, details, recommendations, pairing
        var id: String { rawValue }
    }

    private init() {
        PlaybackLatencyPreferences.migrate()
        lastHost = UserDefaults.standard.object(forKey: ConnectionPreferences.lastHostKey) as? String ?? ""
        rememberedHost = UserDefaults.standard.object(forKey: "hearport.rememberedHost") as? String ?? ""
        detailedLogging = UserDefaults.standard.object(forKey: "hearport.detailedLogging") as? Bool ?? false
        autoConnect = UserDefaults.standard.object(forKey: "hearport.autoConnect") as? Bool ?? false
        usbTransportModeRaw = UserDefaults.standard.object(forKey: "hearport.usbAudio.transport") as? String ?? AudioTransportMode.reliable.rawValue
        audioTransportModeRaw = UserDefaults.standard.object(forKey: "hearport.audioTransportMode") as? String ?? AudioTransportMode.datagram.rawValue
        jitterBufferTargetPackets = UserDefaults.standard.object(forKey: "hearport.jitterStartupPackets") as? Int ?? 8
        networkTargetLatencyMs = UserDefaults.standard.object(forKey: PlaybackLatencyPreferences.networkTargetKey) as? Int ?? 50
        networkMaximumLatencyMs = UserDefaults.standard.object(forKey: PlaybackLatencyPreferences.networkMaximumKey) as? Int ?? 100
        usbTargetLatencyMs = UserDefaults.standard.object(forKey: PlaybackLatencyPreferences.usbTargetKey) as? Int ?? 50
        usbMaximumLatencyMs = UserDefaults.standard.object(forKey: PlaybackLatencyPreferences.usbMaximumKey) as? Int ?? 100
        networkCodec = UserDefaults.standard.object(forKey: "hearport.networkAudio.codec") as? String ?? "opus"
        networkBitrate = UserDefaults.standard.object(forKey: "hearport.networkAudio.bitrate") as? Int ?? 256_000
        networkFrames = UserDefaults.standard.object(forKey: "hearport.networkAudio.frames") as? Int ?? 240
        usbCodec = UserDefaults.standard.object(forKey: "hearport.usbAudio.codec") as? String ?? "pcm"
        usbBitrate = UserDefaults.standard.object(forKey: "hearport.usbAudio.bitrate") as? Int ?? 256_000
        usbFrames = UserDefaults.standard.object(forKey: "hearport.usbAudio.frames") as? Int ?? 240
        keepScreenAwake = UserDefaults.standard.object(forKey: "hearport.keepScreenAwake") as? Bool ?? false
    }

    fileprivate var canvas: some View {
        NavigationStack { [self] in
            homeView
            .navigationTitle("HearPort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { [self] in
                ToolbarItem(placement: .principal) {
                    Text("HearPort")
                        .font(.system(size: 32, weight: .semibold))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { [self] in canvasSheet = .settings } label: {
                        Image(systemName: "gearshape")
                            .accessibilityLabel(Text("Settings"))
                    }
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .tint(Color.primary)
        .background { [self] in
            NarrowFormSheet(item: binding(\.canvasSheet)) { [self] sheet in
                NavigationStack { [self] in
                    Group { [self] in
                        switch sheet {
                        case .settings: settingsView
                        case .details: connectionDetailsView
                        case .recommendations: calibrationResults
                        case .pairing: connectionSetupView
                        }
                    }
                    .toolbar { [self] in
                        ToolbarItem(placement: .navigationBarTrailing) {
                            if sheet != .pairing {
                                Button("Done") { [self] in canvasSheet = nil; pendingCalibration = nil; calibrationTarget = nil }
                            }
                        }
                    }
                }
                .tint(Color.primary)
            }
        }
        .onAppear { [self] in start(); resumeConnection() }
        .onChange(of: detailedLogging) { [self] enabled in
            diagnostics.level = enabled ? .debug : .info
            diagnostics.log(
                .info,
                category: .app,
                message: "ui_logging_level_changed",
                fields: ["event": "ui_logging_level_changed", "level": enabled ? "debug" : "info"]
            )
            refreshDiagnostics()
        }
        .confirmationDialog("Unpair this PC?", isPresented: Binding(get: { [self] in unpairTarget != nil }, set: { [self] value in if !value { unpairTarget = nil } }), titleVisibility: .visible) {
            if let target = unpairTarget {
                Button("Unpair", role: .destructive) { [self] in forgetComputer(target) }
            }
            Button("Cancel", role: .cancel) { [self] in unpairTarget = nil }
        } message: {
            Text(unpairTarget?.title ?? "")
        }
        .onChange(of: keepScreenAwake) { [self] _ in updateIdleTimer() }
        .onChange(of: testRunning) { [self] _ in updateIdleTimer() }
        .onChange(of: pendingCalibration != nil) { [self] _ in updateIdleTimer() }
        .onChange(of: canvasSheet) { [self] sheet in
            if sheet == nil && !isConnecting {
                pendingCalibration = nil; calibrationTarget = nil
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { [self] _ in
            guard scenePhase == .active else { return }
            if connectionEstablished && control != nil && !sendingReport && completedTestStatus == nil && !isConnecting {
                let sample = receiver.linkTimingSample()
                linkSample = sample
                qualityTracker.observe(sample)
            } else { qualityTracker = LinkStabilityTracker(); linkSample = nil }
            if calibrationProgress != nil { calibrationNow = DispatchTime.now().uptimeNanoseconds }
            if musicRound != nil { roundElapsed = max(0, ProcessInfo.processInfo.systemUptime - roundStartedAt) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { [self] _ in
            control?.interruptCalibration(forOutputChange: true)
        }
        .onChange(of: host) { [self] newHost in
            if authMode == .remembered && newHost != rememberedHost {
                authMode = .pair
            }
        }
    }

    private let processStartedAt = ProcessInfo.processInfo.systemUptime
    private var automationRequests: [UUID: TimeInterval] = [:]
    private var started = false
    private var recoveryIntent = ConnectionRecoveryIntent()
    private var requestedRoute: AutomationRoute = .automatic

    public func start() {
        guard !started else { return }
        started = true
        connectionManager.onRequest = { [self] id, route in beginConnection(id: id, route: route) }
        connectionManager.onCancel = { [self] id in
            if let candidate = pendingControls.removeValue(forKey: id) { candidate.cancel() }
            if id == connectionID {
                control?.end(reason: 2); control = nil
                try? audioOutput?.stop(); audioOutput = nil
            }
        }
        connectionManager.onSearching = { [self] in
            if completedTestStatus == nil { showConnectionSearch() }
        }
        connectionManager.onNetworkAvailable = { [weak self] in self?.resumeConnection() }
        connectionManager.start()
        automationEvent("runtime_started")
        updateIdleTimer()
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

    private func binding<T>(_ key: ReferenceWritableKeyPath<ReceiverRuntime, T>) -> Binding<T> {
        Binding(get: { self[keyPath: key] }, set: { self[keyPath: key] = $0 })
    }

    fileprivate func updateScene(_ phase: ScenePhase, reduceMotion: Bool) {
        scenePhase = phase; self.reduceMotion = reduceMotion
        updateIdleTimer()
        automationEvent("scene", fields: ["phase": String(describing: phase)])
        if phase == .active { resumeConnection(); connectionManager.resumeUSBDiscovery() }
        if phase == .background { control?.interruptCalibration() }
        if phase != .active { qualityTracker = LinkStabilityTracker(); linkSample = nil }
    }

    private func resumeConnection() {
        if !hasRememberedCredential, let saved = try? KeychainRememberedCredentialStore().load() {
            hasRememberedCredential = true
            connectionManager.setRememberedIdentity(saved.windowsSPKISHA256)
        }
        guard control == nil, !isConnecting, completedTestStatus == nil,
              recoveryIntent.shouldResume(automatic: autoConnect && canvasHasAppeared, remembered: hasRememberedCredential) else { return }
        authMode = .remembered
        connect(route: requestedRoute)
    }

    private var presentationStage: ConnectionPresentationStage {
        .resolve(completed: completedTestStatus != nil, reporting: sendingReport,
            recovering: retainingConnection && isConnecting, connecting: isConnecting,
            playing: audioOutput != nil || (connectionEstablished && audioOutputState == .failed),
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
        case .playing:
            switch audioOutputState {
            case .failed: return Self.localize("Audio output unavailable")
            case .interrupted: return Self.localize("Playback interrupted")
            case .recovering: return Self.localize("Restoring audio…")
            default: return Self.localize("Playing")
            }
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
        case .playing where audioOutputState == .failed:
            return Self.localize("The connection is active. Retry audio playback.")
        default: return calibrationStartStatus ?? currentComputerName
        }
    }

    private var homeView: some View {
        GeometryReader { [self] geometry in
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
                        if pairingNeedsAttention {
                            Button("Pair again") { [self] in authMode = .pair; pin = ""; canvasSheet = .pairing }
                                .tint(.blue).buttonStyle(.borderless)
                        }
                        if audioOutputState == .failed && connectionEstablished && !testRunning {
                            Button("Retry playback", action: retryAudioOutput)
                                .tint(.blue).buttonStyle(.borderless)
                        }
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
                            Button { [self] in canvasSheet = .recommendations } label: {
                                Text("Review recommendations").font(.headline)
                                    .padding(.horizontal, 24).padding(.vertical, 14)
                                    .foregroundStyle(Color(uiColor: .systemBackground))
                                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                            if sendingReport {
                                Text("Recommendations are saved on this iPad. A diagnostic copy is being sent to the PC.")
                                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                            Button("Back to connections") { [self] in disconnect() }
                        } else {
                            Button { [self] in disconnect() } label: {
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
                .animation(reduceMotion || !canvasHasAppeared ? nil : .easeInOut(duration: 0.45), value: presentationStage)
            }
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .background(CanvasAppearanceObserver { [self] in canvasHasAppeared = true; resumeConnection() })
        .transaction { [self] transaction in
            if !canvasHasAppeared { transaction.disablesAnimations = true; transaction.animation = nil }
        }
    }

    @ViewBuilder private var canvasLinkStatus: some View {
        if showsConnections {
            if connectionManager.hasUSB {
                Label("USB available", systemImage: "cable.connector")
                    .font(.subheadline).foregroundStyle(.blue)
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
            ForEach(connectionManager.computers) { [self] computer in
                Button { [self] in selectConnection(computer.preferredEndpoint) } label: {
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
                .contextMenu {
                    Button { [self] in
                        calibrationTarget = computer
                        calibrationRunResult = nil
                        canvasSheet = .recommendations
                    } label: { Label("Automatic test and recommendations", systemImage: "slider.horizontal.3") }
                    .disabled(!computer.hasNetwork)
                    if hasRememberedCredential && connectionManager.isRemembered(computer.identity) {
                        Button(role: .destructive) { [self] in unpairTarget = computer } label: { Label("Unpair", systemImage: "link") }
                    }
                }
            }
            if !lastHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !lastHostIsDiscovered {
                Button { [self] in
                    selectedEndpoint = nil; host = lastHost
                    if hasRememberedCredential && lastHost == rememberedHost {
                        authMode = .remembered; connect()
                    } else { authMode = .oneTime; canvasSheet = .pairing }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "wifi").font(.title2).frame(width: 36)
                        Text("Last connection").font(.headline)
                        Spacer(minLength: 12)
                        Text(lastHost).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }.frame(minHeight: 34).padding(20).background(canvasSurface).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Button { [self] in
                selectedEndpoint = nil; canvasSheet = .pairing
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
        connectionManager.computers.contains { [self] computer in
            computer.networkAddress == lastHost ||
                (hasRememberedCredential && lastHost == rememberedHost && computer.title == connectionManager.rememberedComputerName)
        }
    }

    private func selectConnection(_ endpoint: ConnectionEndpoint) {
        selectedEndpoint = endpoint
        if hasRememberedCredential && (endpoint.identity == nil || connectionManager.isRemembered(endpoint.identity)) { authMode = .remembered; connect(selected: endpoint) }
        else {
            if endpoint.path == .network { host = endpoint.host }
            authMode = .pair; canvasSheet = .pairing
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
                            .tint(.hearPortGreen)
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
        Button { [self] in canvasSheet = .settings } label: {
            Label("Playback settings", systemImage: "slider.horizontal.3").frame(minHeight: 44)
        }
        .disabled(presentationStage == .reporting)
        Button { [self] in canvasSheet = .details } label: {
            Label("Connection details", systemImage: "info.circle").frame(minHeight: 44)
        }
        Spacer(minLength: 0)
        Button("Disconnect", role: .destructive) { [self] in disconnect() }
            .frame(minHeight: 44)

    }

    private var connectionDetailsView: some View {
        Form { [self] in
            Section("Current connection") {
                LabeledContent("Windows PC", value: currentComputerName)
                LabeledContent("Path", value: activePath == .usb ? "USB" :
                    activeNetworkEndpoint.isEmpty ? Self.localize("Resolving address…") : activeNetworkEndpoint)
                LabeledContent("Transport", value: (musicRound?.reliable ?? (activeAudioMode == .reliable)) ? "Reliable stream" : "Datagram")
                if musicRound == nil { LabeledContent("Audio format", value: activeAudioFormat.label) }
                if connectionEstablished && !isConnecting { Label("Identity verified", systemImage: "checkmark.shield") }
            }
            Section { [self] in
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
        Form { [self] in
            Section("Windows PC") {
                TextField("Hostname or IP address", text: Binding(get: { host }, set: {
                    host = $0
                    selectedEndpoint = nil
                    calibrationTarget = nil
                }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("Connection method") {
                Picker("Authentication", selection: binding(\.authMode)) {
                    if pendingCalibration == nil && hasRememberedCredential && (host == rememberedHost || connectionManager.hasUSB || !connectionManager.endpoints.isEmpty) {
                        Text("Remembered").tag(AuthMode.remembered)
                    }
                    Text("Pair and remember").tag(AuthMode.pair)
                    if pendingCalibration == nil { Text("One-time").tag(AuthMode.oneTime) }
                }
                if authMode != .remembered {
                    TextField("6-digit PIN", text: binding(\.pin))
                        .keyboardType(.numberPad)
                    Text("Enter the code displayed by HearPort on Windows.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section { [self] in
                Button { [self] in
                    connect(selected: selectedEndpoint, forCalibration: pendingCalibration != nil)
                    if canvasSheet == .pairing { canvasSheet = nil }
                } label: {
                    Text("Connect").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.automatic).tint(.blue)
                .disabled((host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && connectionManager.endpoints.isEmpty) ||
                          (authMode != .remembered && !PairingSecurity.validatePIN(pin)))
            }
        }
        .navigationTitle("Connect to a PC")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { [self] in
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { [self] in canvasSheet = nil; pendingCalibration = nil; calibrationTarget = nil }
            }
        }
    }

    private var playbackSettingsSection: some View {
            Section { [self] in
                audioFormatLink("Network audio", codec: binding(\.networkCodec), bitrate: binding(\.networkBitrate), frames: binding(\.networkFrames),
                                transport: binding(\.audioTransportModeRaw), target: binding(\.networkTargetLatencyMs), maximum: binding(\.networkMaximumLatencyMs))
                audioFormatLink("USB audio", codec: binding(\.usbCodec), bitrate: binding(\.usbBitrate), frames: binding(\.usbFrames),
                                transport: binding(\.usbTransportModeRaw), target: binding(\.usbTargetLatencyMs), maximum: binding(\.usbMaximumLatencyMs))
            } header: {
                Text("Playback")
            }
    }

    private func audioFormatLink(_ title: LocalizedStringKey, codec: Binding<String>,
                                 bitrate: Binding<Int>, frames: Binding<Int>, transport: Binding<String>,
                                 target: Binding<Int>, maximum: Binding<Int>) -> some View {
        NavigationLink {
            Form { [self] in
                Section { [self] in
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
                Section { [self] in
                    MillisecondsControl("Normal target", value: target, range: 10...max(10, maximum.wrappedValue))
                    MillisecondsControl("Maximum total delay", value: maximum, range: max(20, target.wrappedValue)...2_000)
                } footer: {
                    Text("The target and maximum include transport, processing and output. Changes take effect on the next connection. A higher maximum can tolerate longer interruptions.")
                }
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        } label: {
            LabeledContent {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(codec.wrappedValue == "opus" ?
                        "Opus · \(bitrate.wrappedValue / 1000) kb/s · \(Double(frames.wrappedValue) / 48) ms" : "PCM")
                    Text("Target \(target.wrappedValue) / Maximum \(maximum.wrappedValue) ms")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
            } label: {
                Text(title)
            }
        }
    }

    private var calibrationLink: some View {
        NavigationLink("Automatic test and recommendations") { calibrationResults }
    }

    @ViewBuilder private var calibrationResults: some View {
        if let calibrationRunResult {
            CalibrationResultsView(result: calibrationRunResult, apply: { [self] profile in
                _ = calibrationRunResult.apply(profile: profile)
            })
        } else {
            AdaptiveCalibrationView(result: adaptiveRunResult ?? adaptiveResult,
                canStart: canStartCalibration,
                hasSelectedConnection: calibrationTarget != nil || connectionEstablished || isConnecting,
                canChooseComputer: !connectionEstablished && !isConnecting,
                computers: connectionManager.computers, selectedComputer: binding(\.calibrationTarget),
                starting: calibrationRequestID != nil,
                status: calibrationStartStatus, start: startCalibration, apply: { [self] in
                    guard (adaptiveRunResult ?? adaptiveResult)?.apply() == true else { return false }
                    audioTransportModeRaw = UserDefaults.standard.string(forKey: "hearport.audioTransportMode") ?? AudioTransportMode.datagram.rawValue
                    let budget = PlaybackLatencyPreferences.load(usb: false)
                    networkTargetLatencyMs = budget.target
                    networkMaximumLatencyMs = budget.maximum
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
            ProgressView(value: Double(progress.seconds - remaining), total: Double(progress.seconds)).tint(.hearPortGreen)
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
                ProgressView(value: Double(progress.completed), total: Double(progress.total)).tint(.hearPortGreen)
                Text("Compared \(progress.completed) / \(progress.total) candidates")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else { ProgressView().tint(.hearPortGreen) }
            Text("Validation rounds will be selected after analysis.").font(.footnote).foregroundStyle(.secondary)
        } else if progress.stage == "interrupted" {
            Text("Calibration interrupted")
        } else if progress.index > 0 {
            let remaining = progress.remainingRoundSeconds(at: calibrationNow)
            Text(progress.stage == "validation" ? "Validating recommendations" : "Sampling network").font(.headline)
            Text("Round \(progress.phaseIndex) / \(progress.phaseCount)").font(.subheadline)
            ProgressView(value: Double(progress.seconds - remaining), total: Double(progress.seconds)).tint(.hearPortGreen)
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

    private var canSendCalibration: Bool {
        hasRememberedCredential && authMode == .remembered && connectionEstablished &&
            control != nil && !isConnecting && !testRunning && !sendingReport &&
            completedTestStatus == nil && (activePath == .network || connectionManager.computers.contains {
                $0.identity == currentComputerIdentity && $0.hasNetwork
            })
    }
    private var canStartCalibration: Bool {
        canSendCalibration || (calibrationTarget?.hasNetwork == true && pendingCalibration == nil && !testRunning)
    }

    private func startCalibration(goal: Int, seconds: Int, maximum: Int) {
        guard canStartCalibration else { return }
        if !canSendCalibration {
            guard let target = calibrationTarget else { return }
            pendingCalibration = (goal, seconds, maximum)
            selectedEndpoint = target.preferredEndpoint
            if hasRememberedCredential && connectionManager.isRemembered(target.identity) {
                authMode = .remembered; canvasSheet = nil
                connect(selected: target.preferredEndpoint, forCalibration: true)
            } else {
                authMode = .pair; pin = ""
                if target.preferredEndpoint.path == .network { host = target.preferredEndpoint.host }
                canvasSheet = .pairing
            }
            return
        }
        guard let control else { return }
        completedAdaptiveConnection = nil
        let id = UUID()
        calibrationRequestID = id; calibrationStartStatus = nil
        adaptiveRunResult = nil; calibrationRunResult = nil; calibrationProgress = nil
        testRunning = true
        control.requestEnvironmentCalibration(seconds: seconds, maximum: maximum, goal: goal) { [self] accepted in
            DispatchQueue.main.async { [self] in
                guard calibrationRequestID == id else { return }
                if accepted { canvasSheet = nil }
                else {
                    calibrationRequestID = nil; testRunning = false
                    calibrationStartStatus = Self.localize("Could not start calibration. Reconnect and try again.")
                    if audioOutput == nil && connectionEstablished { control.onReady?() }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [self] in
            guard calibrationRequestID == id else { return }
            calibrationRequestID = nil; testRunning = false
            calibrationStartStatus = Self.localize("The PC did not start calibration. Reconnect and try again.")
            status = calibrationStartStatus ?? Self.localize("Connection failed")
            if audioOutput == nil && connectionEstablished { control.onReady?() }
        }
    }

    private var settingsView: some View {
        Form { [self] in
            playbackSettingsSection
            Section { [self] in
                Toggle("Automatically reconnect", isOn: binding(\.autoConnect))
                    .tint(.green)
                Toggle("Keep screen awake", isOn: binding(\.keepScreenAwake)).tint(.green)
            } header: {
                Text("Connection")
            } footer: {
                Text("Uses the last connected PC when its pairing is saved.")
            }
            Section("Support") {
                NavigationLink("Shortcuts and automation") { automationHelp }
                calibrationLink
                NavigationLink {
                    diagnosticsView
                } label: {
                    Text("Diagnostics")
                }
            }
            Section { [self] in
                NavigationLink("About HearPort") {
                    Form { [self] in
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
        Form { [self] in
            Section { [self] in
                LabeledContent("Logging level", value: Self.label(for: diagnosticsSnapshot.level))
                LabeledContent("Recent entries (memory)", value: "\(diagnosticsSnapshot.entryCount)")
                LabeledContent("Saved log size", value: Self.byteLabel(diagnosticsSnapshot.totalBytes))
                Toggle("Detailed logging", isOn: binding(\.detailedLogging))
                    .tint(.green)
            } header: {
                Text("Current log")
            } footer: {
                Text("Secrets, authentication material, and raw audio are excluded from logs.")
            }
            Section("Actions") {
                Button { [self] in
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
                Button("Clear diagnostics", role: .destructive) { [self] in
                    showingClearConfirmation = true
                }
                .confirmationDialog("Clear retained diagnostics?", isPresented: binding(\.showingClearConfirmation), titleVisibility: .visible) {
                    Button("Clear", role: .destructive) { [self] in clearDiagnostics() }
                    Button("Cancel", role: .cancel) { [self] in}
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
        .onAppear { [self] in refreshDiagnostics() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { [self] _ in refreshDiagnostics() }
    }

    private func connect(selected: ConnectionEndpoint? = nil, forCalibration: Bool = false, route: AutomationRoute = .automatic) {
        recoveryIntent.request(); requestedRoute = route
        guard authMode == .remembered || PairingSecurity.validatePIN(pin) else {
            status = Self.localize("Enter the 6-digit PIN shown on Windows"); return
        }
        if !forCalibration { pendingCalibration = nil; calibrationTarget = nil }
        completedTestStatus = nil; connectionError = nil
        pairingNeedsAttention = false; audioOutputState = nil
        completedAdaptiveConnection = nil
        adaptiveRunResult = nil; calibrationRunResult = nil; calibrationProgress = nil
        sendingReport = false; retainingConnection = false
        calibrationRequestID = nil; calibrationStartStatus = nil
        musicRound = nil; testRunning = false; currentComputerName = ""
        qualityTracker = LinkStabilityTracker(); linkSample = nil
        isConnecting = true; status = Self.localize("Searching network and USB…")
        connectionManager.setMaximumLatency(usbMaximumLatencyMs)
        connectionManager.connect(manualHost: host.trimmingCharacters(in: .whitespacesAndNewlines),
            selected: selected, useRememberedIdentity: authMode == .remembered, route: route)
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
        automationEvent("connection_attempt", fields: ["route": route.path.rawValue, "connection_id": id.uuidString])
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
        var resolvedNetworkEndpoint = ""
        if route.path == .network {
            session.transport.onRemoteAddress = { [self] address in
                DispatchQueue.main.async { [self] in
                    resolvedNetworkEndpoint = address
                    if connectionID == id { activeNetworkEndpoint = address }
                }
            }
        }
        let budget = PlaybackLatencyPreferences.load(usb: route.path == .usb)
        let target = budget.target, maximum = budget.maximum
        if route.path == .usb { connectionManager.setMaximumLatency(maximum) }
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
        session.calibrationContext = { [self] in
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
        session.onAuthenticated = { [self, weak session] identity, features in
            DispatchQueue.main.async { [self] in
                guard let session, pendingControls[id] === session else { return }
                authenticatedIdentity = identity
                automationEvent("peer_authenticated", fields: ["connection_id": id.uuidString])
                if requestedAuthMode == .pair {
                    hasRememberedCredential = true; authMode = .remembered; pin = ""
                    connectionManager.setRememberedIdentity(identity)
                }
                guard connectionManager.authenticated(id, identity: identity, features: features) else { return }
                connectionID = id; control = session; receiver = activeReceiver
                pendingControls.removeValue(forKey: id)
                activePath = route.path
                activeNetworkEndpoint = resolvedNetworkEndpoint
                currentComputerName = "HearPort-" + identity.prefix(6).map { String(format: "%02x", $0) }.joined()
                currentComputerIdentity = identity.map { String(format: "%02x", $0) }.joined()
                if features & ControlFeature.environmentCalibration != 0 {
                    calibrationRequestID = nil; calibrationStartStatus = nil
                }
                qualityTracker = LinkStabilityTracker(); linkSample = nil; musicRound = nil; testRunning = false
                calibrationProgress = nil
                if completedAdaptiveConnection == nil { calibrationRunResult = nil; adaptiveRunResult = nil }
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
        session.onAuthenticationRejected = { [self, weak session] message in
            DispatchQueue.main.async { [self] in
                guard let session, pendingControls[id] === session else { return }
                disconnect()
                selectedEndpoint = route
                if route.path == .network { host = route.host }
                pairingNeedsAttention = true
                recoveryIntent.reject()
                automationEvent("authentication_rejected")
                connectionError = Self.localize(message)
                status = connectionError ?? Self.localize("Connection failed")
                diagnostics.log(.warning, category: .pairing, message: "remembered_auth_rejected_credentials_retained")
            }
        }
        session.onSessionEnded = { [self, weak session] reason in
            DispatchQueue.main.async { [self] in
                if reason == 3 {
                    guard connectionID == id, let session else { return }
                    do {
                        let store = KeychainRememberedCredentialStore()
                        if let saved = try store.load() {
                            guard PairingRecovery.removesCredential(reason: reason,
                                authenticated: authenticatedIdentity != nil,
                                session: session.pairedCredential, stored: saved) else { return }
                            try store.remove()
                        }
                        hasRememberedCredential = false; authMode = .pair; pin = ""
                        rememberedHost = ""; connectionManager.setRememberedIdentity(nil)
                        disconnect()
                        selectedEndpoint = route
                        if route.path == .network { host = route.host }
                        pairingNeedsAttention = true
                        connectionError = Self.localize("The PC cancelled this pairing. Pair again to connect.")
                        status = connectionError ?? Self.localize("Disconnected")
                        diagnostics.log(.info, category: .pairing, message: "authenticated_peer_removed_pairing")
                    } catch {
                        disconnect()
                        connectionError = Self.localize("Could not remove the saved pairing.")
                    }
                    return
                }
                if completedAdaptiveConnection == id {
                    if connectionID == id {
                        control?.cancel(); control = nil
                        try? audioOutput?.stop(); audioOutput = nil
                    }
                    connectionManager.ended(id)
                    if connectionManager.isWaiting { showConnectionSearch() }
                    return
                }
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
                    if completed == nil && recoveryIntent.shouldResume(automatic: autoConnect && canvasHasAppeared, remembered: hasRememberedCredential) {
                        control?.cancel(); control = nil
                        try? audioOutput?.stop(); audioOutput = nil
                        connectionEstablished = false; audioOutputState = nil
                        connectionManager.ended(id); showConnectionSearch()
                        automationEvent("peer_stopped_waiting")
                        return
                    }
                    control?.cancel(); control = nil
                    connectionManager.stop(); connectionID = UUID()
                    isConnecting = false; connectionError = nil
                    sendingReport = false; testRunning = false
                    status = completed ?? Self.localize("PC stopped the connection")
                } else { connectionManager.ended(id) }
            }
        }
        session.onDiagnosticSessionStarted = { [self] in
            DispatchQueue.main.async { [self] in if connectionID == id { connectionManager.pinActive() } }
        }
        session.onCalibrationProgress = { [self] progress in
            DispatchQueue.main.async { [self] in
                guard connectionID == activeConnectionID, completedTestStatus == nil, !sendingReport else { return }
                calibrationProgress = progress
                calibrationNow = DispatchTime.now().uptimeNanoseconds
                status = Self.localize(progress.stage == "analyzing" ? "Analyzing recommendations" : progress.stage == "validation" ?
                    "Validating recommendations" : progress.stage == "interrupted" ? "Calibration interrupted" : "Sampling network")
            }
        }
        session.onAdaptiveCalibrationResult = { [self] result in
            DispatchQueue.main.async { [self] in
                guard connectionID == activeConnectionID else { return }
                adaptiveRunResult = result
                if result.canApply { adaptiveResult = result }
                completedAdaptiveConnection = activeConnectionID
                connectionManager.resumeAfterTest()
                completedTestStatus = nil
                calibrationRequestID = nil
                testCompletedNormally = result.complete
                testRunning = false; isConnecting = false; sendingReport = false
                canvasSheet = .recommendations
            }
        }
        session.onCalibrationResult = { [self] result in
            DispatchQueue.main.async { [self] in
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
        session.onTransportState = { [self] newState in
            DispatchQueue.main.async { [self] in
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
        session.onError = { [self] message in
            diagnostics.log(
                .warning,
                category: .app,
                message: "ui_connection_error",
                fields: ["event": "ui_connection_error", "message_bytes": "\(message.utf8.count)"]
            )
            DispatchQueue.main.async { [self] in
                if authenticatedIdentity == nil && connectionManager.isWaiting && control == nil && requestedAuthMode != .remembered {
                    connectionManager.stop(); isConnecting = false
                    pendingCalibration = nil; calibrationTarget = nil
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
                pendingCalibration = nil; calibrationTarget = nil
                isConnecting = false
                connectionError = Self.localize(reportInterrupted ? "Report transfer interrupted. Receipt not confirmed." : message)
                status = connectionError ?? Self.localize("Connection failed")
                refreshDiagnostics()
            }
        }
        session.onAudioFormat = { [self] format in
            DispatchQueue.main.async { [self] in
                guard connectionID == id else { return }
                activeAudioFormat = format
                diagnostics.log(.info, category: .audio, message: "ui_audio_format_negotiated",
                    fields: ["physical_path": route.path.rawValue, "format": format.label])
            }
        }
        session.onReady = { [self, weak session] in
            DispatchQueue.main.async { [self] in
                guard connectionID == activeConnectionID, completedTestStatus == nil else { return }
                // Ready also resumes playback after the PC acknowledges an older retained report.
                sendingReport = false
                isConnecting = false
                connectionEstablished = true
                automationEvent("session_ready", fields: ["connection_id": id.uuidString])
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
                if let request = pendingCalibration {
                    pendingCalibration = nil
                    startCalibration(goal: request.goal, seconds: request.seconds, maximum: request.maximum)
                    return
                }
                do {
                    try startAudioOutput(receiver: activeReceiver, id: id)
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
                    audioOutputState = .failed
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
        session.onMusicTestRound = { [self] round in
            DispatchQueue.main.async { [self] in
                guard connectionID == activeConnectionID, completedTestStatus == nil, !sendingReport else { return }
                musicRound = round
                roundStartedAt = ProcessInfo.processInfo.systemUptime; roundElapsed = 0
                status = Self.label(for: round)
                refreshDiagnostics()
            }
        }
        session.onDiagnosticReportSending = { [self] in
            DispatchQueue.main.async { [self] in
                guard connectionID == activeConnectionID else { return }
                connectionManager.pinActive()
                sendingReport = true
                status = Self.localize("Test ended. Preparing and sending the report…")
                refreshDiagnostics()
            }
        }
        session.onDiagnosticReportReceived = { [self] reason in
            DispatchQueue.main.async { [self] in
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

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = scenePhase == .active &&
            (keepScreenAwake || testRunning || pendingCalibration != nil)
    }

    private func forgetComputer(_ target: ComputerConnectionTarget) {
        guard connectionManager.isRemembered(target.identity) else { return }
        unpairTarget = nil
        do {
            try KeychainRememberedCredentialStore().remove()
            disconnect(reason: 3)
            hasRememberedCredential = false; authMode = .pair; pin = ""
            rememberedHost = ""
            connectionManager.setRememberedIdentity(nil)
            diagnostics.log(.info, category: .pairing, message: "pairing_removed")
        } catch {
            connectionError = Self.localize("Could not remove the saved pairing.")
            status = connectionError ?? Self.localize("Connection failed")
        }
    }

    private func disconnect(reason: UInt32 = 1) {
        recoveryIntent.pause()
        pendingCalibration = nil; calibrationTarget = nil
        completedAdaptiveConnection = nil
        let hadActiveSession = control != nil || audioOutput != nil
        let closing = control
        control = nil
        connectionManager.completed()
        connectionID = UUID()
        let closedID = connectionID
        if let closing {
            closing.end(reason: reason) { [self] in
                DispatchQueue.main.async { [self] in
                    guard connectionID == closedID, !isConnecting, control == nil else { return }
                    connectionManager.stop()
                }
            }
        } else { connectionManager.stop() }
        isConnecting = false
        connectionError = nil
        connectionEstablished = false
        completedTestStatus = nil
        adaptiveRunResult = nil; calibrationRunResult = nil; calibrationProgress = nil
        sendingReport = false; retainingConnection = false; musicRound = nil; testRunning = false
        qualityTracker = LinkStabilityTracker(); linkSample = nil
        currentComputerName = ""
        activeNetworkEndpoint = ""
        currentComputerIdentity = ""; calibrationRequestID = nil; calibrationStartStatus = nil
        try? audioOutput?.stop()
        audioOutput = nil
        audioOutputState = nil; pairingNeedsAttention = false
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

    private func startAudioOutput(receiver: HearPortReceiver, id: UUID) throws {
        let output = PlatformAudioOutputController(receiver: receiver)
        output.onStateChanged = { [self, weak output] state in
            DispatchQueue.main.async { [self] in
                guard connectionID == id, let output, audioOutput === output else { return }
                audioOutputState = state
            }
        }
        do { try output.start() }
        catch { try? output.stop(); throw error }
        audioOutput = output; audioOutputState = .playing
        automationEvent("audio_engine_started", fields: ["connection_id": id.uuidString])
        observeReceivedAudio(output, id: id, until: ProcessInfo.processInfo.systemUptime + 60)
    }

    private func retryAudioOutput() {
        guard connectionEstablished, control != nil, !testRunning else { return }
        try? audioOutput?.stop(); audioOutput = nil
        do {
            try startAudioOutput(receiver: receiver, id: connectionID)
            status = Self.localize("Playing")
        } catch {
            audioOutputState = .failed
            status = Self.localize("Audio output unavailable")
            diagnostics.log(.error, category: .audio, message: "ui_audio_retry_failed",
                fields: ["error_type": "\(type(of: error))"])
        }
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
        connectionManager.recordUSBStatus { [self] in
            DispatchQueue.global(qos: .utility).async { [self] in
                let result = Result { try log.export() }
                DispatchQueue.main.async { [self] in
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


extension ReceiverRuntime {
    private func automationEvent(_ stage: String, fields: [String: String] = [:]) {
        let now = ProcessInfo.processInfo.systemUptime
        automationRequests = automationRequests.filter { now - $0.value < 120 }
        var common = fields
        common["stage"] = stage
        common["pid"] = "\(ProcessInfo.processInfo.processIdentifier)"
        common["process_ms"] = "\(Int((now - processStartedAt) * 1_000))"
        common["ui_appeared"] = "\(canvasHasAppeared)"
        common["application_state"] = "\(UIApplication.shared.applicationState.rawValue)"
        common["os"] = UIDevice.current.systemVersion
        common["build"] = Bundle.main.object(forInfoDictionaryKey: "HearPortBuildID") as? String ?? "local"
        if automationRequests.isEmpty {
            diagnostics.log(.info, category: .app, message: "automation_stage", fields: common)
        } else {
            for (id, began) in automationRequests {
                var entry = common
                entry["request_id"] = id.uuidString
                entry["elapsed_ms"] = "\(Int((now - began) * 1_000))"
                diagnostics.log(.info, category: .app, message: "automation_stage", fields: entry)
            }
        }
    }

    private func observeReceivedAudio(_ output: PlatformAudioOutputController, id: UUID, until: TimeInterval) {
        guard connectionID == id, audioOutput === output else { return }
        if output.hasRenderedReceivedAudio {
            automationEvent("received_audio_rendered", fields: ["connection_id": id.uuidString])
        } else if ProcessInfo.processInfo.systemUptime < until {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak output] in
                guard let self, let output else { return }
                self.observeReceivedAudio(output, id: id, until: until)
            }
        }
    }

    public func automationStatus(source: String = "status") -> String {
        start()
        automationEvent("status_requested", fields: ["source": source])
        return automationReply(audioOutput?.hasRenderedReceivedAudio == true ? "received_audio_rendered" :
            audioOutput != nil ? "engine_started" : isConnecting ? "waiting" :
            pairingNeedsAttention ? "authentication_rejected" : "disconnected")
    }

    private func automationReply(_ result: String, request: UUID? = nil) -> String {
        var value: [String: String] = ["result": result, "route": control != nil ? activePath.rawValue : requestedRoute.rawValue,
            "paired": "\(hasRememberedCredential)", "engine": audioOutputState.map { String(describing: $0) } ?? "stopped",
            "pid": "\(ProcessInfo.processInfo.processIdentifier)"]
        if let request { value["request_id"] = request.uuidString }
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? result
    }

    public func markAutomationTrigger() -> String {
        start()
        let id = UUID(); automationRequests[id] = ProcessInfo.processInfo.systemUptime
        automationEvent("trigger_marker", fields: ["marker_id": id.uuidString])
        return automationReply("trigger_recorded", request: id)
    }

    public func automationDisconnect() -> String {
        start(); automationEvent("disconnect_requested")
        disconnect()
        return automationReply("disconnected")
    }

    public func automationConnect(route: AutomationRoute, source: String) async -> String {
        start()
        let id = UUID(); automationRequests[id] = ProcessInfo.processInfo.systemUptime
        automationEvent("action_entered", fields: ["source": source, "requested_route": route.rawValue])
        guard !pairingNeedsAttention else { return automationReply("authentication_rejected", request: id) }
        guard !testRunning && !sendingReport && pendingCalibration == nil else { return automationReply("test_running", request: id) }
        // Reload after an earlier attempt while Keychain was unavailable before first unlock.
        do {
            let saved = try KeychainRememberedCredentialStore().load()
            hasRememberedCredential = saved != nil
            connectionManager.setRememberedIdentity(saved?.windowsSPKISHA256)
        } catch {
            automationEvent("credential_unavailable")
            return automationReply("credential_unavailable", request: id)
        }
        guard hasRememberedCredential else { return automationReply("pair_in_app", request: id) }
        if control != nil && !route.includes(activePath) {
            return automationReply("another_route_active", request: id)
        }
        if isConnecting && route != requestedRoute {
            return automationReply("another_request_active", request: id)
        }
        recoveryIntent.request()
        if control == nil && !isConnecting {
            host = rememberedHost.isEmpty ? lastHost : rememberedHost
            authMode = .remembered
            connect(route: route)
        } else if connectionEstablished && audioOutputState == .failed { retryAudioOutput() }
        automationEvent("request_accepted")
        // Keep the invocation alive briefly for authentication/audio startup; this is not a keepalive.
        for _ in 0..<32 {
            if Task.isCancelled { return automationReply("cancelled", request: id) }
            if audioOutput != nil { break }
            if pairingNeedsAttention || audioOutputState == .failed || !isConnecting { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let result = pairingNeedsAttention ? "authentication_rejected" :
            audioOutput?.hasRenderedReceivedAudio == true ? "received_audio_rendered" :
            audioOutput != nil ? "engine_started" : audioOutputState == .failed ? "audio_failed" :
            isConnecting ? "waiting" : "disconnected"
        automationEvent("action_returned", fields: ["result": result])
        return automationReply(result, request: id)
    }

    public func handleAutomationURL(_ url: URL) async {
        guard let command = AutomationCommand(url: url) else {
            automationEvent("url_rejected"); return
        }
        switch command {
        case let .connect(route): _ = await automationConnect(route: route, source: "url_foreground")
        case .disconnect: _ = automationDisconnect()
        case .status: _ = automationStatus(source: "url_foreground"); canvasSheet = .details
        }
    }

    private var automationHelp: some View {
        Form {
            Section("Shortcuts") {
                Text("Add HearPort actions in Shortcuts. Play PC audio uses an audio playback action; Background connect and Open and connect allow comparison.")
                Text("Choose Automatic, Network only or USB only. Only the saved paired PC is used. Pair in HearPort first.")
            }
            Section("Personal automation") {
                Text("For joining your Wi-Fi, run Play PC audio with Network only. For charger connected, use USB only: a charger does not prove a PC data connection is ready.")
                Text("Choose Run Immediately if available. System permissions, first unlock and foreground actions may still require interaction.")
            }
            Section("Verification") {
                Text("Record automation trigger can precede a connection action. Read connection status returns a request result; export Diagnostics after testing to compare trigger, authentication, audio engine and received audio stages.")
                Text("An engine start does not prove audible sound. A silent PC may send no audio. Locked, background and force-quit cases need testing on this iPad.")
            }
        }.navigationTitle("Shortcuts and automation").navigationBarTitleDisplayMode(.inline)
    }
}

private struct CanvasAppearanceObserver: UIViewControllerRepresentable {
    let onFirstAppearance: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        controller.onFirstAppearance = onFirstAppearance
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onFirstAppearance = onFirstAppearance
    }

    final class Controller: UIViewController {
        var onFirstAppearance: (() -> Void)?
        private var appeared = false
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !appeared else { return }
            appeared = true
            onFirstAppearance?()
        }
    }
}

public typealias HearPortReceiverView = HearPortApp
#endif
