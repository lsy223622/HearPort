#if canImport(MediaPlayer) && os(iOS)
import MediaPlayer

@MainActor final class SystemPlaybackControls {
    enum State { case unavailable, playing, paused, connecting }
    var onPlay: (() -> Void)?
    var onStop: (() -> Void)?
    private let center = MPRemoteCommandCenter.shared()
    private var state = State.unavailable
    private var published = false
    private var targets: [(MPRemoteCommand, Any)] = []

    init() {
        register(center.playCommand) { $0.onPlay?() }
        register(center.pauseCommand) { $0.onStop?() }
        register(center.stopCommand) { $0.onStop?() }
        register(center.togglePlayPauseCommand) {
            if $0.state == .playing || $0.state == .connecting { $0.onStop?() }
            else { $0.onPlay?() }
        }
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }

    private func register(_ command: MPRemoteCommand, action: @escaping (SystemPlaybackControls) -> Void) {
        let target = command.addTarget { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.state != .unavailable else { return }
                action(self)
            }
            return .success
        }
        targets.append((command, target))
    }

    func update(_ next: State, computerName: String) {
        state = next
        let active = next == .playing || next == .connecting
        center.playCommand.isEnabled = next == .paused
        center.pauseCommand.isEnabled = active
        center.stopCommand.isEnabled = active
        center.togglePlayPauseCommand.isEnabled = next != .unavailable
        if next == .unavailable {
            if published { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
            published = false
            return
        }
        guard published || next == .playing else { return }
        published = true
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: NSLocalizedString("PC audio", bundle: .main, comment: ""),
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: next == .playing ? 1.0 : 0.0
        ]
        if !computerName.isEmpty { info[MPMediaItemPropertyArtist] = computerName }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    deinit {
        for (command, target) in targets { command.removeTarget(target) }
    }
}
#endif
