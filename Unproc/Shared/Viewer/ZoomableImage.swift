import SwiftUI
import UIKit

/// One photo that can be pinched (1…5×, following the fingers and rubber-banding
/// past the limits), double-tapped (toggle 2.5× at the tap point) and panned
/// while zoomed. Reports zoom through `isZoomed` so the pager can stop paging
/// and the viewer can stop the dismiss drag.
struct ZoomableImage: View {
    let image: UIImage?
    /// Matched-geometry id: the hero id on the current page, a unique one elsewhere.
    let heroID: String
    let namespace: Namespace.ID
    /// Only the active page writes `isZoomed`; inactive pages reset.
    let isActive: Bool
    @Binding var isZoomed: Bool

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 5
    private let doubleTapScale: CGFloat = 2.5

    /// Live values (what is on screen).
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// Values at the start of the current gesture.
    @State private var baseScale: CGFloat = 1
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            content
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, coordinateSpace: .local) { location in
                    toggleZoom(at: location, in: size)
                }
                .gesture(pan(in: size), including: scale > 1.01 ? .all : .subviews)
                .simultaneousGesture(magnify(in: size))
        }
        .onChange(of: scale > 1.01) { _, zoomed in
            if isActive { isZoomed = zoomed }
        }
        .onChange(of: isActive) { _, active in
            if active {
                isZoomed = scale > 1.01
            } else {
                resetZoom()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .matchedGeometryEffect(id: heroID, in: namespace)
        } else {
            ProgressView()
                .tint(.white.opacity(0.6))
        }
    }

    // MARK: Gestures

    /// Pinch: the point between the fingers stays under the fingers (1:1),
    /// with rubber-banding past 1× and 5×, springing back on release.
    private func magnify(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let raw = baseScale * value.magnification
                let live = rubberBandedScale(raw)
                scale = live
                offset = anchoredOffset(scale: live, location: value.startLocation, in: size)
            }
            .onEnded { value in
                let target = min(max(scale, minScale), maxScale)
                let targetOffset = target <= minScale
                    ? CGSize.zero
                    : clamped(anchoredOffset(scale: target, location: value.startLocation, in: size),
                              scale: target, in: size)
                withAnimation(ViewerStyle.snapBack) {
                    scale = target
                    offset = targetOffset
                }
                baseScale = target
                baseOffset = targetOffset
            }
    }

    /// Pan while zoomed: 1:1, rubber-bands past the image edges, and on release
    /// carries the flick's momentum to where it was heading (clamped).
    private func pan(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let proposed = CGSize(width: baseOffset.width + value.translation.width,
                                      height: baseOffset.height + value.translation.height)
                offset = rubberBanded(proposed, scale: scale, in: size)
            }
            .onEnded { value in
                let projected = CGSize(width: baseOffset.width + value.predictedEndTranslation.width,
                                       height: baseOffset.height + value.predictedEndTranslation.height)
                let target = clamped(projected, scale: scale, in: size)
                withAnimation(ViewerStyle.snapBack) { offset = target }
                baseOffset = target
            }
    }

    private func toggleZoom(at location: CGPoint, in size: CGSize) {
        let targetScale: CGFloat
        let targetOffset: CGSize
        if scale > 1.01 {
            targetScale = 1
            targetOffset = .zero
        } else {
            // Keep the tapped point under the finger.
            targetScale = doubleTapScale
            let dx = location.x - size.width / 2
            let dy = location.y - size.height / 2
            targetOffset = clamped(CGSize(width: -dx * (doubleTapScale - 1), height: -dy * (doubleTapScale - 1)),
                                   scale: doubleTapScale, in: size)
        }
        withAnimation(ViewerStyle.hero) {
            scale = targetScale
            offset = targetOffset
        }
        baseScale = targetScale
        baseOffset = targetOffset
    }

    private func resetZoom() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }

    // MARK: Geometry

    private func rubberBandedScale(_ raw: CGFloat) -> CGFloat {
        if raw > maxScale {
            return maxScale + ViewerStyle.rubberBand(raw - maxScale, dimension: maxScale)
        }
        if raw < minScale {
            return minScale + ViewerStyle.rubberBand(raw - minScale, dimension: minScale)
        }
        return raw
    }

    /// Offset that keeps the content point that was under `location` (at the
    /// gesture's start) under it at `scale`.
    private func anchoredOffset(scale: CGFloat, location: CGPoint, in size: CGSize) -> CGSize {
        guard baseScale > 0 else { return offset }
        let lx = location.x - size.width / 2
        let ly = location.y - size.height / 2
        let ratio = scale / baseScale
        return CGSize(width: lx - (lx - baseOffset.width) * ratio,
                      height: ly - (ly - baseOffset.height) * ratio)
    }

    /// The size the image occupies at 1× (aspect fit in the page).
    private func fittedSize(in size: CGSize) -> CGSize {
        guard let image, image.size.width > 0, image.size.height > 0,
              size.width > 0, size.height > 0 else { return size }
        let ratio = min(size.width / image.size.width, size.height / image.size.height)
        return CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
    }

    private func limits(scale: CGFloat, in size: CGSize) -> CGSize {
        let fitted = fittedSize(in: size)
        return CGSize(width: max(0, (fitted.width * scale - size.width) / 2),
                      height: max(0, (fitted.height * scale - size.height) / 2))
    }

    private func clamped(_ proposed: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
        let limit = limits(scale: scale, in: size)
        return CGSize(width: min(max(proposed.width, -limit.width), limit.width),
                      height: min(max(proposed.height, -limit.height), limit.height))
    }

    private func rubberBanded(_ proposed: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
        let limit = limits(scale: scale, in: size)
        func band(_ value: CGFloat, _ bound: CGFloat, _ dimension: CGFloat) -> CGFloat {
            if value > bound { return bound + ViewerStyle.rubberBand(value - bound, dimension: dimension) }
            if value < -bound { return -bound + ViewerStyle.rubberBand(value + bound, dimension: dimension) }
            return value
        }
        return CGSize(width: band(proposed.width, limit.width, size.width),
                      height: band(proposed.height, limit.height, size.height))
    }
}
