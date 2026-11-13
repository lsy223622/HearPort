#if canImport(SwiftUI) && os(iOS)
import AVFAudio
import MediaPlayer
import SwiftUI

@MainActor final class RemoteSystemVolume {
    private let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 160, height: 32))

    var backingView: some View {
        VolumeControl(view: view)
            .frame(width: 160, height: 32)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    func request(_ percent: UInt32?, reply: @escaping (UInt32?) -> Void) {
        guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else {
            reply(nil)
            return
        }
        let session = AVAudioSession.sharedInstance()
        if let percent {
            slider.setValue(Float(percent) / 100, animated: false)
            slider.sendActions(for: .valueChanged)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                reply(UInt32((session.outputVolume * 100).rounded()))
            }
        } else {
            reply(UInt32((session.outputVolume * 100).rounded()))
        }
    }

    private struct VolumeControl: UIViewRepresentable {
        let view: MPVolumeView
        func makeUIView(context: Context) -> MPVolumeView { view }
        func updateUIView(_ uiView: MPVolumeView, context: Context) {}
    }
}
#endif
