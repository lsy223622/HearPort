import SwiftUI
import HearPortReceiver

@main
@MainActor
struct HearPortApp: App {
    init() {
        ReceiverRuntime.shared.start()
    }
    var body: some Scene {
        WindowGroup {
            HearPortReceiverView()
                .onOpenURL { url in
                    Task { await ReceiverRuntime.shared.handleAutomationURL(url) }
                }
        }
    }
}
