import SwiftUI

// Controls used inside the settings menu. The menu panel itself is Liquid
// Glass, so everything here uses plain fills (no glass on glass): a faint
// white track, and an accent-tinted selection that slides between options.

// MARK: - Segmented

/// One option in a `PillSegmented` control.
struct MenuSegment: Identifiable {
    let id: String
    /// Text label (mono, uppercased). Nil for icon-only options.
    var label: String? = nil
    /// SF Symbol drawn before the label.
    var symbol: String? = nil
    /// Portrait width / height: draws a tiny frame-shaped glyph before the label.
    var ratio: CGFloat? = nil
    /// Accessibility identifier (UI tests), e.g. "menu.format.raw".
    let accessibilityID: String
    /// VoiceOver label; defaults to `label`.
    var accessibilityLabel: String? = nil
}

/// A capsule track of options whose selection is a plain accent-tinted pill
/// that slides between them (matched geometry). Labels always sit on top.
struct PillSegmented: View {
    let segments: [MenuSegment]
    let selectedID: String?
    var fontSize: CGFloat = 10
    var height: CGFloat = 30
    var horizontalPadding: CGFloat = 10
    /// Stretch the options to share the full available width.
    var fillsWidth: Bool = false
    let onSelect: (String) -> Void

    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { (segment: MenuSegment) in
                segmentButton(segment)
            }
        }
        .padding(2)
        .background {
            Capsule().fill(Color.white.opacity(0.08))
        }
    }

    private func segmentButton(_ segment: MenuSegment) -> some View {
        let selected = segment.id == selectedID
        let spoken = segment.accessibilityLabel ?? segment.label ?? segment.id
        return Button {
            guard !selected else { return }
            withAnimation(reduceMotion ? Theme.fade : Theme.glassSlide) {
                onSelect(segment.id)
            }
        } label: {
            MenuSegmentLabel(segment: segment, selected: selected, fontSize: fontSize)
                .padding(.horizontal, horizontalPadding)
                .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: height)
                .background {
                    if selected {
                        Capsule()
                            .fill(Theme.accent.opacity(0.2))
                            .overlay {
                                Capsule().strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1)
                            }
                            .matchedGeometryEffect(id: "selection", in: selection)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .id(segment.id)
        .accessibilityLabel(Text(spoken))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(segment.accessibilityID)
    }
}

/// Icon / ratio glyph / text of one segment.
struct MenuSegmentLabel: View {
    let segment: MenuSegment
    let selected: Bool
    let fontSize: CGFloat

    private var color: Color {
        selected ? Theme.accent : Color.white.opacity(0.7)
    }

    var body: some View {
        HStack(spacing: 5) {
            if let symbol = segment.symbol {
                Image(systemName: symbol)
                    .font(.system(size: fontSize + 2, weight: .semibold))
                    .foregroundStyle(color)
            }
            if let ratio = segment.ratio {
                RatioGlyph(aspect: ratio, color: color)
            }
            if let label = segment.label {
                Text(label)
                    .monoLabel(fontSize, weight: selected ? .semibold : .medium, color: color)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

/// A tiny outlined frame in the shape of a crop ratio (portrait).
struct RatioGlyph: View {
    /// Width / height.
    let aspect: CGFloat
    let color: Color
    var height: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .strokeBorder(color, lineWidth: 1.2)
            .frame(width: max(height * aspect, 4), height: height)
    }
}

// MARK: - Toggle tile

/// An on/off tile: SF Symbol over a mono label; lights up in the accent when on.
///
/// Its accessibility identifier names what a tap does — "menu.<id>.on" while
/// off, "menu.<id>.off" while on — matching the old OFF / ON segments.
struct ToggleTile: View {
    let title: String
    let symbol: String
    let id: String
    let isOn: Bool
    let onToggle: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    var body: some View {
        let tint: Color = isOn ? Theme.accent : Color.white.opacity(0.62)
        let identifier = "menu.\(id).\(isOn ? "off" : "on")"
        Button {
            withAnimation(reduceMotion ? Theme.fade : Theme.snappy) {
                onToggle(!isOn)
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(height: 18)
                Text(title)
                    .monoLabel(9, weight: isOn ? .semibold : .medium, color: tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background {
                shape.fill(isOn ? Theme.accent.opacity(0.18) : Color.white.opacity(0.07))
            }
            .overlay {
                shape.strokeBorder(isOn ? Theme.accent.opacity(0.5) : Color.white.opacity(0.06), lineWidth: 1)
            }
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(isOn ? Theme.accent : Color.white.opacity(0.18))
                    .frame(width: 4, height: 4)
                    .padding(8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(isOn ? "On" : "Off"))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Colour swatches

/// One accent choice.
struct AccentSwatch: Identifiable {
    let id: String
    let name: String
    let color: Color
}

/// A row of colour dots; the selected one carries a white ring that slides.
struct AccentSwatches: View {
    let swatches: [AccentSwatch]
    let selectedID: String
    let onSelect: (String) -> Void

    @Namespace private var ring
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(swatches) { (swatch: AccentSwatch) in
                swatchButton(swatch)
            }
        }
    }

    private func swatchButton(_ swatch: AccentSwatch) -> some View {
        let selected = swatch.id == selectedID
        return Button {
            guard !selected else { return }
            withAnimation(reduceMotion ? Theme.fade : Theme.glassSlide) {
                onSelect(swatch.id)
            }
        } label: {
            Circle()
                .fill(swatch.color)
                .frame(width: 20, height: 20)
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                }
                .padding(4)
                .background {
                    if selected {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                            .matchedGeometryEffect(id: "ring", in: ring)
                    }
                }
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .id(swatch.id)
        .accessibilityLabel(Text(swatch.name))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("menu.accent.\(swatch.id)")
    }
}

// MARK: - Section header

/// Small mono section label with a hairline, and an optional accent detail
/// (e.g. the current look's name).
struct MenuSectionHeader: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .monoLabel(9, weight: .semibold, color: Color.white.opacity(0.42))
                .lineLimit(1)
                .fixedSize()
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
            if let detail {
                Text(detail)
                    .monoLabel(9, color: Theme.accent.opacity(0.9))
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Scroll fade

/// Mask that fades a horizontal scroll row out at its trailing edge.
struct TrailingFadeMask: View {
    var width: CGFloat = 28

    var body: some View {
        HStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: width)
        }
    }
}
