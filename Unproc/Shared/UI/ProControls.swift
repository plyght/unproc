import SwiftUI

/// Manual controls shown over the bottom of the viewfinder in PRO mode:
/// a row of glass chips (ISO, SHUTTER, EV, WB, FOCUS) with live values, each
/// expanding into a `ValueDial`.
struct ProControls: View {
    let camera: CameraController
    @Binding var expanded: ProParameter?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(camera: CameraController, expanded: Binding<ProParameter?>) {
        self.camera = camera
        self._expanded = expanded
    }

    /// Chip order: ƒ (variable-aperture cameras only), ISO, SHUTTER, EV, WB, FOCUS.
    enum ProParameter: String, CaseIterable, Identifiable {
        case aperture, iso, shutter, ev, wb, focus
        var id: String { rawValue }
        var title: String {
            switch self {
            case .aperture: "APERTURE"
            case .iso: "ISO"
            case .shutter: "SHUTTER"
            case .ev: "EV"
            case .wb: "WB"
            case .focus: "FOCUS"
            }
        }
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                if let expanded {
                    dial(for: expanded)
                        .id(expanded)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .rect(cornerRadius: 16))
                        .transition(Theme.popover(anchor: .bottom, offsetY: 6, reduceMotion: reduceMotion))
                }
                // Fill the width when the chips fit; scroll horizontally when
                // they don't (six chips on an SE-size screen).
                ViewThatFits(in: .horizontal) {
                    chipRow
                    ScrollView(.horizontal, showsIndicators: false) {
                        chipRow
                    }
                    .scrollClipDisabled()
                }
            }
        }
        .animation(Theme.snappy, value: expanded)
        .onChange(of: camera.supportsVariableAperture) { _, supported in
            if !supported && expanded == .aperture { expanded = nil }
        }
    }

    private var parameters: [ProParameter] {
        camera.supportsVariableAperture
            ? ProParameter.allCases
            : ProParameter.allCases.filter { $0 != .aperture }
    }

    private var chipRow: some View {
        HStack(spacing: 6) {
            ForEach(parameters) { parameter in
                chip(parameter)
            }
        }
    }

    // MARK: Chips

    private func chip(_ parameter: ProParameter) -> some View {
        let manual = isManual(parameter)
        let selected = expanded == parameter
        return Button {
            expanded = selected ? nil : parameter
        } label: {
            VStack(spacing: 2) {
                Text(parameter.title)
                    .monoLabel(7, color: selected ? Theme.accent : Theme.secondary)
                Text(valueText(parameter))
                    .monoLabel(10, weight: .semibold, color: manual ? Theme.accent : Theme.primary, uppercase: false)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                    // Roll digits only for values the user sets; live auto
                    // values change constantly and would just be noise.
                    .animation(manual ? Theme.snappy : nil, value: valueText(parameter))
            }
            .frame(minWidth: 48, maxWidth: .infinity)
            .padding(.vertical, 7)
            .padding(.horizontal, 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityIdentifier("pro.\(parameter.rawValue)")
        .sensoryFeedback(.selection, trigger: selected)
    }

    private func isManual(_ parameter: ProParameter) -> Bool {
        let e = camera.exposure
        switch parameter {
        case .aperture: return e.manualAperture != nil
        case .iso: return e.manualISO != nil
        case .shutter: return e.manualShutter != nil
        case .ev: return abs(e.bias) > 0.01
        case .wb: return e.manualKelvin != nil
        case .focus: return camera.focus.manualLensPosition != nil
        }
    }

    private func valueText(_ parameter: ProParameter) -> String {
        let e = camera.exposure
        switch parameter {
        case .aperture: return ProFormat.aperture(Double(e.manualAperture ?? e.aperture))
        case .iso: return ProFormat.iso(Double(e.manualISO ?? e.iso))
        case .shutter: return ProFormat.shutter(e.manualShutter ?? e.shutter)
        case .ev: return ProFormat.ev(Double(e.bias))
        case .wb: return ProFormat.kelvin(Double(e.manualKelvin ?? e.kelvin))
        case .focus:
            if let manual = camera.focus.manualLensPosition { return ProFormat.focus(Double(manual)) }
            return "AF"
        }
    }

    // MARK: Dials

    @ViewBuilder
    private func dial(for parameter: ProParameter) -> some View {
        let e = camera.exposure
        switch parameter {
        case .aperture:
            ValueDial(
                title: "APERTURE",
                stops: ProStops.aperture(e.apertureStops),
                current: Double(e.manualAperture ?? e.aperture),
                isAuto: e.manualAperture == nil,
                logarithmic: true,
                majorEvery: 1,
                tickSpacing: 24,
                format: ProFormat.aperture,
                onChange: { camera.setAperture(Float($0)) },
                onAuto: { camera.setAperture(nil) }
            )
        case .iso:
            ValueDial(
                title: "ISO",
                stops: ProStops.iso(in: e.isoRange),
                current: Double(e.manualISO ?? e.iso),
                isAuto: e.manualISO == nil,
                logarithmic: true,
                majorEvery: 3,
                format: ProFormat.iso,
                onChange: { camera.setISO(Float($0)) },
                onAuto: { camera.setISO(nil) }
            )
        case .shutter:
            ValueDial(
                title: "SHUTTER",
                stops: ProStops.shutter(in: e.shutterRange),
                current: e.manualShutter ?? e.shutter,
                isAuto: e.manualShutter == nil,
                logarithmic: true,
                majorEvery: 1,
                tickSpacing: 18,
                format: ProFormat.shutter,
                onChange: { camera.setShutter($0) },
                onAuto: { camera.setShutter(nil) }
            )
        case .ev:
            ValueDial(
                title: "EV",
                stops: ProStops.ev(in: e.biasRange),
                current: Double(e.bias),
                isAuto: abs(e.bias) < 0.01,
                majorEvery: 3,
                format: ProFormat.ev,
                onChange: { camera.setExposureBias(Float($0)) },
                onAuto: { camera.setExposureBias(0) }
            )
        case .wb:
            ValueDial(
                title: "WB",
                stops: ProStops.kelvin,
                current: Double(e.manualKelvin ?? e.kelvin),
                isAuto: e.manualKelvin == nil,
                majorEvery: 10,
                tickSpacing: 7,
                format: ProFormat.kelvin,
                onChange: { camera.setWhiteBalance(kelvin: Float($0)) },
                onAuto: { camera.setWhiteBalance(kelvin: nil) }
            )
        case .focus:
            ValueDial(
                title: "FOCUS",
                stops: ProStops.focus,
                current: Double(camera.focus.manualLensPosition ?? camera.focus.lensPosition),
                isAuto: camera.focus.manualLensPosition == nil,
                majorEvery: 10,
                tickSpacing: 6,
                format: ProFormat.focus,
                onChange: { camera.setManualFocus(Float($0)) },
                onAuto: { camera.setManualFocus(nil) }
            )
        }
    }
}

// MARK: - Stops

enum ProStops {
    static let isoThirds: [Double] = [
        25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800,
        1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800,
    ]

    static func iso(in range: ClosedRange<Float>) -> [Double] {
        let lo = Double(range.lowerBound), hi = Double(range.upperBound)
        var stops = isoThirds.filter { $0 >= lo - 0.5 && $0 <= hi + 0.5 }
        if stops.isEmpty { stops = [lo, hi] }
        return stops
    }

    /// Full stops 1/8000 … 30 s.
    static let shutterStops: [Double] = [
        1.0 / 8000, 1.0 / 4000, 1.0 / 2000, 1.0 / 1000, 1.0 / 500, 1.0 / 250, 1.0 / 125,
        1.0 / 60, 1.0 / 30, 1.0 / 15, 1.0 / 8, 1.0 / 4, 1.0 / 2, 1, 2, 4, 8, 15, 30,
    ]

    static func shutter(in range: ClosedRange<Double>) -> [Double] {
        var stops = shutterStops.filter { $0 >= range.lowerBound * 0.999 && $0 <= range.upperBound * 1.001 }
        if stops.isEmpty { stops = [range.lowerBound, range.upperBound] }
        return stops
    }

    static func ev(in range: ClosedRange<Float>) -> [Double] {
        let lo = max(-3, Double(range.lowerBound)), hi = min(3, Double(range.upperBound))
        var stops: [Double] = []
        for third in -9...9 {
            let v = Double(third) / 3
            if v >= lo - 0.001 && v <= hi + 0.001 { stops.append(v) }
        }
        return stops.isEmpty ? [0] : stops
    }

    static let kelvin: [Double] = stride(from: 2000.0, through: 10000.0, by: 100.0).map { $0 }

    static let focus: [Double] = (0...100).map { Double($0) / 100 }

    /// The lens's own aperture stops (f/1.48 · 1.8 · 2.8 · 4 on a variable-aperture main camera).
    static func aperture(_ stops: [Float]) -> [Double] {
        let values = stops.map(Double.init).filter { $0 > 0 }.sorted()
        return values.isEmpty ? [1.48, 1.8, 2.8, 4] : values
    }
}

// MARK: - Formatting

enum ProFormat {
    static func iso(_ value: Double) -> String {
        "\(Int(value.rounded()))"
    }

    /// "1/125", "0.5\"", "1\"", "15\"".
    static func shutter(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds >= 0.45 {
            if abs(seconds - seconds.rounded()) < 0.05 { return "\(Int(seconds.rounded()))\"" }
            return String(format: "%.1f\"", seconds)
        }
        return "1/\(Int((1 / seconds).rounded()))"
    }

    static func ev(_ value: Double) -> String {
        if abs(value) < 0.05 { return "±0.0" }
        return String(format: "%+.1f", value)
    }

    static func kelvin(_ value: Double) -> String {
        "\(Int((value / 100).rounded()) * 100)K"
    }

    static func focus(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// "ƒ1.48", "ƒ1.8", "ƒ4" (lowercase ƒ — don't uppercase this string).
    static func aperture(_ value: Double) -> String {
        var s = String(format: "%.2f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return "ƒ" + s
    }
}
