import SwiftUI

/// Bottom-right glass lens button.
///
/// - Tap: next lens.
/// - Press and hold (or start dragging vertically): the inline vertical zoom
///   dial appears beside it; drag up to zoom in, down to zoom out, and keep
///   forcing past .5× to flip to the selfie camera.
///
/// One `DragGesture(minimumDistance: 0)` drives all three so a hold never
/// also fires a tap and the drag continues seamlessly from the press.
struct LensButton: View {
    let current: Lens?
    /// Shown instead of the lens label while scrubbing (e.g. "2.4×").
    var liveLabel: String? = nil
    let onTap: () -> Void
    let onScrubBegin: () -> Void
    let onScrubChange: (CGFloat) -> Void
    let onScrubEnd: () -> Void

    @State private var isPressed = false
    @State private var isScrubbing = false
    @State private var holdTask: Task<Void, Never>?

    private static let holdDelay: Duration = .milliseconds(260)
    private static let dragToScrub: CGFloat = 8

    var body: some View {
        Text(liveLabel ?? current?.buttonLabel ?? "—")
            .monoLabel(current?.isFront == true && liveLabel == nil ? 11 : 14, weight: .semibold, uppercase: liveLabel == nil)
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(Theme.snappy, value: current?.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(isScrubbing ? .regular.tint(Theme.accent.opacity(0.22)).interactive() : .regular.interactive(),
                         in: .circle)
            .contentShape(Circle())
            .scaleEffect(isPressed ? 0.94 : 1)
            .animation(Theme.press, value: isPressed)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if !isPressed {
                            isPressed = true
                            holdTask?.cancel()
                            holdTask = Task { @MainActor in
                                try? await Task.sleep(for: Self.holdDelay)
                                guard !Task.isCancelled, isPressed, !isScrubbing else { return }
                                beginScrub()
                            }
                        }
                        if !isScrubbing, abs(value.translation.height) > Self.dragToScrub {
                            beginScrub()
                        }
                        if isScrubbing {
                            onScrubChange(value.translation.height)
                        }
                    }
                    .onEnded { _ in
                        holdTask?.cancel()
                        holdTask = nil
                        isPressed = false
                        if isScrubbing {
                            isScrubbing = false
                            onScrubEnd()
                        } else {
                            onTap()
                        }
                    }
            )
            .sensoryFeedback(.impact(weight: .light), trigger: isScrubbing) { _, new in new }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Lens \(current?.buttonLabel ?? "")")
            .accessibilityHint("Hold, then drag up to zoom in or down to zoom out")
            .accessibilityIdentifier("lensButton")
    }

    private func beginScrub() {
        guard !isScrubbing else { return }
        isScrubbing = true
        onScrubBegin()
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
