#if canImport(SwiftUI) && os(iOS)
import AVFAudio
import MediaPlayer
import SwiftUI

@MainActor struct SystemVolumeExperiment: View {
    @State private var volumeView = MPVolumeView(frame: .zero)
    @State private var pending = false
    @State private var result = ""

    var body: some View {
        Section("系统媒体音量实验") {
            VolumeControl(view: volumeView)
                .frame(height: 36)
            Button("立即测试") { schedule(after: 0) }
                .disabled(pending)
            Button("10 秒后测试") { schedule(after: 10) }
                .disabled(pending)
            if !result.isEmpty { Text(verbatim: result).textSelection(.enabled) }
        }
    }

    private func schedule(after delay: TimeInterval) {
        pending = true
        result = delay > 0 ? "已排队，可以锁屏" : "正在测试"
        let scheduledAt = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let session = AVAudioSession.sharedInstance()
            let before = session.outputVolume
            let target = before >= 0.2 ? before - 0.15 : min(before + 0.15, 0.2)
            let state = UIApplication.shared.applicationState.rawValue
            let elapsed = ProcessInfo.processInfo.systemUptime - scheduledAt
            let slider = volumeView.subviews.compactMap { $0 as? UISlider }.first
            slider?.setValue(target, animated: false)
            slider?.sendActions(for: .valueChanged)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                let after = session.outputVolume
                let completedState = UIApplication.shared.applicationState.rawValue
                result = String(format: "%.2f → %.2f（目标 %.2f）｜状态 %ld → %ld｜%.1f 秒｜%@", before, after,
                                target, state, completedState, elapsed, slider == nil ? "未找到滑块" : "已拨动滑块")
                HearPortDiagnostics.shared.log(.info, category: .audio, message: "system_volume_experiment", fields: [
                    "before": "\(before)", "requested": "\(target)", "after": "\(after)",
                    "app_state_at_write": "\(state)", "app_state_at_read": "\(completedState)",
                    "delay_requested": "\(delay)", "delay_actual": "\(elapsed)", "slider_found": "\(slider != nil)"
                ])
                pending = false
            }
        }
    }

    private struct VolumeControl: UIViewRepresentable {
        let view: MPVolumeView
        func makeUIView(context: Context) -> MPVolumeView { view }
        func updateUIView(_ uiView: MPVolumeView, context: Context) {}
    }
}
#endif
