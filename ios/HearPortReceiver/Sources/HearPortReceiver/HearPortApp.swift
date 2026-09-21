#if canImport(SwiftUI) && canImport(Network) && canImport(AVFAudio) && os(iOS)
import AVFAudio
import Network
import SwiftUI

public struct HearPortApp: View {
    @State private var host = ""
    @State private var pin = ""
    @State private var authMode: AuthMode = .pair
    @State private var status = "Disconnected"
    @State private var receiver = HearPortReceiver()
    @State private var control: ReceiverControlSession?
    @State private var audioOutput: PlatformAudioOutputController?

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
            }
            .navigationTitle("HearPort")
        }
        .onAppear {
            status = "Disconnected"
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
            return
        }
        let session = ReceiverControlSession(
            receiver: receiver,
            provider: PairingSecurity.defaultSpake2Provider()
        )
        session.onTransportState = { newState in
            DispatchQueue.main.async { status = Self.label(for: newState) }
        }
        session.onError = { message in
            DispatchQueue.main.async { status = message }
        }
        session.onReady = {
            DispatchQueue.main.async {
                do {
                    let output = PlatformAudioOutputController(receiver: receiver)
                    try output.start()
                    audioOutput = output
                    status = "Playing"
                } catch {
                    status = "Audio output unavailable"
                }
            }
        }
        control = session
        session.connect(host: endpoint, mode: authMode, pin: pin)
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
}
#endif
