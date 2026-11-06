import Foundation

struct PlaybackRecoveryWindow {
    private var armed = false
    private(set) var active = false

    mutating func playbackStarted() { active = false; armed = true }
    mutating func begin(eligible: Bool) -> Bool {
        guard !active else { return false }
        let allowed = armed && eligible
        armed = false
        active = allowed
        return allowed
    }
    mutating func end() { active = false; armed = false }
}

struct AudioPlaybackRecovery {
    private enum State { case stopped, playing, interrupted, waitingForUser }
    private var state = State.stopped
    var canRecoverAutomatically: Bool { state == .playing }
    mutating func start() { state = .playing }
    mutating func stop() { state = .stopped }
    mutating func interrupt() {
        if state == .playing { state = .interrupted }
    }
    mutating func endInterruption(shouldResume: Bool) -> Bool {
        guard state == .interrupted else { return false }
        state = shouldResume ? .playing : .waitingForUser
        return shouldResume
    }
    mutating func mediaServicesReset() {
        if state != .stopped { state = .waitingForUser }
    }
}

#if canImport(UIKit) && os(iOS)
import UIKit

@MainActor final class PlaybackBackgroundRecovery {
    private var window = PlaybackRecoveryWindow()
    private var task = UIBackgroundTaskIdentifier.invalid
    private var deadline: DispatchWorkItem?
    private var generation = UUID()
    private let diagnostics = HearPortDiagnostics.shared

    func playbackStarted() {
        end(reason: "playback_started")
        window.playbackStarted()
    }

    func begin(eligible: Bool) {
        guard window.begin(eligible: eligible) else { return }
        let generation = UUID()
        self.generation = generation
        let acquired = UIApplication.shared.beginBackgroundTask(withName: "Restore PC audio") { [weak self] in
            guard let self, self.generation == generation else { return }
            self.end(reason: "system_expired")
        }
        guard self.generation == generation, window.active else {
            if acquired != .invalid { UIApplication.shared.endBackgroundTask(acquired) }
            return
        }
        task = acquired
        guard task != .invalid else { window.end(); return }
        diagnostics.log(.info, category: .app, message: "background_recovery_started")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation else { return }
            self.end(reason: "deadline")
        }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    func end(reason: String) {
        generation = UUID()
        window.end()
        deadline?.cancel(); deadline = nil
        guard task != .invalid else { return }
        let finished = task; task = .invalid
        UIApplication.shared.endBackgroundTask(finished)
        diagnostics.log(.info, category: .app, message: "background_recovery_ended", fields: ["reason": reason])
    }
}
#endif
