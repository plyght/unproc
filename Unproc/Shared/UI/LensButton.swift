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
            .glassEffect(.regular.interactive(), in: .circle)
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

/// Liquid Glass capsule listing every lens; the current one sits under a
/// glass selection that slides across as you pick. Presented growing out of
/// the lens button (see `CameraScreen`).
struct LensPicker: View {
    static let height: CGFloat = 48

    let lenses: [Lens]
    let current: Lens?
    let onSelect: (Lens) -> Void

    var body: some View {
        GlassSegmented(
            segments: lenses.map {
                GlassSegment(id: $0.id, label: $0.buttonLabel, accessibilityID: "lens.\($0.id)",
                             fontSize: $0.isFront ? 10 : 12)
            },
            selectedID: current?.id,
            spacing: 0,
            minHeight: Self.height - 10,
            horizontalPadding: 11,
            onSelect: { id in
                if let lens = lenses.first(where: { $0.id == id }) { onSelect(lens) }
            }
        )
        .padding(5)
        .glassEffect(.regular.tint(Color.black.opacity(0.25)), in: .capsule)
    }
}
