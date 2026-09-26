import SwiftUI

/// Ruler-style horizontal scrubber that snaps to a list of stops.
///
/// Drag left/right to scrub; the value under the centre (accent) needle is
/// sent through `onChange` each time it lands on a new stop. The "AUTO" pill
/// calls `onAuto` (the caller sets the manual value back to nil).
struct ValueDial: View {
    let title: String
    let stops: [Double]
    /// Live value shown while in auto (and the starting point for scrubbing).
    let current: Double
    let isAuto: Bool
    /// Compare stops logarithmically (ISO, shutter).
    var logarithmic: Bool = false
    /// Every n-th tick is drawn taller.
    var majorEvery: Int = 3
    var tickSpacing: CGFloat = 11
    let format: (Double) -> String
    let onChange: (Double) -> Void
    let onAuto: () -> Void

    init(
        title: String,
        stops: [Double],
        current: Double,
        isAuto: Bool,
        logarithmic: Bool = false,
        majorEvery: Int = 3,
        tickSpacing: CGFloat = 11,
        format: @escaping (Double) -> String,
        onChange: @escaping (Double) -> Void,
        onAuto: @escaping () -> Void
    ) {
        self.title = title
        self.stops = stops
        self.current = current
        self.isAuto = isAuto
        self.logarithmic = logarithmic
        self.majorEvery = majorEvery
        self.tickSpacing = tickSpacing
        self.format = format
        self.onChange = onChange
        self.onAuto = onAuto
    }

    @State private var position: Double = 0
    @State private var dragBase: Double?
    @State private var selectedIndex: Int = 0
    @State private var hapticTick: Int = 0

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .monoLabel(9, color: Theme.secondary)
                Text(format(displayValue))
                    .monoLabel(12, weight: .semibold, color: isAuto ? Theme.primary : Theme.accent, uppercase: false)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(isAuto ? nil : Animation.snappy(duration: 0.16), value: format(displayValue))
                Spacer(minLength: 8)
                Button(action: onAuto) {
                    Text("AUTO")
                        .monoLabel(9, weight: .semibold, color: isAuto ? .black : Theme.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background {
                            Capsule().fill(isAuto ? Theme.accent : Color.white.opacity(0.12))
                        }
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("pro.auto")
                .animation(Theme.fade, value: isAuto)
            }

            ruler
                .frame(height: 30)
                .contentShape(Rectangle())
                .gesture(drag)
        }
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.3), trigger: hapticTick)
        .onAppear { syncToCurrent() }
        .onChange(of: current) { _, _ in
            if dragBase == nil && isAuto { syncToCurrent() }
        }
        .onChange(of: isAuto) { _, _ in
            if dragBase == nil { syncToCurrent() }
        }
    }

    private var displayValue: Double {
        if dragBase != nil, stops.indices.contains(selectedIndex) { return stops[selectedIndex] }
        return current
    }

    // MARK: Ruler

    private var ruler: some View {
        let pos = position
        let count = stops.count
        let spacing = tickSpacing
        let major = max(majorEvery, 1)
        return Canvas { context, size in
            let mid = size.width / 2
            let visible = Int(ceil(size.width / spacing / 2)) + 1
            let centre = Int(pos.rounded())
            let lo = max(0, centre - visible)
            let hi = min(count - 1, centre + visible)
            guard lo <= hi else { return }
            for i in lo...hi {
                let x = mid + CGFloat(Double(i) - pos) * spacing
                let distance = abs(x - mid) / max(mid, 1)
                let fade = max(0.12, 1 - distance * 0.9)
                let isMajor = i % major == 0
                let h: CGFloat = isMajor ? size.height * 0.62 : size.height * 0.34
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height - h))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(.white.opacity((isMajor ? 0.75 : 0.4) * fade)), lineWidth: 1)
            }
        }
        .overlay {
            // Centre needle.
            Capsule()
                .fill(Theme.accent)
                .frame(width: 2)
                .padding(.vertical, 1)
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.15),
                    .init(color: .black, location: 0.85),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard !stops.isEmpty else { return }
                let base = dragBase ?? position
                if dragBase == nil { dragBase = base }
                let raw = base - Double(value.translation.width / tickSpacing)
                position = min(max(raw, 0), Double(stops.count - 1))
                let index = Int(position.rounded())
                if index != selectedIndex || isAuto {
                    if index != selectedIndex { hapticTick &+= 1 }
                    selectedIndex = index
                    onChange(stops[index])
                }
            }
            .onEnded { _ in
                dragBase = nil
                withAnimation(Theme.snappy) {
                    position = Double(selectedIndex)
                }
            }
    }

    // MARK: Helpers

    private func syncToCurrent() {
        let index = nearestIndex(to: current)
        selectedIndex = index
        position = Double(index)
    }

    private func nearestIndex(to value: Double) -> Int {
        guard !stops.isEmpty else { return 0 }
        func key(_ v: Double) -> Double { logarithmic ? log(max(v, 1e-9)) : v }
        let target = key(value)
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (i, s) in stops.enumerated() {
            let d = abs(key(s) - target)
            if d < bestDistance { bestDistance = d; best = i }
        }
        return best
    }
}
