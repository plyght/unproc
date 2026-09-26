import SwiftUI

/// Liquid Glass panel that drops down over the top of the viewfinder.
/// Each row is a label followed by a `GlassSegmented` selector whose glass
/// capsule slides between options.
struct SettingsMenu: View {
    let settings: SettingsStore
    var onClose: () -> Void = {}

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: Theme.viewfinderCorner,
            bottomLeadingRadius: 24,
            bottomTrailingRadius: 24,
            topTrailingRadius: Theme.viewfinderCorner,
            style: .continuous
        )
    }

    var body: some View {
        let value = settings.value
        VStack(alignment: .leading, spacing: 6) {
            row("FORMAT", id: "format", selected: value.output.rawValue, options: [
                ("jpeg", "JPEG"), ("raw", "RAW"),
            ]) { settings.value.output = OutputFormat(rawValue: $0) ?? .jpeg }

            if value.output == .raw {
                row("RAW", id: "raw", selected: value.rawFlavor == .bayer ? "bayer" : "proraw", options: [
                    ("bayer", "BAYER"), ("proraw", "PRORAW"),
                ]) { settings.value.rawFlavor = $0 == "bayer" ? .bayer : .proRAW }
                .transition(.opacity)
            }

            row("RATIO", id: "ratio", selected: value.ratio.rawValue,
                options: FrameRatio.allCases.map { ($0.rawValue, $0.rawValue) }) {
                settings.value.ratio = FrameRatio(rawValue: $0) ?? .fourThree
            }

            lookRow(selectedID: value.lookID)

            toggleRow("DOUBLE EXP", id: "double", isOn: value.doubleExposure) { settings.value.doubleExposure = $0 }
            toggleRow("PRO", id: "pro", isOn: value.proMode) { settings.value.proMode = $0 }
            toggleRow("ZEBRAS", id: "zebras", isOn: value.zebras) { settings.value.zebras = $0 }
            toggleRow("PEAKING", id: "peaking", isOn: value.peaking) { settings.value.peaking = $0 }
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .padding(.top, 16)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(Color.white.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.bottom, 9)
        }
        .glassEffect(.regular.tint(Color.black.opacity(0.38)), in: shape)
        .gesture(
            DragGesture(minimumDistance: 20).onEnded { drag in
                if drag.translation.height < -30 { onClose() }
            }
        )
        .animation(Theme.snappy, value: value.output)
        .sensoryFeedback(.selection, trigger: value)
    }

    // MARK: Rows

    private static let labelWidth: CGFloat = 92

    private func label(_ title: String) -> some View {
        Text(title)
            .monoLabel(10, color: Theme.tertiary)
            .lineLimit(1)
            .frame(width: Self.labelWidth, alignment: .leading)
    }

    /// `options` are (value, label); accessibility ids are "menu.<id>.<value>".
    private func row(
        _ title: String,
        id: String,
        selected: String,
        options: [(String, String)],
        set: @escaping (String) -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 0) {
            label(title)
            GlassSegmented(
                segments: options.map { GlassSegment(id: $0.0, label: $0.1, accessibilityID: "menu.\(id).\($0.0)") },
                selectedID: selected,
                onSelect: set
            )
            Spacer(minLength: 0)
        }
    }

    private func toggleRow(_ title: String, id: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        row(title, id: id, selected: isOn ? "on" : "off", options: [("off", "OFF"), ("on", "ON")]) {
            set($0 == "on")
        }
    }

    private func lookRow(selectedID: String) -> some View {
        HStack(alignment: .center, spacing: 0) {
            label("LOOK")
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassSegmented(
                        segments: LookLibrary.all.map {
                            GlassSegment(id: $0.id, label: $0.code, accessibilityID: "menu.look.\($0.id)")
                        },
                        selectedID: selectedID,
                        onSelect: { settings.value.lookID = $0 }
                    )
                    .padding(.trailing, 28)
                }
                .scrollClipDisabled()
                .mask {
                    HStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 28)
                    }
                }
                .onAppear {
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            }
        }
    }
}
