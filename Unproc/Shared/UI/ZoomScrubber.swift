import SwiftUI

/// State + math for the zoom dial that appears when the lens button is held.
///
/// The scale is laid out in points, from 0 (widest) to `length` (longest): each lens
/// stop owns a flat "detent" band where zoom holds exactly at the stop (so stops
/// feel magnetic), and the ramps between stops are log-linear in zoom, free of
/// any resistance, so every value in between (1.2×, 1.3×, …) is reachable.
/// Dragging past either end stop runs into rubber-band resistance; pull
/// `flipThreshold` past the widest back stop and the camera flips to the
/// selfie camera (and, from selfie, the same pull past its longest stop flips
/// back). Overshoot is measured from the end stop's *centre* — not from where
/// the drag began, and not from the outer edge of the stop's detent band — so
/// the pull needed is the same whichever stop the drag started on, and the
/// band doesn't swallow part of it. One flip per gesture at most; after it the
/// rest of the drag is ignored (it belongs to the old camera).
///
/// The front camera has its own stops (the square Center Stage sensor's wide
/// and standard framings); with a single front stop the scale is hidden and
/// only the flip back remains.
///
/// Landing on a stop:
/// - While dragging, anywhere inside a stop's band reads exactly the stop, with
///   a detent tick on entering. The band's "captured" state has a little
///   hysteresis so a finger resting on its edge doesn't chatter the haptic.
/// - On release, the last few points of travel (lift-off jitter: the finger
///   rolls as it leaves the glass) are ignored, then anything within
///   `releaseZone` of a stop settles exactly on it; any other value is kept,
///   rounded to 0.1× so it matches what the readout showed.
@MainActor
@Observable
final class ZoomScrubModel {
    // MARK: Tuning

    /// Flat band each lens stop occupies on the track (±13 pt of finger travel
    /// reads exactly the stop).
    static let detent: CGFloat = 26
    /// Once captured by a stop, the finger has to go this far past the band's
    /// edge before the stop lets go (for the haptic / captured state; the zoom
    /// itself is continuous at the edge, so it never jumps).
    static let detentHysteresis: CGFloat = 5
    /// Release zone, in |ln(zoom / stop)|: a release within ~±7 % of a stop
    /// settles exactly on it (1.07× → 1×; 1.1× and beyond stay put).
    static let releaseZone: CGFloat = 0.07
    /// Lift-off jitter filter: at release, if the finger moved no more than
    /// `liftOffJitter` points over the last `liftOffWindow` seconds, the
    /// position from before that window is used instead of the final sample.
    static let liftOffWindow: TimeInterval = 0.06
    static let liftOffJitter: CGFloat = 6
    /// Track points per unit of ln(zoom).
    static let pointsPerLog: CGFloat = 72
    /// Raw overshoot past the end stop's centre needed to flip cameras.
    static let flipDistance: CGFloat = 56
    /// The shortest the flip pull gets when the finger has little room left
    /// (the lens button sits near the bottom of the screen): below this an
    /// accidental overshoot could flip.
    static let minFlipDistance: CGFloat = 34
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
    /// True while showing the selfie camera's stops (its flip goes up, to the back).
    private(set) var isFront = false
    /// Whether this gesture may flip cameras at all (not while recording, not
    /// when the other camera doesn't exist). Without it the ends are plain
    /// rubber bands: no tension, no hint, no flip.
    private(set) var canFlip = true
    /// Overshoot that flips during the current gesture (`flipDistance`, less
    /// when the finger would run out of screen first).
    private(set) var flipThreshold: CGFloat = ZoomScrubModel.flipDistance

    private(set) var stops: [CGFloat] = [1]
    /// Thumb position when the current scrub began.
    private(set) var startPosition: CGFloat = 0
    /// A flip has fired during the current gesture.
    private(set) var didFlip = false
    private var lastDetent: Int?
    private var lastFineStep: Int?

    private struct Sample {
        let time: TimeInterval
        let raw: CGFloat
    }
    /// Recent raw track positions (for the lift-off jitter filter). Samples only
    /// arrive when the finger moves, so this is capped by count, not age: a
    /// finger that rested still keeps its last sample as the reference.
    @ObservationIgnored private var samples: [Sample] = []
    private static let maxSamples = 32

    var length: CGFloat {
        guard stops.count > 1 else { return Self.detent }
        var total = Self.detent * CGFloat(stops.count)
        for i in 0..<(stops.count - 1) {
            total += log(stops[i + 1] / stops[i]) * Self.pointsPerLog
        }
        return total
    }

    /// There's a scale to show (a single selfie stop has none: only the flip).
    var showsScale: Bool { stops.count > 1 }

