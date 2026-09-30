import SwiftUI
import os

/// Bottom-right lens button: the zoom number in a Liquid Glass circle.
///
/// - Tap, press and hold, or start dragging vertically: the glass circle fades
///   away, the number stays where it is, and a vertical ruler appears through
///   it. Drag up to zoom in, down to zoom out; keep forcing past .5× to flip to
///   the selfie camera (and from the selfie camera, up past its longest stop to
///   flip back). Release and the ruler hides as the circle comes back.
///   A plain tap opens the ruler (lingering longer, inviting a slide); a tap
///   while it's out closes it. On a selfie camera with two framings a tap
///   swaps between them instead (see `CameraScreen`).
///
/// One `DragGesture(minimumDistance: 0)` drives all of it so a hold never
/// also fires a tap and the drag continues seamlessly from the press.
struct LensButton: View {
    let current: Lens?
    let model: ZoomScrubModel
    /// True while the ruler is showing (it lingers briefly after release).
    let isExpanded: Bool
    /// The selfie camera has more than one framing (square Center Stage
    /// sensor): the button shows which one next to the selfie icon.
    var frontHasStops: Bool = false
    /// Room below the button's centre the ruler may use (see `ZoomRuler.maxBelow`).
    var rulerMaxBelow: CGFloat = .infinity
    /// Global y of the screen's bottom edge: how far a drag can still go down.
    var screenBottom: CGFloat = .infinity
    /// Tap with no drag: `true` when the ruler was already out.
    let onTap: (_ whileExpanded: Bool) -> Void
    /// A scrub starts; the argument is how far the finger can still travel
    /// down before it runs out of screen.
    let onScrubBegin: (_ roomBelow: CGFloat) -> Void
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
    @State private var lastLocationY: CGFloat = 0
    @State private var scrubOrigin: CGFloat = 0
    /// True for as long as the system considers the touch alive. When a drag
    /// is cancelled (the view hierarchy changing under it as a flip swaps
    /// cameras, a system gesture…) `onEnded` never runs; this resetting is
    /// how we notice, so a scrub is never left half-open — which used to
    /// leave `isPressed` stuck and every later drag on the button dead.
    @GestureState private var touchAlive = false

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
    /// A finger can't usefully drag closer than this to the bottom edge (the
    /// home-indicator zone; the thumb's pad sits below its touch point).
    private static let bottomEdgeMargin: CGFloat = 24

    /// The ruler is out with a scale: the button shows the live readout.
    private var showsReadout: Bool { isExpanded && model.showsScale }

    private var label: String {
        if showsReadout { return ZoomDial.label(model.displayZoom, precise: true) }
        return current?.buttonLabel ?? "—"
    }

    /// Front camera: an icon (the word FRONT doesn't fit between the ruler's marks).
    private var showsFrontIcon: Bool {
        current?.isFront == true && !showsReadout
    }

    /// Which selfie framing is on (".8" / "1"), when there's a choice.
    private var frontZoomText: String? {
        guard frontHasStops, let current, current.isFront else { return nil }
        return ZoomDial.label(current.zoom).replacingOccurrences(of: "\u{00D7}", with: "")
    }

    @ViewBuilder
    private var labelContent: some View {
        if showsFrontIcon {
            HStack(spacing: 2) {
                Image(systemName: "person.fill")
                    .font(.system(size: frontZoomText == nil ? 14 : 11, weight: .semibold))
                if let text = frontZoomText {
                    Text(text)
                        .monoLabel(12, weight: .semibold,
                                   color: isExpanded ? Theme.accent : Theme.primary,
                                   uppercase: false)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
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
                // Not interactive mid-scrub: a flip folds the ruler while the
                // finger is still down, and interactive glass coming back under
                // it must not take the touch over.
                .glassEffect(isExpanded ? .identity : .regular.interactive(!isScrubbing), in: .circle)
        }
        .frame(width: 52, height: 52)
        // Transparent/glass regions don't hit-test on their own: an explicit
        // shape, reaching past the 52 pt frame, so the whole ruler area grabs.
        // It stays large for the whole scrub (even once a flip has folded the
        // ruler) so the hit area never shrinks out from under the finger.
        .contentShape(LensHitShape(
            expandedSize: isExpanded || isScrubbing ? Self.rulerHitSize : nil,
            outset: Self.buttonHitOutset
        ))
        .scaleEffect(isPressed && !isExpanded && !isScrubbing ? 0.94 : 1)
        .animation(Theme.press, value: isPressed)
        .animation(Theme.snappy, value: isExpanded)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .updating($touchAlive) { _, alive, _ in alive = true }
                .onChanged { value in
                    lastTranslation = value.translation.height
                    lastLocationY = value.location.y
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
                    finishTouch(cancelled: false)
                }
        )
        .onChange(of: touchAlive) { _, alive in
            guard !alive, isPressed else { return }
            // Either the normal end (whose `onEnded` may still be on its way)
            // or a cancellation (it never comes): look again once a normal end
            // has had its chance.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                guard isPressed, !touchAlive else { return }
                Log.ui.notice("ui: lens gesture cancelled mid-touch (scrubbing=\(isScrubbing, privacy: .public)); ending it")
                finishTouch(cancelled: true)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: isScrubbing) { _, new in new }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Hold, then drag up to zoom in or down to zoom out")
        .accessibilityIdentifier("lensButton")
    }

    private var accessibilityText: String {
        var text = "Lens \(current?.buttonLabel ?? "")"
        if let zoom = frontZoomText { text += " \(zoom)\u{00D7}" }
        return text
    }

    private func beginScrub(at translation: CGFloat) {
        guard !isScrubbing else { return }
        scrubOrigin = translation
        isScrubbing = true
        onScrubBegin(max(screenBottom - Self.bottomEdgeMargin - lastLocationY, 0))
    }

    /// The touch is over: lifted (`cancelled` false) or taken away by the system.
    private func finishTouch(cancelled: Bool) {
        guard isPressed else { return }
        holdTask?.cancel()
        holdTask = nil
        isPressed = false
        if isScrubbing {
            isScrubbing = false
            onScrubEnd()
            // A touch on the open ruler that never moved is a tap: close it.
            if !cancelled, startedExpanded, !moved { onTap(true) }
        } else if !cancelled {
            onTap(false)
        }
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
