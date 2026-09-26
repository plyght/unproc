import SwiftUI

/// Tiny top-right badge: look code (accent), output format, and PRO / 2×EXP tags.
/// Tapping it opens the settings menu.
struct StatusBadge: View {
    let settings: CaptureSettings
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(LookLibrary.look(id: settings.lookID).code)
                    .monoLabel(10, weight: .semibold, color: Theme.accent)
                HStack(spacing: 4) {
                    if settings.doubleExposure { tag("2×EXP") }
                    if settings.proMode { tag("PRO") }
                    Text(settings.output == .raw ? "RAW" : "JPEG")
                        .monoLabel(10, weight: .medium, color: Theme.primary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.black.opacity(0.32))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .animation(Theme.snappy, value: settings)
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("statusBadge")
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .monoLabel(7, weight: .bold, color: .black)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(0.85))
            }
    }
}
