import SwiftUI

/// The big accent pill with one lowercase word ("shoot", "snap", …).
struct ShutterButton: View {
    var word: String = Theme.shutterWord
    var isEnabled: Bool = true
    /// Dims the word slightly while earlier presses are still developing.
    var isBusy: Bool = false
    var width: CGFloat = 132
    var height: CGFloat = 64
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(word)
                .font(Theme.mono(height * 0.32, weight: .bold))
                .foregroundStyle(Color.black.opacity(isBusy ? 0.55 : 1))
                .animation(Theme.fade, value: isBusy)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: width, height: height)
                .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.94, haptic: true))
        .opacity(isEnabled ? 1 : 0.35)
        .animation(Theme.fade, value: isEnabled)
        .disabled(!isEnabled)
        .accessibilityLabel("Shutter")
        .accessibilityIdentifier("shutter")
    }
}
