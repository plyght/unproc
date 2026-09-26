import SwiftUI

/// State + math for the vertical zoom scrubber that rises out of the lens
/// button on press-and-hold.
///
/// The track is laid out in points, bottom (0) to top (`length`): each lens
/// stop owns a short flat "detent" band where zoom holds still (so stops feel
/// magnetic), and the ramps between stops are log-linear in zoom. Dragging
/// past either end runs into rubber-band resistance; pull far enough past the
/// bottom and the camera flips to the selfie lens (and, from selfie, pull past
/// the top to flip back).
@MainActor
@Observable
final class ZoomScrubModel {
    // MARK: Tuning

    /// Flat band each lens stop occupies on the track.
    static let detent: CGFloat = 18
    /// Track points per unit of ln(zoom).
    static let pointsPerLog: CGFloat = 72
    /// Raw overshoot needed to flip cameras.
    static let flipDistance: CGFloat = 110
    /// Rubber-band limit: visual overshoot approaches this but never reaches it.
    static let stretchLimit: CGFloat = 54

    // MARK: State

    private(set) var isActive = false
    /// Thumb position on the track (0 … length).
    private(set) var position: CGFloat = 0
    /// Visual rubber-band stretch past an end: negative below, positive above.
    private(set) var stretch: CGFloat = 0
    /// 0 … 1 progress toward flipping cameras.
    private(set) var flipProgress: CGFloat = 0
    private(set) var zoom: CGFloat = 1
    /// Bumped whenever the thumb enters a stop's detent (drives a haptic).
    private(set) var detentTick = 0
    /// Bumped when the flip threshold is crossed (drives a heavy haptic).
    private(set) var flipTick = 0
    /// Bumped every ~0.1 stop of zoom between detents (a whisper of a tick).
    private(set) var fineTick = 0
    /// 1…3 as the rubber band tightens toward a flip; drives rising pulses.
    private(set) var tension = 0
    /// True while scrubbing from the selfie camera (the track only flips back).
    private(set) var isFront = false

    private(set) var stops: [CGFloat] = [1]
    private var startPosition: CGFloat = 0
    private var didFlip = false
    private var lastDetent: Int?
    private var lastFineStep: Int?

    var length: CGFloat {
        guard stops.count > 1 else { return Self.detent }
        var total = Self.detent * CGFloat(stops.count)
        for i in 0..<(stops.count - 1) {
            total += log(stops[i + 1] / stops[i]) * Self.pointsPerLog
        }
        return total
    }

    // MARK: Mapping

    /// Track position of the centre of stop `index`.
    func position(ofStop index: Int) -> CGFloat {
        var s: CGFloat = 0
        for i in 0..<index {
            s += Self.detent + log(stops[i + 1] / stops[i]) * Self.pointsPerLog
        }
        return s + Self.detent / 2
    }

    /// Zoom at a track position.
    func zoom(at s: CGFloat) -> CGFloat {
        guard let first = stops.first else { return 1 }
        var cursor: CGFloat = 0
        for i in stops.indices {
            // Detent band: hold at the stop.
            if s <= cursor + Self.detent { return stops[i] }
            cursor += Self.detent
            guard i + 1 < stops.count else { return stops[i] }
            // Ramp to the next stop.
            let ramp = log(stops[i + 1] / stops[i]) * Self.pointsPerLog
            if s <= cursor + ramp {
                let t = max(s - cursor, 0) / max(ramp, 0.001)
                return stops[i] * pow(stops[i + 1] / stops[i], t)
            }
            cursor += ramp
        }
        return stops.last ?? first
    }

    /// Track position showing `zoom` (centre of its detent for exact stops).
    func position(forZoom zoom: CGFloat) -> CGFloat {
        guard !stops.isEmpty else { return 0 }
        if let i = stops.firstIndex(where: { abs($0 - zoom) / $0 < 0.01 }) {
            return position(ofStop: i)
        }
        var cursor: CGFloat = 0
        for i in 0..<(stops.count - 1) {
            cursor += Self.detent
            if zoom > stops[i], zoom < stops[i + 1] {
                return cursor + log(zoom / stops[i]) * Self.pointsPerLog
            }
            cursor += log(stops[i + 1] / stops[i]) * Self.pointsPerLog
        }
        return zoom <= stops[0] ? Self.detent / 2 : length - Self.detent / 2
    }

    private func detentIndex(at s: CGFloat) -> Int? {
        stops.indices.first { abs(position(ofStop: $0) - s) <= Self.detent / 2 }
    }

    /// iOS-style rubber band: resistance grows the further you pull.
    private static func rubber(_ overshoot: CGFloat) -> CGFloat {
        let c = stretchLimit
        return c * (1 - 1 / (overshoot * 0.55 / c + 1))
    }

    // MARK: Gesture

    func begin(stops: [CGFloat], zoom: CGFloat, isFront: Bool) {
        self.stops = stops.isEmpty ? [1] : stops
        self.isFront = isFront
        self.zoom = zoom
        position = isFront ? 0 : position(forZoom: zoom)
        startPosition = position
        stretch = 0
        flipProgress = 0
        didFlip = false
        tension = 0
        lastDetent = detentIndex(at: position)
        lastFineStep = nil
        isActive = true
    }

