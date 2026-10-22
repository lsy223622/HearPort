import AppIntents
import HearPortReceiver

enum HearPortRoute: String, AppEnum {
    case automatic, network, usb
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Connection route"
    static var caseDisplayRepresentations: [HearPortRoute: DisplayRepresentation] = [
        .automatic: "Automatic (USB preferred)", .network: "Network only", .usb: "USB only"
    ]
    var route: AutomationRoute { AutomationRoute(rawValue: rawValue)! }
}

@available(iOS 17.0, *)
struct PlayPCAudioIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play PC audio"
    static var description = IntentDescription("Connect to the saved paired PC and start audio without opening HearPort.")
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @Parameter(title: "Connection route", default: .automatic) var route: HearPortRoute
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: await ReceiverRuntime.shared.automationConnect(route: route.route, source: "audio_playback_intent"))
    }
}

struct BackgroundConnectIntent: AppIntent {
    static var title: LocalizedStringResource = "Background connect"
    static var description = IntentDescription("Compare ordinary background execution with the audio playback action.")
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @Parameter(title: "Connection route", default: .automatic) var route: HearPortRoute
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: await ReceiverRuntime.shared.automationConnect(route: route.route, source: "background_intent"))
    }
}

struct OpenAndConnectIntent: AppIntent {
    static var title: LocalizedStringResource = "Open and connect"
    static var description = IntentDescription("Open HearPort and connect to the saved paired PC. Unlocking may be required.")
    static var openAppWhenRun = true
    @Parameter(title: "Connection route", default: .automatic) var route: HearPortRoute
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: await ReceiverRuntime.shared.automationConnect(route: route.route, source: "foreground_intent"))
    }
}

@available(iOS 17.0, *)
struct DisconnectPCAudioIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Disconnect PC audio"
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: ReceiverRuntime.shared.automationDisconnect())
    }
}

struct ConnectionStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Read connection status"
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: ReceiverRuntime.shared.automationStatus())
    }
}

struct AutomationMarkerIntent: AppIntent {
    static var title: LocalizedStringResource = "Record automation trigger"
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: ReceiverRuntime.shared.markAutomationTrigger())
    }
}

@available(iOS 17.0, *)
struct HearPortShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayPCAudioIntent(), phrases: ["Play PC audio with \(.applicationName)"],
                    shortTitle: "Play PC audio", systemImageName: "play.circle")
        AppShortcut(intent: BackgroundConnectIntent(), phrases: ["Connect in the background with \(.applicationName)"],
                    shortTitle: "Background connect", systemImageName: "network")
        AppShortcut(intent: OpenAndConnectIntent(), phrases: ["Open and connect with \(.applicationName)"],
                    shortTitle: "Open and connect", systemImageName: "desktopcomputer")
        AppShortcut(intent: DisconnectPCAudioIntent(), phrases: ["Disconnect PC audio with \(.applicationName)"],
                    shortTitle: "Disconnect PC audio", systemImageName: "stop.circle")
        AppShortcut(intent: ConnectionStatusIntent(), phrases: ["Read connection status with \(.applicationName)"],
                    shortTitle: "Read connection status", systemImageName: "info.circle")
        AppShortcut(intent: AutomationMarkerIntent(), phrases: ["Record automation trigger with \(.applicationName)"],
                    shortTitle: "Record automation trigger", systemImageName: "checkmark.circle")
    }
}