    /// Track positions of the widest and longest stops' centres: the thumb
    /// never goes past them; beyond is rubber band (and the flip).
    var lowestStopPosition: CGFloat { position(ofStop: 0) }
    var highestStopPosition: CGFloat { position(ofStop: max(stops.count - 1, 0)) }

    /// What the readout shows: while dragging, the value a release here would
    /// settle on (so "1.1×" never turns into 1× on lift, or vice versa).
    var displayZoom: CGFloat {
        isActive ? Self.settle(zoom, stops: stops) : zoom
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

    /// The stop holding the thumb at `s`: inside a band, that stop; just
    /// outside the band it was captured by (within the hysteresis), still that.
    private func capturedStop(at s: CGFloat) -> Int? {
        if let d = detentIndex(at: s) { return d }
        if let last = lastDetent, stops.indices.contains(last),
           abs(position(ofStop: last) - s) <= Self.detent / 2 + Self.detentHysteresis {
            return last
        }
        return nil
    }

    /// Where a zoom value comes to rest on release: exactly on a stop within
    /// `releaseZone`, otherwise rounded to 0.1× (clamped to the stops).
    static func settle(_ zoom: CGFloat, stops: [CGFloat]) -> CGFloat {
        guard let lo = stops.first, let hi = stops.last, zoom.isFinite else { return zoom }
        let z = min(max(zoom, lo), hi)
        if let nearest = stops.min(by: { abs(log($0 / z)) < abs(log($1 / z)) }),
           abs(log(nearest / z)) <= releaseZone {
            return nearest
        }
        let rounded = min(max((z * 10).rounded() / 10, lo), hi)
        return stops.first { abs($0 - rounded) / $0 < 0.01 } ?? rounded
    }

    /// iOS-style rubber band: resistance grows the further you pull.
    private static func rubber(_ overshoot: CGFloat) -> CGFloat {
        let c = stretchLimit
        return c * (1 - 1 / (overshoot * 0.55 / c + 1))
    }

    // MARK: Gesture

    /// Pinch-to-zoom: sets the zoom directly (clamped to the stops), with a
    /// little magnetism at each lens stop and the same detent haptic.
    /// Returns the zoom to apply.
    func pinch(to requested: CGFloat) -> CGFloat {
        guard let lo = stops.first, let hi = stops.last else { return requested }
        var z = min(max(requested, lo), hi)
        let nearest = stops.min { abs(log($0 / z)) < abs(log($1 / z)) }
        var onStop: Int?
        if let nearest, abs(log(nearest / z)) < 0.04 {
            z = nearest
            onStop = stops.firstIndex(of: nearest)
        }
        if let onStop, onStop != lastDetent { detentTick += 1 }
        lastDetent = onStop
        zoom = z
        position = position(forZoom: z)
        return z
    }

    /// Shows the scale at `zoom` without starting a drag (e.g. after a tap).
    func present(stops: [CGFloat], zoom: CGFloat, isFront: Bool) {
        self.stops = stops.isEmpty ? [1] : stops
        self.isFront = isFront
        self.zoom = zoom
        position = position(forZoom: zoom)
        stretch = 0
        flipProgress = 0
        tension = 0
    }

    /// Starts a drag. `flipRoom` is how far the finger can still travel toward
    /// the flip (down, for the back camera) before the screen runs out: when
    /// reaching the widest stop and then pulling `flipDistance` past it
    /// wouldn't fit, the flip pull is shortened (never below
    /// `minFlipDistance`) so it stays reachable in one gesture.
    func begin(stops: [CGFloat], zoom: CGFloat, isFront: Bool, canFlip: Bool = true,
               flipRoom: CGFloat = .infinity) {
        self.stops = stops.isEmpty ? [1] : stops
        self.isFront = isFront
        self.canFlip = canFlip
        self.zoom = zoom
        position = position(forZoom: zoom)
        startPosition = position
        stretch = 0
        flipProgress = 0
        didFlip = false
        tension = 0
        lastDetent = detentIndex(at: position)
        lastFineStep = nil
        samples.removeAll()
        // Travel from here to the end stop the flip pulls past.
        let travel = isFront ? max(highestStopPosition - position, 0) : max(position - lowestStopPosition, 0)
        if flipRoom.isFinite {
            flipThreshold = min(max(flipRoom - travel, Self.minFlipDistance), Self.flipDistance)
        } else {
            flipThreshold = Self.flipDistance
        }
        isActive = true
    }

    /// `dy` is the drag's vertical translation since the scrub began (negative
    /// = finger moved up); `now` is the sample's time (for the lift-off filter).
    /// Returns an action for the camera, if any.
    func update(dy: CGFloat, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Action? {
        // After a flip the rest of this drag belongs to the old camera: ignore it
        // (otherwise it would zoom the new camera, or flip straight back).
        guard isActive, !didFlip else { return nil }
        let raw = startPosition - dy
        samples.append(Sample(time: now, raw: raw))
        if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }

        let lo = lowestStopPosition
        let hi = highestStopPosition
        if raw < lo {
            // Past the widest stop: hold it, rubber band; on the back camera
            // this is the pull toward the selfie camera.
            position = lo
            stretch = -Self.rubber(lo - raw)
            lastFineStep = nil
            if !isFront, canFlip {
                if let flip = flipCheck(overshoot: lo - raw, to: .front) { return flip }
            } else {
                resetTension()
            }
            return pinToEnd(stop: 0)
        }
        if raw > hi {
            // Past the longest stop; from the selfie camera, the pull back.
            position = hi
            stretch = Self.rubber(raw - hi)
            lastFineStep = nil
            if isFront, canFlip {
                if let flip = flipCheck(overshoot: raw - hi, to: .back) { return flip }
            } else {
                resetTension()
            }
            return pinToEnd(stop: stops.count - 1)
        }
        resetTension()
        stretch = 0
        position = raw
        let newZoom = zoom(at: raw)
        let captured = capturedStop(at: raw)
        if let d = captured, d != lastDetent { detentTick += 1 }
        lastDetent = captured
        if captured == nil {
            let step = Int((log(newZoom) / 0.1).rounded(.down))
            if let last = lastFineStep, step != last { fineTick += 1 }
            lastFineStep = step
        } else {
            lastFineStep = nil
        }
        // Always land exactly on a stop (the 0.4 % filter below would otherwise
        // leave the camera a hair off it when easing into a band).
        let reachedStop = newZoom != zoom && stops.contains(newZoom)
        guard reachedStop || abs(newZoom - zoom) / max(zoom, 0.01) > 0.004 else { return nil }
        zoom = newZoom
        return .zoom(newZoom)
    }

    /// The thumb is pinned on an end stop: zoom exactly there (reported once,
    /// not on every frame of the stretch), ticking if it just arrived.
    private func pinToEnd(stop index: Int) -> Action? {
        guard stops.indices.contains(index) else { return nil }
        if lastDetent != index { detentTick += 1 }
        lastDetent = index
        let stop = stops[index]
        guard stop != zoom else { return nil }
        zoom = stop
        return .zoom(stop)
    }

    private func resetTension() {
        if flipProgress != 0 { flipProgress = 0 }
        if tension != 0 { tension = 0 }
    }

    /// Ends the scrub: ignores lift-off jitter, then settles exactly on a stop
    /// within `releaseZone`, or keeps the value rounded to 0.1×. A release
    /// short of the flip just springs back (the stretch returns to 0).
    func end(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Action? {
        defer {
            isActive = false
            stretch = 0
            flipProgress = 0
            tension = 0
            samples.removeAll()
        }
        guard !didFlip else { return nil }
        let raw = settledRaw(at: now) ?? startPosition
        // Never moved (a tap or hold on the ruler): leave the zoom as it was,
        // even if it's an off-stop value from a pinch.
        guard abs(raw - startPosition) >= 0.5 else {
            position = startPosition
            let original = zoom(at: startPosition)
            guard abs(original - zoom) > max(zoom, 0.01) * 1e-4 else { return nil }
            zoom = original
            return .zoom(original)
        }
        let s = min(max(raw, lowestStopPosition), highestStopPosition)
        let settled = Self.settle(zoom(at: s), stops: stops)
        position = position(forZoom: settled)
        if let i = stops.firstIndex(of: settled) {
            // Clicking onto a stop on release gets the same tick as dragging in.
            if i != lastDetent { detentTick += 1 }
            lastDetent = i
        } else {
            lastDetent = nil
        }
        let changed = abs(settled - zoom) > max(zoom, 0.01) * 1e-4
        zoom = settled
        return changed ? .zoom(settled) : nil
    }

    /// The finger's track position at release with lift-off jitter removed: if
    /// the last `liftOffWindow` of the drag moved only a couple of points, the
    /// position from just before it.
    private func settledRaw(at now: TimeInterval) -> CGFloat? {
        guard let last = samples.last else { return nil }
        let cutoff = now - Self.liftOffWindow
        let reference = samples.last(where: { $0.time <= cutoff }) ?? samples[0]
        return abs(last.raw - reference.raw) <= Self.liftOffJitter ? reference.raw : last.raw
    }

    private func flipCheck(overshoot: CGFloat, to side: Action.Side) -> Action? {
        let threshold = max(flipThreshold, 1)
        let progress = min(overshoot / threshold, 1)
        if progress != flipProgress { flipProgress = progress }
        // Rising pulses as it tightens: 25 %, 50 %, 75 % of the way.
        let stage = min(Int(progress * 4), 3)
        if stage != tension { tension = stage }
        guard !didFlip, overshoot >= threshold else { return nil }
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

/// The ruler that appears through the lens button while zooming: a plain
/// vertical scale (no glass) that slides past the button's own zoom number,
/// which stays put in the middle. Higher zoom sits *below* the number, so
/// pulling the scale up (finger up) brings it in. Forcing below .5× opens a
/// gap above the number where "SELFIE" fades in.
struct ZoomRuler: View {
    let model: ZoomScrubModel
    /// How far below the centre the ruler may draw before fading out (it stops
    /// at the image's bottom edge in 16:9, where the button floats over it).
    var maxBelow: CGFloat = .infinity

    var body: some View {
        ZStack {
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .mask {
                GeometryReader { proxy in
                    let h = proxy.size.height
                    let below = min(maxBelow, h / 2)
                    let fade = min(h * 0.22, max(below * 0.6, 10))
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: h * 0.22)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: fade)
                    }
                    .frame(height: max(h / 2 + below, h * 0.22 + fade))
                }
            }

            flipHint
        }
        .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.86), value: model.stretch)
        .allowsHitTesting(false)
    }

    private func y(for trackPosition: CGFloat, centre: CGFloat) -> CGFloat {
        centre + (trackPosition - model.position) - model.stretch
    }

    /// Loupe: how much an item `d` points from the centre is magnified. Strong
    /// while dragging, gentle when the ruler is just showing.
    private func magnification(at d: CGFloat) -> CGFloat {
        let strength: CGFloat = model.isActive ? 0.95 : 0.35
        return 1 + strength * exp(-pow(d / 46, 2))
    }

    /// Items brighten toward the centre.
    private func brightness(at d: CGFloat) -> Double {
        Double(0.22 + 0.68 * exp(-pow(d / 70, 2)))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let cy = size.height / 2
        let cx = size.width / 2
        // Keep the (growing) readout clear.
        let clearance: CGFloat = model.isActive ? 20 : 16

        // Centre marks either side of the readout; they reach in while dragging.
        let markLength: CGFloat = model.isActive ? 8 : 5
        for side in [-1.0, 1.0] {
            var mark = Path()
            let x0 = cx + CGFloat(side) * (size.width / 2 - 2)
            mark.move(to: CGPoint(x: x0, y: cy))
            mark.addLine(to: CGPoint(x: x0 - CGFloat(side) * markLength, y: cy))
            context.stroke(mark, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }

        // A single selfie stop has no scale: just the marks (and the flip hint).
        guard model.showsScale else { return }
        let stops = model.stops

        // Minor ticks: 8 per gap between stops, evenly spaced in log zoom.
        for i in 0..<max(stops.count - 1, 0) {
            for step in 1..<8 {
                let z = stops[i] * pow(stops[i + 1] / stops[i], CGFloat(step) / 8)
                let py = y(for: model.position(forZoom: z), centre: cy)
                let d = abs(py - cy)
                guard py > -4, py < size.height + 4, d > clearance else { continue }
                let half = 4 * magnification(at: d)
                var tick = Path()
                tick.move(to: CGPoint(x: cx - half, y: py))
                tick.addLine(to: CGPoint(x: cx + half, y: py))
                context.stroke(tick, with: .color(.white.opacity(brightness(at: d) * 0.55)), lineWidth: 1)
            }
        }
        // Stops: labels on the scale itself, swelling as they near the centre.
        for (i, stop) in stops.enumerated() {
            let py = y(for: model.position(ofStop: i), centre: cy)
            let d = abs(py - cy)
            guard py > -14, py < size.height + 14, d > clearance else { continue }
            let text = Text(ZoomDial.label(stop))
                .font(Theme.mono(9 * magnification(at: d), weight: .bold))
                .foregroundStyle(Color.white.opacity(0.25 + brightness(at: d) * 0.75))
            context.draw(text, at: CGPoint(x: cx, y: py))
        }
    }

    @ViewBuilder
    private var flipHint: some View {
        let p = model.flipProgress
        if p > 0.05 {
            // In the gap the scale stretches away from.
            Text(model.isFront ? "BACK" : "SELFIE")
                .monoLabel(8, weight: .bold, color: p >= 1 ? Theme.accent : Theme.primary)
                .opacity(Double(p))
                .scaleEffect(0.85 + 0.15 * p)
                .fixedSize()
                .offset(y: model.isFront ? 36 : -36)
        }
    }
}

enum ZoomDial {
    static func label(_ zoom: CGFloat, precise: Bool = false) -> String {
        if zoom < 1 {
            return String(format: "%.1f×", zoom).replacingOccurrences(of: "0.", with: ".")
        }
        if abs(zoom.rounded() - zoom) < 0.05 { return "\(Int(zoom.rounded()))×" }
        return String(format: "%.1f×", zoom)
    }
}
