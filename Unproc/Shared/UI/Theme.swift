import SwiftUI

/// unproc's visual language: pure black, white at a few opacities, one
/// signal-orange accent, and small tracked monospaced uppercase type.
enum Theme {
    // MARK: Colour

    /// Signal orange #FF5A1F — selected values and the shutter. Nothing else.
    static let accent = Color(red: 1.0, green: 90.0 / 255.0, blue: 31.0 / 255.0)
    static let background = Color.black
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.5)
    static let tertiary = Color.white.opacity(0.28)
    /// Translucent panel used by the settings menu.
    static let panel = Color.black.opacity(0.72)

    // MARK: Geometry

    /// Corner radius of the 3:4 viewfinder.
    static let viewfinderCorner: CGFloat = 28
    /// Portrait width / height of the sensor frame.
    static let frameAspect: CGFloat = 3.0 / 4.0

    // MARK: Type

    /// Letter spacing used for all labels.
    static let tracking: CGFloat = 1.1

    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: Motion
    //
    // Critically damped springs everywhere (no overshoot on functional
    // controls), all under 300 ms. Exits are quicker than entrances.

    /// Default UI motion: enters, moves, state changes.
    static let snappy = Animation.spring(response: 0.25, dampingFraction: 1.0)
    /// Exits: the system responding, so it snaps.
    static let exit = Animation.spring(response: 0.18, dampingFraction: 1.0)
    /// Press feedback on every pressable control.
    static let press = Animation.spring(response: 0.2, dampingFraction: 0.8)
    /// Liquid Glass selection moving between options: a touch of give, like
    /// the system's own glass controls.
    static let glassSlide = Animation.spring(response: 0.34, dampingFraction: 0.78)
    /// Opacity-only fades (also the reduce-motion substitute for movement).
    static let fade = Animation.easeOut(duration: 0.18)

    /// Returns `transition`, or a plain fade when Reduce Motion is on.
    static func transition(_ transition: AnyTransition, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : transition
    }

    /// Asymmetric popover transition: scales in from `anchor` (never from 0)
    /// with a slight offset toward the trigger; exits quicker as a plain fade.
    static func popover(anchor: UnitPoint, offsetY: CGFloat = 0, reduceMotion: Bool) -> AnyTransition {
        if reduceMotion {
            return .opacity.animation(fade)
        }
        return .asymmetric(
            insertion: .scale(scale: 0.95, anchor: anchor)
                .combined(with: .opacity)
                .combined(with: .offset(x: 0, y: offsetY))
                .animation(snappy),
            removal: .scale(scale: 0.97, anchor: anchor)
                .combined(with: .opacity)
                .animation(exit)
        )
    }

    /// Fade with a slight blur-in (4 → 0) — masks crossfades between states.
    static var blurFade: AnyTransition {
        .modifier(active: BlurFadeModifier(amount: 1), identity: BlurFadeModifier(amount: 0))
    }

    // MARK: Shutter word

    static let shutterWords = ["shoot", "snap", "take", "now", "click"]
    /// Chosen once per launch (static lets are initialised lazily, exactly once).
    /// Deterministic ("shoot") under `-UNPROC_DEMO` so UI-test screenshots are stable.
    static let shutterWord: String = LaunchArguments.isDemo ? "shoot" : (shutterWords.randomElement() ?? "shoot")
}

/// Launch arguments used by UI tests / screenshot runs.
enum LaunchArguments {
    /// `-UNPROC_DEMO`: deterministic UI (fixed shutter word).
    static let isDemo = ProcessInfo.processInfo.arguments.contains("-UNPROC_DEMO")
    /// `-UNPROC_RESET`: start from default settings.
    static let shouldReset = ProcessInfo.processInfo.arguments.contains("-UNPROC_RESET")

    /// Resets settings once per process when `-UNPROC_RESET` is passed.
    @MainActor
    static func applyResetIfNeeded() {
        guard shouldReset, !didReset else { return }
        didReset = true
        SettingsStore.shared.value = CaptureSettings()
    }

    @MainActor private static var didReset = false
}

struct BlurFadeModifier: ViewModifier {
    let amount: CGFloat
    func body(content: Content) -> some View {
        content
            .blur(radius: 4 * amount)
            .opacity(1 - Double(amount))
    }
}

/// Every pressable control: scales to ~0.96 on touch-down with a quick spring,
/// optionally with a light haptic on press.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    var haptic: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .scaleEffect(pressed ? scale : 1)
            .animation(Theme.press, value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed) { _, isPressed in
                haptic && isPressed
            }
    }
}

extension ButtonStyle where Self == PressableStyle {
    /// Default press feedback (0.96).
    static var pressable: PressableStyle { PressableStyle() }
}

extension View {
    /// Monospaced, uppercase, tracked label styling. Pass `uppercase: false`
    /// for values that must keep their case (e.g. "ƒ1.8" — "ƒ" uppercases to "Ƒ").
    func monoLabel(_ size: CGFloat = 11, weight: Font.Weight = .medium, color: Color = Theme.primary, uppercase: Bool = true) -> some View {
        self
            .font(Theme.mono(size, weight: weight))
            .textCase(uppercase ? .uppercase : nil)
            .tracking(Theme.tracking)
            .foregroundStyle(color)
    }
}

extension Lens {
    /// Label printed on the lens button: "1×", "0.5×", "5×", "FRONT".
    var buttonLabel: String {
        kind == .front ? label : "\(label)×"
    }
}
