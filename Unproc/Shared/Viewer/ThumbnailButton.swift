import SwiftUI
import UIKit
import os

/// The small rounded thumbnail of the latest photo on the camera screen.
/// Tapping it opens `PhotoViewer`; the image carries the shared hero id.
struct ThumbnailButton: View {
    let store: any PhotoStore
    let namespace: Namespace.ID
    let action: () -> Void

    private let size: CGFloat = 46   // + 2 × 3 rim = 52, the bottom bar's control height
    private let corner: CGFloat = 10
    /// Loaded a bit larger than displayed so the hero has pixels to grow from.
    private let loadSide: CGFloat = 160

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: UIImage?
    @State private var shownID: PhotoItem.ID?

    init(store: any PhotoStore, namespace: Namespace.ID, action: @escaping () -> Void) {
        self.store = store
        self.namespace = namespace
        self.action = action
        if let first = store.items.first, let cached = ViewerImageCache.thumb(first.id) {
            _shown = State(initialValue: cached)
            _shownID = State(initialValue: first.id)
        }
    }

    var body: some View {
        let latest = store.items.first
        let heroHidden = ViewerHeroState.shared.isOpen(namespace)
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)

        Button {
            guard latest != nil else {
                Log.viewer.info("thumbnail: tap ignored, no photos")
                return
            }
            withAnimation(ViewerStyle.heroAnimation(reduceMotion: reduceMotion)) {
                ViewerHeroState.shared.setOpen(true, for: namespace)
                action()
            }
            let heroNamespace = namespace
            Task {
                try? await Task.sleep(for: .seconds(1))
                withAnimation(ViewerStyle.ui) {
                    ViewerHeroState.shared.revertIfNotPresented(heroNamespace)
                }
            }
        } label: {
            ZStack {
                if !heroHidden, let shown, latest != nil {
                    Color.clear
                        .overlay {
                            Image(uiImage: shown)
                                .resizable()
                                .scaledToFill()
                                .id(shownID)
                                .transition(.opacity)
                        }
                        .clipShape(shape)
                        .overlay(alignment: .bottomTrailing) {
                            if let latest, latest.isVideo {
                                VideoDurationBadge(duration: latest.duration, fontSize: 7)
                                    .padding(2)
                            }
                        }
                        // Reduce Motion: no shared id, so the viewer crossfades in instead of growing.
                        .matchedGeometryEffect(id: reduceMotion ? "photo-hero-thumb" : ViewerStyle.heroID, in: namespace)
                        .frame(width: size, height: size)
                }
            }
            .frame(width: size, height: size)
            // Liquid Glass rim around the photo (and the empty state).
            .padding(3)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: corner + 3, style: .continuous))
            .contentShape(shape)
        }
        .buttonStyle(ViewerPressStyle())
        .accessibilityLabel(Text("Photos"))
        .accessibilityIdentifier("thumbnail")
        .accessibilityValue("\(store.items.count)")
        .task(id: latest?.id) {
            guard let latest else {
                shown = nil
                shownID = nil
                return
            }
            if latest.id == shownID, shown != nil { return }
            if let cached = ViewerImageCache.thumb(latest.id, minSide: loadSide) {
                crossfade(to: cached, id: latest.id)
                return
            }
            guard let image = await store.thumbnail(for: latest, side: loadSide) else { return }
            ViewerImageCache.setThumb(image, for: latest.id, side: loadSide)
            crossfade(to: image, id: latest.id)
        }
        .task {
            if store.items.isEmpty { await store.reload() }
        }
    }

    private func crossfade(to image: UIImage, id: PhotoItem.ID) {
        // A new shot just landed: a short crossfade says "updated" without moving anything.
        withAnimation(.easeOut(duration: 0.25)) {
            shown = image
            shownID = id
        }
    }
}
