import Foundation

public enum AudioLifecycleState: Equatable, Sendable {
    case idle
    case playing
    case interrupted
    case silentRebuffer
    case stopped
}

public enum AudioLifecycleEvent: Sendable {
    case interruptionBegan
    case interruptionEnded
    case routeChanged
    case audioAvailable
}

public final class AudioLifecycleController {
    private let diagnostics: HearPortDiagnostics
    public private(set) var state: AudioLifecycleState = .idle
    public private(set) var resetGeneration = 0

    public init(diagnostics: HearPortDiagnostics = .shared) {
        self.diagnostics = diagnostics
    }

    public var shouldRenderSilence: Bool {
        state == .interrupted || state == .silentRebuffer
    }

    public func startSpeakerSession() {
        state = .playing
        diagnostics.log(
            .info,
            category: .audio,
            message: "speaker_session_started",
            fields: ["event": "speaker_session_started", "state": "\(state)"]
        )
    }

    public func stopSpeakerSession() {
        state = .stopped
        diagnostics.log(
            .info,
            category: .audio,
            message: "speaker_session_stopped",
            fields: ["event": "speaker_session_stopped", "state": "\(state)"]
        )
    }

    public func enterSilentRebuffer() {
        guard state != .stopped else { return }
        state = .silentRebuffer
        diagnostics.log(
            .info,
            category: .audio,
            message: "silent_rebuffer_entered",
            fields: ["event": "silent_rebuffer_entered", "state": "\(state)"]
        )
    }

    public func handle(_ event: AudioLifecycleEvent) {
        let previousState = state
        switch event {
        case .interruptionBegan:
            guard state != .stopped else { return }
            resetGeneration += 1
            state = .interrupted
        case .interruptionEnded:
            guard state == .interrupted else { return }
            state = .silentRebuffer
        case .routeChanged:
            guard state != .stopped else { return }
            resetGeneration += 1
            state = .silentRebuffer
        case .audioAvailable:
            guard state == .silentRebuffer || state == .playing else { return }
            state = .playing
        }
        if case .audioAvailable = event {
            return
        }
        diagnostics.log(
            .info,
            category: .audio,
            message: "audio_lifecycle_transition",
            fields: [
                "event": Self.diagnosticName(for: event),
                "previous_state": "\(previousState)",
                "state": "\(state)",
                "reset_generation": "\(resetGeneration)"
            ]
        )
    }

    private static func diagnosticName(for event: AudioLifecycleEvent) -> String {
        switch event {
        case .interruptionBegan: return "interruption_began"
        case .interruptionEnded: return "interruption_ended"
        case .routeChanged: return "route_changed"
        case .audioAvailable: return "audio_available"
        }
    }
}

#if canImport(AVFAudio) && os(iOS)
import AVFAudio

public final class PlatformAudioSessionController {
    private let diagnostics: HearPortDiagnostics
    private let audioSession = AVAudioSession.sharedInstance()

    public init(diagnostics: HearPortDiagnostics = .shared) {
        self.diagnostics = diagnostics
    }