    /// `dy` is the drag's vertical translation (negative = finger moved up).
    /// Returns an action for the camera, if any.
    func update(dy: CGFloat) -> Action? {
        guard isActive else { return nil }
        let raw = startPosition - dy
        let upper = length

        if isFront {
            // From selfie: only an upward pull (to flip back) does anything.
            let overshoot = max(raw, 0)
            position = 0
            stretch = Self.rubber(overshoot)
            return flipCheck(overshoot: overshoot, to: .back)
        }

        if raw < 0 {
            position = 0
            stretch = -Self.rubber(-raw)
            zoom = stops.first ?? 1
            return flipCheck(overshoot: -raw, to: .front) ?? .zoom(zoom)
        }
        flipProgress = 0
        tension = 0
        if raw > upper {
            position = upper
            stretch = Self.rubber(raw - upper)
            zoom = stops.last ?? 1
            return .zoom(zoom)
        }
        stretch = 0
        position = raw
        let newZoom = zoom(at: raw)
        if let d = detentIndex(at: raw), d != lastDetent { detentTick += 1 }
        lastDetent = detentIndex(at: raw)
        if lastDetent == nil {
            let step = Int((log(newZoom) / 0.1).rounded(.down))
            if let last = lastFineStep, step != last { fineTick += 1 }
            lastFineStep = step
        } else {
            lastFineStep = nil
        }
        guard abs(newZoom - zoom) / max(zoom, 0.01) > 0.004 else { return nil }
        zoom = newZoom
        return .zoom(newZoom)
    }

    /// Ends the scrub. Values just off a stop snap to it.
    func end() -> Action? {
        defer {
            isActive = false
            stretch = 0
            flipProgress = 0
        }
        guard !didFlip, !isFront else { return nil }
        if let nearest = stops.min(by: { abs(log($0 / zoom)) < abs(log($1 / zoom)) }),
           abs(log(nearest / zoom)) < 0.07, nearest != zoom {
            zoom = nearest
            position = position(forZoom: nearest)
            return .zoom(nearest)
        }
        return nil
    }

    private func flipCheck(overshoot: CGFloat, to side: Action.Side) -> Action? {
        flipProgress = min(overshoot / Self.flipDistance, 1)
        // Rising pulses as it tightens: 25 %, 50 %, 75 % of the way.
        let stage = min(Int(flipProgress * 4), 3)
        if stage != tension { tension = stage }
        guard !didFlip, overshoot >= Self.flipDistance else { return nil }
        didFlip = true
        flipTick += 1
        return .flip(side)
    }

    enum Action: Equatable {
        enum Side { case front, back }
        case zoom(CGFloat)
        case flip(Side)
    }
}

/// The glass track itself: stop labels, a thumb, the live zoom readout, and an
/// elastic end that stretches as you force it toward a camera flip.
struct ZoomTrack: View {
    let model: ZoomScrubModel
    static let width: CGFloat = 46
    private static let inset: CGFloat = 14

    var body: some View {
        let length = model.length
        let below = max(-model.stretch, 0)
        let above = max(model.stretch, 0)
        let trackHeight = model.isFront ? 44 : length + Self.inset * 2

        GlassEffectContainer(spacing: 10) {
            ZStack(alignment: .bottom) {
                // Stop labels.
                if !model.isFront {
                    ForEach(Array(model.stops.enumerated()), id: \.offset) { index, stop in
                        let active = abs(stop - model.zoom) / stop < 0.01
                        Text(ZoomTrack.label(stop))
                            .monoLabel(9, weight: active ? .bold : .medium,
                                       color: active ? Theme.accent : Theme.secondary, uppercase: false)
                            .fixedSize()
                            .offset(y: -(model.position(ofStop: index) + Self.inset - 6))
                    }
                    // Thumb.
                    // Thumb: a short accent tick on the trailing edge.
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: 7, height: 3)
                        .offset(x: Self.width / 2 - 7, y: -(model.position + Self.inset - 1.5))
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(model.flipProgress >= 1 ? Theme.accent : Theme.primary)
                        .padding(.bottom, 13)
                }
            }
            .frame(width: Self.width, height: trackHeight + below + above, alignment: .bottom)
            .glassEffect(.regular.tint(Color.black.opacity(0.2)).interactive(), in: .capsule)
            // The elastic end: the capsule grows past its end as it's forced.
            .offset(y: below)
            .overlay(alignment: .topTrailing) {
                if !model.isFront {
                    // Frame top is fixed; the capsule is drawn `below` lower.
                    readout
                        .offset(x: -(Self.width + 8),
                                y: trackHeight + 2 * below + above - model.position - Self.inset - 13)
                }
            }
            .overlay(alignment: model.isFront ? .topTrailing : .bottomTrailing) {
                flipHint
                    .offset(x: -(Self.width + 8), y: model.isFront ? 6 : below - 8)
            }
        }
        .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.86), value: model.stretch)
    }

    private var readout: some View {
        Text(ZoomTrack.label(model.zoom, precise: true))
            .monoLabel(12, weight: .semibold, uppercase: false)
            .monospacedDigit()
            .contentTransition(.numericText())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(Color.black.opacity(0.2)), in: .capsule)
            .fixedSize()
    }

    @ViewBuilder
    private var flipHint: some View {
        let p = model.flipProgress
        if p > 0.05 {
            Text(model.isFront ? "BACK" : "SELFIE")
                .monoLabel(9, weight: .bold, color: p >= 1 ? Theme.accent : Theme.primary)
                .opacity(Double(p))
                .scaleEffect(0.85 + 0.15 * p, anchor: .trailing)
                .fixedSize()
        }
    }

    static func label(_ zoom: CGFloat, precise: Bool = false) -> String {
        if zoom < 1 {
            return String(format: "%.1f×", zoom).replacingOccurrences(of: "0.", with: ".")
        }
        if abs(zoom.rounded() - zoom) < 0.05 { return "\(Int(zoom.rounded()))×" }
        return String(format: "%.1f×", zoom)
    }
}
