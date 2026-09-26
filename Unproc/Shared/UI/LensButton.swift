import SwiftUI

/// Bottom-right lens button: the zoom number in a Liquid Glass circle.
///
/// - Tap, press and hold, or start dragging vertically: the glass circle fades
///   away, the number stays where it is, and a vertical ruler appears through
///   it. Drag up to zoom in, down to zoom out; keep forcing past .5× to flip to
///   the selfie camera. Release and the ruler hides as the circle comes back.
///   A plain tap opens the ruler (lingering longer, inviting a slide); a tap
///   while it's out closes it.
///
/// One `DragGesture(minimumDistance: 0)` drives all of it so a hold never
/// also fires a tap and the drag continues seamlessly from the press.
struct LensButton: View {
    let current: Lens?
    let model: ZoomScrubModel
    /// True while the ruler is showing (it lingers briefly after release).
    let isExpanded: Bool
    /// Room below the button's centre the ruler may use (see `ZoomRuler.maxBelow`).
    var rulerMaxBelow: CGFloat = .infinity
    /// Tap with no drag: `true` when the ruler was already out.
    let onTap: (_ whileExpanded: Bool) -> Void
    let onScrubBegin: () -> Void
    let onScrubChange: (CGFloat) -> Void
    let onScrubEnd: () -> Void

    @State private var isPressed = false
    @State private var isScrubbing = false
    @State private var holdTask: Task<Void, Never>?
    @State private var moved = false
    @State private var startedExpanded = false

    static let rulerSize = CGSize(width: 64, height: 232)
    private static let holdDelay: Duration = .milliseconds(260)
    private static let dragToScrub: CGFloat = 8

    private var label: String {
        if isExpanded, !model.isFront { return ZoomDial.label(model.zoom, precise: true) }
        return current?.buttonLabel ?? "—"
    }

    var body: some View {
        ZStack {
            if isExpanded {
                ZoomRuler(model: model, maxBelow: rulerMaxBelow)
                    .frame(width: Self.rulerSize.width, height: Self.rulerSize.height)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            Text(label)
                .monoLabel(current?.isFront == true && !isExpanded ? 11 : 14, weight: .semibold,
                           color: isExpanded ? Theme.accent : Theme.primary,
                           uppercase: !isExpanded)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(Theme.snappy, value: current?.id)
                .frame(width: 52, height: 52)
                // Glass only in the resting state; it melts away for the ruler.
                .glassEffect(isExpanded ? .identity : .regular.interactive(), in: .circle)
        }
        .frame(width: 52, height: 52)
        .contentShape(Circle())
        .scaleEffect(isPressed && !isExpanded ? 0.94 : 1)
        .animation(Theme.press, value: isPressed)
        .animation(Theme.snappy, value: isExpanded)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if !isPressed {
                        isPressed = true
                        moved = false
                        startedExpanded = isExpanded
                        // Ruler already out: grab it straight away.
                        if isExpanded { beginScrub() }
                        holdTask?.cancel()
                        holdTask = Task { @MainActor in
                            try? await Task.sleep(for: Self.holdDelay)
                            guard !Task.isCancelled, isPressed, !isScrubbing else { return }
                            beginScrub()
                        }
                    }
                    if abs(value.translation.height) > 4 { moved = true }
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
                        // A touch on the open ruler that never moved is a tap: close it.
                        if startedExpanded && !moved { onTap(true) }
                    } else {
                        onTap(false)
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
