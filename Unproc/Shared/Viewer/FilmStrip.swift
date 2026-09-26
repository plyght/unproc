import SwiftUI

/// Row of small thumbnails under the viewer. The current photo is outlined in
/// the accent colour; tapping one jumps to it; the strip follows the pager.
struct FilmStrip: View {
    let store: any PhotoStore
    let items: [PhotoItem]
    let currentID: PhotoItem.ID?
    let onSelect: (PhotoItem.ID) -> Void

    private let cellSize = CGSize(width: 36, height: 48)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 4) {
                    ForEach(items) { item in
                        let isCurrent = item.id == currentID
                        Button {
                            onSelect(item.id)
                        } label: {
                            StoreThumbnail(store: store, item: item, side: cellSize.height)
                                .frame(width: cellSize.width, height: cellSize.height)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(isCurrent ? ViewerStyle.accent : Color.clear, lineWidth: 2)
                                )
                                .opacity(isCurrent ? 1 : 0.55)
                                .animation(ViewerStyle.ui, value: isCurrent)
                        }
                        .buttonStyle(ViewerPressStyle())
                        .accessibilityLabel(Text(item.createdAt, format: .dateTime))
                        .accessibilityAddTraits(isCurrent ? .isSelected : [])
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("viewer.filmstrip")
            .frame(height: cellSize.height + 16)
            .onAppear {
                if let currentID { proxy.scrollTo(currentID, anchor: .center) }
            }
            .onChange(of: currentID) { _, id in
                guard let id else { return }
                withAnimation(ViewerStyle.ui) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}
