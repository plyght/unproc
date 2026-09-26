import SwiftUI
import UIKit
import Observation

/// Visual and motion constants for the viewer. Namespaced so they never
/// collide with the camera UI's `Theme`.
enum ViewerStyle {
    /// The app accent (device colour or signal orange, see `DeviceAccent`).
    static var accent: Color { DeviceAccent.color }
    static let placeholder = Color(white: 0.11)
    /// Shared `matchedGeometryEffect` id between the thumbnail and the viewer.
    static let heroID = "photo-hero"

    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        Font.system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: Motion
    // Springs everywhere (interruptible, retarget from the on-screen value).
    // Critically damped unless a flick put momentum into the gesture.

    /// Thumbnail <-> viewer hero. Critically damped: a reposition, no overshoot.
    static let hero = Animation.spring(response: 0.35, dampingFraction: 1.0)
    /// Small state changes (pager step, labels, fades): ~200 ms, no overshoot.
    static let ui = Animation.spring(response: 0.2, dampingFraction: 1.0)
    /// Press feedback: fast in, fast out.
    static let press = Animation.spring(response: 0.15, dampingFraction: 1.0)
    /// Something the user let go of after dragging (dismiss cancelled, zoom
    /// past its limits): may carry a touch of momentum.
    static let snapBack = Animation.spring(response: 0.3, dampingFraction: 0.82)
    /// Reduced motion replaces movement with a short crossfade.
    static let fade = Animation.easeOut(duration: 0.2)

    /// Hero (or its crossfade substitute when Reduce Motion is on).
    static func heroAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : hero
    }

    /// Apple's rubber band: the further past the edge, the less it follows.
    static func rubberBand(_ overshoot: CGFloat, dimension: CGFloat, constant: CGFloat = 0.55) -> CGFloat {
        guard dimension > 0 else { return 0 }
        let magnitude = abs(overshoot)
        let damped = (magnitude * dimension * constant) / (dimension + constant * magnitude)
        return overshoot < 0 ? -damped : damped
    }
}

/// Press feedback for every viewer control: shrinks to 0.96 the instant a
/// finger lands (dims instead under Reduce Motion).
struct ViewerPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
            .opacity(pressed && reduceMotion ? 0.6 : 1)
            .animation(ViewerStyle.press, value: pressed)
    }
}

/// Which hero namespaces currently have a viewer open. The thumbnail hides its
/// image while the viewer is open so exactly one view carries the hero id,
/// and toggling this inside the same animated transaction as the parent's
/// presentation state is what makes the photo "grow out of" the thumbnail.
@MainActor
@Observable
final class ViewerHeroState {
    static let shared = ViewerHeroState()
    private(set) var open: Set<Namespace.ID> = []
    /// Namespaces whose `PhotoViewer` is actually on screen.
    @ObservationIgnored private var presented: Set<Namespace.ID> = []

    private init() {}

    func isOpen(_ namespace: Namespace.ID) -> Bool { open.contains(namespace) }
    func setOpen(_ isOpen: Bool, for namespace: Namespace.ID) {
        if isOpen {
            if !open.contains(namespace) { open.insert(namespace) }
        } else if open.contains(namespace) {
            open.remove(namespace)
        }
    }

    func viewerAppeared(_ namespace: Namespace.ID) {
        presented.insert(namespace)
        setOpen(true, for: namespace)
    }

    func viewerDisappeared(_ namespace: Namespace.ID) {
        presented.remove(namespace)
        setOpen(false, for: namespace)
    }

    /// Safety net: if the host didn't actually present a viewer after the
    /// thumbnail was tapped, show the thumbnail again.
    func revertIfNotPresented(_ namespace: Namespace.ID) {
        if !presented.contains(namespace) { setOpen(false, for: namespace) }
    }
}

/// Small in-memory caches shared by the thumbnail button, the film strip and
/// the pages, so the hero starts from an image that is already decoded.
@MainActor
enum ViewerImageCache {
    private static let fullCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 6
        return cache
    }()

    private static let thumbCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 500
        return cache
    }()

    /// Point size each cached thumbnail was requested at.
    private static var thumbSides: [String: CGFloat] = [:]

    static func full(_ id: String) -> UIImage? { fullCache.object(forKey: id as NSString) }

    static func setFull(_ image: UIImage, for id: String) {
        fullCache.setObject(image, forKey: id as NSString)
    }

    /// A cached thumbnail at least `minSide` points big.
    static func thumb(_ id: String, minSide: CGFloat = 0) -> UIImage? {
        guard let side = thumbSides[id], side >= minSide else { return nil }
        return thumbCache.object(forKey: id as NSString)
    }

    static func setThumb(_ image: UIImage, for id: String, side: CGFloat) {
        let key = id as NSString
        if let existing = thumbSides[id], existing > side, thumbCache.object(forKey: key) != nil { return }
        thumbCache.setObject(image, forKey: key)
        thumbSides[id] = side
    }

    /// Best image available right now for a page: full, else any thumbnail.
    static func preview(_ id: String) -> UIImage? { full(id) ?? thumb(id) }

    static func forget(_ id: String) {
        let key = id as NSString
        fullCache.removeObject(forKey: key)
        thumbCache.removeObject(forKey: key)
        thumbSides[id] = nil
    }
}

/// A store thumbnail that fills whatever frame it is given (aspect fill, clipped).
struct StoreThumbnail: View {
    let store: any PhotoStore
    let item: PhotoItem
    /// Requested side in points.
    let side: CGFloat

    @State private var image: UIImage?

    init(store: any PhotoStore, item: PhotoItem, side: CGFloat) {
        self.store = store
        self.item = item
        self.side = side
        _image = State(initialValue: ViewerImageCache.thumb(item.id, minSide: side) ?? ViewerImageCache.full(item.id))
    }

    var body: some View {
        Rectangle()
            .fill(ViewerStyle.placeholder)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: item.id) {
                if let cached = ViewerImageCache.thumb(item.id, minSide: side) {
                    image = cached
                    return
                }
                guard let loaded = await store.thumbnail(for: item, side: side) else { return }
                ViewerImageCache.setThumb(loaded, for: item.id, side: side)
                withAnimation(ViewerStyle.ui) { image = loaded }
            }
    }
}