    public func activateForPlayback() throws -> Double {
        diagnostics.log(
            .info,
            category: .audio,
            message: "audio_session_activation_requested",
            fields: ["event": "audio_session_activation_requested"]
        )
        try audioSession.setCategory(.playback, mode: .default, options: [])
        try audioSession.setActive(true)
        let route = audioSession.currentRoute
        guard let output = route.outputs.first else {
            diagnostics.log(
                .error,
                category: .audio,
                message: "audio_route_rejected",
                fields: ["event": "audio_route_rejected", "reason": "stereo_output_required"]
            )
            throw NSError(domain: "HearPortAudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "HearPort v1 requires a stereo output route"])
        }
        let channelCount = output.channels?.count ?? 0
        guard channelCount == 2 else {
            diagnostics.log(
                .error,
                category: .audio,
                message: "audio_route_rejected",
                fields: [
                    "event": "audio_route_rejected",
                    "reason": "stereo_output_required",
                    "channels": "\(channelCount)"
                ]
            )
            throw NSError(domain: "HearPortAudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "HearPort v1 requires a stereo output route"])
        }
        diagnostics.log(
            .info,
            category: .audio,
            message: "audio_session_activated",
            fields: [
                "event": "audio_session_activated",
                "channels": "\(channelCount)",
                "sample_rate": "\(audioSession.sampleRate)"
            ]
        )
        return audioSession.sampleRate
    }

    public func deactivate() throws {
        diagnostics.log(
            .info,
            category: .audio,
            message: "audio_session_deactivation_requested",
            fields: ["event": "audio_session_deactivation_requested"]
        )
        try audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

public final class PlatformAudioOutputController {
    private let receiver: HearPortReceiver
    private let lifecycle: AudioLifecycleController
    private let audioSession = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var observers: [NSObjectProtocol] = []
    private var drift = DriftController()
    private var outputSampleRate = 48_000.0

    public init(receiver: HearPortReceiver) {
        self.receiver = receiver
        lifecycle = receiver.lifecycle
    }

    public func start() throws {
        receiver.diagnostics.log(
            .info,
            category: .audio,
            message: "audio_output_start_requested",
            fields: ["event": "audio_output_start_requested"]
        )
        try audioSession.setCategory(.playback, mode: .default, options: [])
        try audioSession.setActive(true)
        guard let output = audioSession.currentRoute.outputs.first else {
            receiver.diagnostics.log(
                .error,
                category: .audio,
                message: "audio_route_rejected",
                fields: ["event": "audio_route_rejected", "reason": "stereo_output_required"]
            )
            throw NSError(domain: "HearPortAudio", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "HearPort v1 requires a stereo output route"])
        }
        let channelCount = output.channels?.count ?? 0
        guard channelCount == 2 else {
            receiver.diagnostics.log(
                .error,
                category: .audio,
                message: "audio_route_rejected",
                fields: [
                    "event": "audio_route_rejected",
                    "reason": "stereo_output_required",
                    "channels": "\(channelCount)"
                ]
            )
            throw NSError(domain: "HearPortAudio", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "HearPort v1 requires a stereo output route"])
        }
        outputSampleRate = audioSession.sampleRate
        drift = DriftController(nominalRatio: 48_000.0 / outputSampleRate)
        let format = engine.outputNode.outputFormat(forBus: 0)
        guard format.channelCount == 2 else {
            receiver.diagnostics.log(
                .error,
                category: .audio,
                message: "audio_format_rejected",
                fields: ["event": "audio_format_rejected", "channels": "\(format.channelCount)"]
            )
            throw NSError(domain: "HearPortAudio", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "HearPort v1 requires a two-channel output format"])
        }
        let source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount,
                                                               audioBufferList in
            guard let self else { return noErr }
            self.render(frameCount: Int(frameCount), audioBufferList: audioBufferList)
            return noErr
        }
        sourceNode = source
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        installAudioNotifications()
        lifecycle.startSpeakerSession()
        try engine.start()
        receiver.diagnostics.log(
            .info,
            category: .audio,
            message: "audio_output_started",
            fields: [
                "event": "audio_output_started",
                "sample_rate": "\(outputSampleRate)",
                "channels": "\(channelCount)"
            ]
        )
    }

    public func stop() throws {
        receiver.diagnostics.log(
            .info,
            category: .audio,
            message: "audio_output_stop_requested",
            fields: ["event": "audio_output_stop_requested"]
        )
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        engine.stop()
        if let sourceNode {
            engine.detach(sourceNode)
        }
        self.sourceNode = nil
        lifecycle.stopSpeakerSession()
        try audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
        receiver.diagnostics.log(
            .info,
            category: .audio,
            message: "audio_output_stopped",
            fields: ["event": "audio_output_stopped"]
        )
    }

    private func render(frameCount: Int,
                        audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        guard frameCount > 0 else { return }
        let fillError = Double(receiver.renderFillFrames - 960)
        let ratio = drift.update(
            fillError: fillError,
            validAudio: lifecycle.state == .playing &&
                receiver.renderFillFrames > 0
        )
        let sourceFrames = max(1, Int(ceil(Double(frameCount) * ratio)) + 1)
        let samples = receiver.renderFrames(sourceFrames)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard buffers.count > 0 else { return }
        if buffers.count == 1 {
            guard let pointer = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
                return
            }
            for frame in 0..<frameCount {
                let position = min(Int(Double(frame) * ratio), sourceFrames - 1)
                pointer[frame * 2] = samples[position * 2]
                pointer[frame * 2 + 1] = samples[position * 2 + 1]
            }
        } else {
            guard let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                return
            }
            for frame in 0..<frameCount {
                let position = min(Int(Double(frame) * ratio), sourceFrames - 1)
                left[frame] = samples[position * 2]
                right[frame] = samples[position * 2 + 1]
            }
        }
    }

    private func installAudioNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: audioSession,
            queue: nil
        ) { [weak self] _ in
            self?.receiver.diagnostics.log(
                .info,
                category: .audio,
                message: "audio_route_changed",
                fields: ["event": "route_changed"]
            )
            self?.receiver.handleAudioLifecycle(.routeChanged)
            self?.drift.reset()
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
                return
            }
            if type == .began {
                self.receiver.diagnostics.log(
                    .info,
                    category: .audio,
                    message: "audio_interruption_began",
                    fields: ["event": "interruption_began"]
                )
                self.receiver.handleAudioLifecycle(.interruptionBegan)
                self.drift.reset()
            } else {
                self.receiver.diagnostics.log(
                    .info,
                    category: .audio,
                    message: "audio_interruption_ended",
                    fields: ["event": "interruption_ended"]
                )
                self.receiver.handleAudioLifecycle(.interruptionEnded)
            }
        })
    }
}
#endif
