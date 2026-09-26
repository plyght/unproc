import SwiftUI

/// Bottom-right lens label. Tap cycles lenses, long-press opens `LensPicker`.
///
/// Built from tap + long-press gestures (not a `Button`) so a long press
/// never also fires the tap action on release; press feedback comes from
/// `onPressingChanged`, so it still responds on touch-down.
struct LensButton: View {
    let current: Lens?
    let onTap: () -> Void
    let onLongPress: () -> Void

    @State private var isPressed = false

    init(current: Lens?, onTap: @escaping () -> Void, onLongPress: @escaping () -> Void) {
        self.current = current
        self.onTap = onTap
        self.onLongPress = onLongPress
    }

    var body: some View {
        Text(current?.buttonLabel ?? "—")
            .monoLabel(current?.isFront == true ? 11 : 14, weight: .semibold)
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(Theme.snappy, value: current?.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            }
            .contentShape(Circle())
            .scaleEffect(isPressed ? 0.96 : 1)
            .animation(Theme.press, value: isPressed)
            .onTapGesture(perform: onTap)
            .onLongPressGesture(minimumDuration: 0.35, perform: onLongPress, onPressingChanged: { pressing in
                isPressed = pressing
            })
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Lens \(current?.buttonLabel ?? "")")
            .accessibilityAction(named: "Choose lens", onLongPress)
            .accessibilityIdentifier("lensButton")
    }
}

/// Small Liquid Glass capsule listing every lens. Presented scaling out of the
/// lens button (see `CameraScreen`).
struct LensPicker: View {
    static let height: CGFloat = 44

    let lenses: [Lens]
    let current: Lens?
    let onSelect: (Lens) -> Void

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 2) {
                ForEach(lenses) { lens in
                    let selected = lens.id == current?.id
                    Button {
                        onSelect(lens)
                    } label: {
                        Text(lens.buttonLabel)
                            .monoLabel(lens.isFront ? 10 : 12, weight: .semibold,
                                       color: selected ? Theme.accent : Theme.primary)
                            .frame(minWidth: 44, minHeight: Self.height - 4)
                            .padding(.horizontal, 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier("lens.\(lens.id)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
    }
}
