import SwiftUI

// Video mode and self-timer controls: the PHOTO / VIDEO switch, the record
// button, the recording timecode and the self-timer countdown.

// MARK: - Mode switch

/// PHOTO / VIDEO switch between the shutter and the thumbnail: the
/// original rounded-rectangle glass tile (50 × 50, 13pt continuous corners,
/// the same outer size and radius as the thumbnail) with a camera and a
/// video glyph stacked inside. The selected glyph is accent-coloured on a
/// sliding rounded pill (10pt radius, concentric with the tile's 3pt inset).
/// Tap a glyph, or swipe (left / down = VIDEO, right / up = PHOTO).
struct ModeSwitch: View {
    let mode: CaptureMode
    let onSelect: (CaptureMode) -> Void

    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 50
    private static let inset: CGFloat = 3
    private static let corner: CGFloat = 13
    private static let rowHeight: CGFloat = 22   // 2 × 22 + 2 × 3 = 50, the thumbnail's height

    var body: some View {
        VStack(spacing: 0) {
            option(.photo, symbol: "camera.fill")
            option(.video, symbol: "video.fill")
        }
        .padding(Self.inset)
        .frame(width: Self.width)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Self.corner, style: .continuous))
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 10).onEnded { (drag: DragGesture.Value) in
                let dx = drag.translation.width
                let dy = drag.translation.height
                let target: CaptureMode?
                if abs(dx) > abs(dy) {
                    target = dx < -12 ? .video : (dx > 12 ? .photo : nil)
                } else {
                    target = dy > 12 ? .video : (dy < -12 ? .photo : nil)
                }
                if let target, target != mode { select(target) }
            }
        )
        .sensoryFeedback(.selection, trigger: mode)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("modeSwitch")
    }

    private func option(_ option: CaptureMode, symbol: String) -> some View {
        let selected = option == mode
        let pill = RoundedRectangle(cornerRadius: Self.corner - Self.inset, style: .continuous)
        return Button {
            guard !selected else { return }
            select(option)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Theme.accent : Color.white.opacity(0.55))
                .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight)
                .background {
                    if selected {
                        pill
                            .fill(Theme.accent.opacity(0.2))
                            .overlay { pill.strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1) }
                            .matchedGeometryEffect(id: "mode", in: selection)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(Text(option == .photo ? "Photo" : "Video"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(option == .photo ? "mode.photo" : "mode.video")
    }

    private func select(_ target: CaptureMode) {
        withAnimation(reduceMotion ? Theme.fade : Theme.glassSlide) {
            onSelect(target)
        }
    }
}

// MARK: - Record button

/// The shutter in video mode: a glass capsule the size of the photo shutter
/// with a red dot that morphs into a rounded square while recording.
struct RecordButton: View {
    let isRecording: Bool
    var isEnabled: Bool = true
    var width: CGFloat = 132
    var height: CGFloat = 64
    let action: () -> Void

    static let red = Color(red: 1.0, green: 0.23, blue: 0.19)

    var body: some View {
        let dot = height * 0.56
        let square = height * 0.34
        Button(action: action) {
            RoundedRectangle(cornerRadius: isRecording ? 5 : dot / 2, style: .continuous)
                .fill(Self.red)
                .frame(width: isRecording ? square : dot, height: isRecording ? square : dot)
                .frame(width: width, height: height)
                .glassEffect(.regular.interactive(), in: .capsule)
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.94, haptic: true))
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isRecording)
        .opacity(isEnabled ? 1 : 0.35)
        .animation(Theme.fade, value: isEnabled)
        .disabled(!isEnabled)
        .accessibilityLabel(isRecording ? "Stop recording" : "Record")
        .accessibilityValue(isRecording ? "recording" : "stopped")
        .accessibilityIdentifier("shutter")
    }
}

// MARK: - Recording timecode

/// "● 00:12" in a small glass capsule, top centre of the viewfinder.
struct RecordingTimecode: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 0.5)) { (context: TimelineViewDefaultContext) in
            let elapsed = max(context.date.timeIntervalSince(start), 0)
            let dotOn = Int(elapsed * 2) % 2 == 0
            HStack(spacing: 6) {
                Circle()
                    .fill(RecordButton.red)
                    .frame(width: 7, height: 7)
                    .opacity(dotOn ? 1 : 0.25)
                Text(Timecode.string(elapsed))
                    .monoLabel(12, weight: .semibold, color: Theme.primary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular.tint(Color.black.opacity(0.3)), in: .capsule)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording")
        .accessibilityIdentifier("recordingTime")
    }
}

// MARK: - Countdown

/// The self-timer's big accent number in the middle of the viewfinder.
/// Each tick replaces the number (scale + fade), keyed by its value.
struct CountdownNumber: View {
    let value: Int

    var body: some View {
        Text("\(value)")
            .font(Theme.mono(112, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(Theme.accent)
            .shadow(color: Color.black.opacity(0.45), radius: 14)
            .id(value)
            .transition(.asymmetric(
                insertion: .scale(scale: 1.4).combined(with: .opacity),
                removal: .scale(scale: 0.6).combined(with: .opacity)
            ))
            .allowsHitTesting(false)
            .accessibilityLabel("\(value)")
            .accessibilityIdentifier("countdown")
    }
}

// MARK: - Haptics

/// Recording and self-timer haptics.
struct VideoTimerHaptics: ViewModifier {
    let recordStart: Int
    let recordStop: Int
    let countdownTick: Int
    let timerFire: Int

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(.impact(weight: .medium, intensity: 0.8), trigger: recordStart)
            .sensoryFeedback(.impact(weight: .medium, intensity: 0.6), trigger: recordStop)
            .sensoryFeedback(.impact(weight: .light, intensity: 0.5), trigger: countdownTick)
            .sensoryFeedback(.impact(weight: .heavy, intensity: 1), trigger: timerFire)
    }
}
