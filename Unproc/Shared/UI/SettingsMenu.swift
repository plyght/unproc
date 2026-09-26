import SwiftUI

/// Dark translucent panel that slides down over the top of the viewfinder.
/// Each row is a label followed by its options; the selected option is accent,
/// the others white at 50 %.
struct SettingsMenu: View {
    let settings: SettingsStore
    var onClose: () -> Void = {}

    var body: some View {
        let value = settings.value
        VStack(alignment: .leading, spacing: 14) {
            row("FORMAT") {
                option("JPEG", id: "format.jpeg", selected: value.output == .jpeg) { settings.value.output = .jpeg }
                option("RAW", id: "format.raw", selected: value.output == .raw) { settings.value.output = .raw }
            }
            if value.output == .raw {
                row("RAW") {
                    option("BAYER", id: "raw.bayer", selected: value.rawFlavor == .bayer) { settings.value.rawFlavor = .bayer }
                    option("PRORAW", id: "raw.proraw", selected: value.rawFlavor == .proRAW) { settings.value.rawFlavor = .proRAW }
                }
                .transition(.opacity)
            }
            lookRow(selectedID: value.lookID)
            toggleRow("DOUBLE EXP", id: "double", isOn: value.doubleExposure) { settings.value.doubleExposure = $0 }
            toggleRow("PRO", id: "pro", isOn: value.proMode) { settings.value.proMode = $0 }
            toggleRow("ZEBRAS", id: "zebras", isOn: value.zebras) { settings.value.zebras = $0 }
            toggleRow("PEAKING", id: "peaking", isOn: value.peaking) { settings.value.peaking = $0 }
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(Color.white.opacity(0.28))
                .frame(width: 36, height: 4)
                .padding(.bottom, 10)
        }
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: Theme.viewfinderCorner,
                bottomLeadingRadius: 22,
                bottomTrailingRadius: 22,
                topTrailingRadius: Theme.viewfinderCorner,
                style: .continuous
            )
            .fill(Theme.panel)
            .background(
                .ultraThinMaterial,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: Theme.viewfinderCorner,
                    bottomLeadingRadius: 22,
                    bottomTrailingRadius: 22,
                    topTrailingRadius: Theme.viewfinderCorner,
                    style: .continuous
                )
            )
        }
        .gesture(
            DragGesture(minimumDistance: 20).onEnded { drag in
                if drag.translation.height < -30 { onClose() }
            }
        )
        .animation(Theme.snappy, value: value)
        .sensoryFeedback(.selection, trigger: value)
    }

    // MARK: Rows

    private static let labelWidth: CGFloat = 96

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Text(title)
                .monoLabel(10, color: Theme.tertiary)
                .lineLimit(1)
                .frame(width: Self.labelWidth, alignment: .leading)
            HStack(spacing: 14) {
                content()
            }
            Spacer(minLength: 0)
        }
    }

    private func toggleRow(_ title: String, id: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        row(title) {
            option("OFF", id: "\(id).off", selected: !isOn) { set(false) }
            option("ON", id: "\(id).on", selected: isOn) { set(true) }
        }
    }

    private func lookRow(selectedID: String) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Text("LOOK")
                .monoLabel(10, color: Theme.tertiary)
                .frame(width: Self.labelWidth, alignment: .leading)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(LookLibrary.all) { look in
                            option(look.code, id: "look.\(look.id)", selected: look.id == selectedID) {
                                settings.value.lookID = look.id
                            }
                            .id(look.id)
                        }
                    }
                    .padding(.trailing, 28)
                }
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

    /// `id` becomes the accessibility identifier "menu.<id>" (UI tests).
    private func option(_ label: String, id: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .monoLabel(11, weight: selected ? .semibold : .regular,
                           color: selected ? Theme.accent : Theme.secondary)
                .fixedSize()
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("menu.\(id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
