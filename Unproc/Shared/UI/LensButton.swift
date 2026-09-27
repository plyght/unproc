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
    /// Latest drag translation, and the translation at the moment scrubbing
    /// began: the ruler moves by travel *since* then, so the 8 pt it takes to
    /// recognise a drag (or any creep during a hold) doesn't push the thumb
    /// off the stop it started on.
    @State private var lastTranslation: CGFloat = 0
    @State private var scrubOrigin: CGFloat = 0

    static let rulerSize = CGSize(width: 64, height: 232)
    /// Touch target while the ruler is out: wider and taller than the drawn
    /// ruler so it can be grabbed anywhere on or near it. 104 pt wide stays
    /// ~25 pt clear of the shutter on the narrowest phones (and on the outer
    /// side just reaches the screen edge), in either handedness.
    static let rulerHitSize = CGSize(width: 104, height: 264)
    /// Invisible margin around the resting 52 pt circle (64 pt target).
    private static let buttonHitOutset: CGFloat = 6
    private static let holdDelay: Duration = .milliseconds(260)
    private static let dragToScrub: CGFloat = 8

    private var label: String {
        if isExpanded, !model.isFront { return ZoomDial.label(model.displayZoom, precise: true) }
        return current?.buttonLabel ?? "—"
    }

    /// Front camera: an icon (the word FRONT doesn't fit between the ruler's marks).
    private var showsFrontIcon: Bool {
        current?.isFront == true && !(isExpanded && !model.isFront)
    }

    @ViewBuilder
    private var labelContent: some View {
        if showsFrontIcon {
            Image(systemName: "person.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isExpanded ? Theme.accent : Theme.primary)
                .transition(.opacity)
        } else {
            Text(label)
                .monoLabel(14, weight: .semibold,
                           color: isExpanded ? Theme.accent : Theme.primary,
                           uppercase: !isExpanded)
                .monospacedDigit()
                .contentTransition(.numericText())
                .transition(.opacity)
        }
    }

    var body: some View {
        ZStack {
            if isExpanded {
                ZoomRuler(model: model, maxBelow: rulerMaxBelow)
                    // Widens a touch while dragging so the loupe has room.
                    .frame(width: Self.rulerSize.width + (isScrubbing ? 14 : 0), height: Self.rulerSize.height)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            labelContent
                .animation(Theme.snappy, value: current?.id)
                // The number grows while your finger is on it…
                .scaleEffect(isScrubbing ? 1.42 : 1, anchor: .center)
                .animation(.spring(response: 0.3, dampingFraction: 0.78), value: isScrubbing)
                // …and pops as it lands on a lens stop.
                .keyframeAnimator(initialValue: 1.0, trigger: model.detentTick) { content, scale in
                    content.scaleEffect(scale)
                } keyframes: { _ in
                    KeyframeTrack {
                        SpringKeyframe(1.14, duration: 0.08, spring: .snappy)
                        SpringKeyframe(1.0, duration: 0.26, spring: .smooth)
                    }
                }
                .frame(width: 52, height: 52)
                // Glass only in the resting state; it melts away for the ruler.
                .glassEffect(isExpanded ? .identity : .regular.interactive(), in: .circle)
        }
        .frame(width: 52, height: 52)
        // Transparent/glass regions don't hit-test on their own: an explicit
        // shape, reaching past the 52 pt frame, so the whole ruler area grabs.
        .contentShape(LensHitShape(
            expandedSize: isExpanded ? Self.rulerHitSize : nil,
            outset: Self.buttonHitOutset
        ))
        .scaleEffect(isPressed && !isExpanded ? 0.94 : 1)
        .animation(Theme.press, value: isPressed)
        .animation(Theme.snappy, value: isExpanded)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    lastTranslation = value.translation.height
                    if !isPressed {
                        isPressed = true
                        moved = false
                        startedExpanded = isExpanded
                        // Ruler already out: grab it straight away.
                        if isExpanded { beginScrub(at: value.translation.height) }
                        holdTask?.cancel()
                        holdTask = Task { @MainActor in
                            try? await Task.sleep(for: Self.holdDelay)
                            guard !Task.isCancelled, isPressed, !isScrubbing else { return }
                            beginScrub(at: lastTranslation)
                        }
                    }
                    if abs(value.translation.height) > 4 { moved = true }
                    if !isScrubbing, abs(value.translation.height) > Self.dragToScrub {
                        beginScrub(at: value.translation.height)
                    }
                    if isScrubbing {
                        onScrubChange(value.translation.height - scrubOrigin)
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

    private func beginScrub(at translation: CGFloat) {
        guard !isScrubbing else { return }
        scrubOrigin = translation
        isScrubbing = true
        onScrubBegin()
    }
}

/// Hit area of the lens button: the circle plus a small margin at rest; a
/// rectangle centred on it (larger than the ruler) while the ruler is out.
private struct LensHitShape: Shape {
    var expandedSize: CGSize?
    var outset: CGFloat

    func path(in rect: CGRect) -> Path {
        if let size = expandedSize {
            return Path(CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                               width: size.width, height: size.height))
        }
        return Path(ellipseIn: rect.insetBy(dx: -outset, dy: -outset))
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
