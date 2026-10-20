#if canImport(SwiftUI) && os(iOS)
import SwiftUI

struct NarrowFormSheet<Item: Identifiable, Content: View>: UIViewControllerRepresentable {
    @Binding var item: Item?
    @ViewBuilder let content: (Item) -> Content

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.onDismiss = { item = nil }
        guard let item else {
            if let host = context.coordinator.host, !host.isBeingDismissed {
                host.dismiss(animated: true) { context.coordinator.host = nil }
            }
            return
        }
        if let host = context.coordinator.host {
            host.rootView = content(item)
            return
        }
        let host = UIHostingController(rootView: content(item))
        host.modalPresentationStyle = .formSheet
        let available = controller.view.window?.bounds.size ?? UIScreen.main.bounds.size
        host.preferredContentSize = CGSize(width: min(600, available.width - 48),
                                           height: min(760, available.height - 80))
        context.coordinator.host = host
        controller.present(host, animated: true)
        host.presentationController?.delegate = context.coordinator
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        var host: UIHostingController<Content>?
        var onDismiss: (() -> Void)?
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            host = nil
            onDismiss?()
        }
    }
}
#endif
