import SwiftUI

/// One choice in a `GlassSegmented` row.
struct GlassSegment: Identifiable {
    let id: String
    let label: String
    /// Accessibility identifier (UI tests), e.g. "menu.format.raw".
    let accessibilityID: String
    var fontSize: CGFloat = 11
}

/// A row of text options where the selection is a Liquid Glass capsule that
/// slides — and liquidly morphs — from one option to the next.
///
/// The selected option carries a tinted glass shape tagged with a shared
/// `glassEffectID`; because every option lives in one `GlassEffectContainer`,
/// changing the selection inside an animation makes the glass flow across
/// instead of cross-fading.
struct GlassSegmented: View {
    let segments: [GlassSegment]
    let selectedID: String?
    var spacing: CGFloat = 2
    var minHeight: CGFloat = 30
    var horizontalPadding: CGFloat = 10
    let onSelect: (String) -> Void

    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            HStack(spacing: spacing) {
                ForEach(segments) { segment in
                    let selected = segment.id == selectedID
                    Button {
                        guard !selected else { return }
                        withAnimation(reduceMotion ? Theme.fade : Theme.glassSlide) {
                            onSelect(segment.id)
                        }
                    } label: {
                        Text(segment.label)
                            .monoLabel(segment.fontSize, weight: selected ? .semibold : .medium,
                                       color: selected ? Theme.accent : Color.white.opacity(0.72))
                            .fixedSize()
                            .padding(.horizontal, horizontalPadding)
                            .frame(minHeight: minHeight)
                            // The glass sits on the label itself so the text renders on
                            // top of it; only the selected option has real glass, and it
                            // carries the shared id so it flows between options.
                            .glassEffect(selected ? .regular.tint(Theme.accent.opacity(0.14)).interactive() : .identity,
                                         in: .capsule)
                            .glassEffectID(selected ? "selection" : segment.id, in: glass)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier(segment.accessibilityID)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }
}
