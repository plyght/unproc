import SwiftUI
import UIKit

/// Invisible view that becomes first responder and reports device shakes.
/// Extension-safe: plain UIResponder motion events, no UIApplication.
struct ShakeDetector: UIViewRepresentable {
    var onShake: () -> Void

    func makeUIView(context: Context) -> ShakeResponderView {
        let view = ShakeResponderView()
        view.backgroundColor = .clear
        view.onShake = onShake
        return view
    }

    func updateUIView(_ uiView: ShakeResponderView, context: Context) {
        uiView.onShake = onShake
        uiView.claimFirstResponderSoon()
    }
}

final class ShakeResponderView: UIView {
    var onShake: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        claimFirstResponderSoon()
    }

    func claimFirstResponderSoon() {
        Task { @MainActor [weak self] in
            guard let self, self.window != nil, !self.isFirstResponder else { return }
            _ = self.becomeFirstResponder()
        }
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            onShake?()
        } else {
            super.motionEnded(motion, with: event)
        }
    }
}
