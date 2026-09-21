#if canImport(SwiftUI) && canImport(Network)
import Network
import SwiftUI

public struct HearPortApp: View {
    @State private var host = ""
    @State private var status = "Disconnected"
    @State private var transport = HearPortQuicTransport()

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section("Windows PC") {
                    TextField("Hostname or IP address", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
            transport.onStateChange = { newState in
                DispatchQueue.main.async {
                    status = Self.label(for: newState)
                }
            }
        }
        .onDisappear {
            transport.cancel()
        }
    }

    private func connect() {
        let endpoint = host.trimmingCharacters(in: .whitespacesAndNewlines)
        transport.connect(host: endpoint)
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
