import SwiftUI
import UIKit

struct SharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
    let cleanup: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    var onComplete: () -> Void = {}

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onComplete()
        }
        configurePopover(controller)
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {
        configurePopover(controller)
    }

    private func configurePopover(_ controller: UIActivityViewController) {
        guard let popover = controller.popoverPresentationController else { return }
        let anchor = controller.view ?? UIView()
        popover.sourceView = anchor
        popover.sourceRect = CGRect(x: anchor.bounds.midX, y: anchor.bounds.midY, width: 1, height: 1)
        popover.permittedArrowDirections = []
    }
}
