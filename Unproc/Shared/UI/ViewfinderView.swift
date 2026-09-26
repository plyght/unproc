import SwiftUI
import UIKit
import MetalKit
import CoreImage
import QuartzCore
import os

/// Live preview. An `MTKView` that draws the newest `PreviewFrameBus` frame
/// through gain → Look → zebras → peaking with `Developer.shared.context`.
///
/// The view is paused and drawn manually: each frame from the bus is stored in
/// a lock-protected slot and a single (coalesced) draw is scheduled on main.
/// Gestures are handled with UIKit recognisers on the MTKView so we get exact
/// touch locations; they are reported in normalised coordinates of the 3:4
/// frame ((0,0) top-left, (1,1) bottom-right).
struct ViewfinderView: UIViewRepresentable {
    let bus: PreviewFrameBus
    var look: Look = .zero
    var zebras: Bool = false
    var peaking: Bool = false

    var onTap: ((CGPoint) -> Void)? = nil
    var onDoubleTap: ((CGPoint) -> Void)? = nil
    var onLongPress: ((CGPoint) -> Void)? = nil
    /// +1 = swipe left (next), -1 = swipe right (previous).
    var onSwipe: ((Int) -> Void)? = nil
    /// Two-finger pinch: spread to zoom in, pinch to zoom out.
    var onPinch: ((Pinch) -> Void)? = nil

    enum Pinch {
        case began
        /// Cumulative scale since the pinch began (1 = unchanged).
        case changed(CGFloat)
        case ended
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let coordinator = context.coordinator
        let view = MTKView(frame: .zero, device: coordinator.device)
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.backgroundColor = .black
        view.isOpaque = true
        view.delegate = coordinator
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Viewfinder"
        view.accessibilityIdentifier = "viewfinder"
        if let layer = view.layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        }
        Log.ui.info("viewfinder: make view metal=\(coordinator.device != nil, privacy: .public)")
        coordinator.view = view
        coordinator.installGestures(on: view)
        apply(to: coordinator)

        let slot = coordinator.slot
        bus.setHandler { [weak coordinator] image in
            // Video queue. Store the frame; schedule at most one pending draw.
            guard slot.store(image) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    coordinator?.drawLatest()
                }
            }
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        apply(to: context.coordinator)
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        Log.ui.info("viewfinder: dismantle")
        coordinator.bus?.setHandler(nil)
        coordinator.view = nil
        uiView.delegate = nil
    }

    private func apply(to coordinator: Coordinator) {
        coordinator.bus = bus
        coordinator.look = look
        coordinator.zebras = zebras
        coordinator.peaking = peaking
        coordinator.onTap = onTap
        coordinator.onDoubleTap = onDoubleTap
        coordinator.onLongPress = onLongPress
        coordinator.onSwipe = onSwipe
        coordinator.onPinch = onPinch
    }

    // MARK: - Frame slot

    /// Latest-frame mailbox shared between the video queue and main.
    final class FrameSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var image: CIImage?
        private var drawPending = false

        /// Stores the frame. Returns true when the caller should schedule a draw.
        func store(_ newImage: CIImage) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            image = newImage
            if drawPending { return false }
            drawPending = true
            return true
        }

        /// Clears the pending flag and returns the newest frame.
        func take() -> CIImage? {
            lock.lock()
            defer { lock.unlock() }
            drawPending = false
            return image
        }

        func peek() -> CIImage? {
            lock.lock()
            defer { lock.unlock() }
            return image
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice?
        private let queue: MTLCommandQueue?
        let slot = FrameSlot()
        private let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        private let startTime = CACurrentMediaTime()

        weak var view: MTKView?
        var bus: PreviewFrameBus?
        var look: Look = .zero
        var zebras = false
        var peaking = false
        var onTap: ((CGPoint) -> Void)?
        var onDoubleTap: ((CGPoint) -> Void)?
        var onLongPress: ((CGPoint) -> Void)?
        var onSwipe: ((Int) -> Void)?
        var onPinch: ((Pinch) -> Void)?

        // Logging state (first frame / size changes only, never per frame).
        private var renderedFrames = 0
        private var lastFrameExtent: CGRect = .null
        private var loggedRenderSkip = false

        override init() {
            let device = MTLCreateSystemDefaultDevice()
            self.device = device
            self.queue = device?.makeCommandQueue()
            super.init()
            if device == nil {
                Log.ui.error("viewfinder: no Metal device; preview cannot render")
            } else if queue == nil {
                Log.ui.error("viewfinder: could not create Metal command queue")
            }
        }

        // MARK: Drawing

        func drawLatest() {
            guard let view, view.window != nil else {
                _ = slot.take()
                return
            }
            view.draw()   // → draw(in:)
        }

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            Log.ui.info("viewfinder: drawable size -> \(String(describing: size), privacy: .public)")
        }

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated {
                render(in: view)
            }
        }

        private func render(in view: MTKView) {
            // Always consume the pending flag so the next frame schedules a draw.
            guard let frame = slot.take() else { return }
            guard let queue,
                  let drawable = view.currentDrawable,
                  let commandBuffer = queue.makeCommandBuffer() else {
                if !loggedRenderSkip {
                    loggedRenderSkip = true
                    Log.ui.debug("viewfinder: render skipped (no queue/drawable/command buffer); logged once")
                }
                return
            }

            let size = view.drawableSize
            guard size.width > 0, size.height > 0, !frame.extent.isInfinite,
                  frame.extent.width > 0, frame.extent.height > 0 else {
                if !loggedRenderSkip {
                    loggedRenderSkip = true
                    Log.ui.debug("viewfinder: render skipped size=\(String(describing: size), privacy: .public) frame=\(String(describing: frame.extent), privacy: .public); logged once")
                }
                return
            }
            let bounds = CGRect(origin: .zero, size: size)
            if frame.extent != lastFrameExtent {
                let previous = lastFrameExtent
                lastFrameExtent = frame.extent
                Log.ui.debug("viewfinder: frame extent \(String(describing: previous), privacy: .public) -> \(String(describing: frame.extent), privacy: .public) drawable=\(String(describing: size), privacy: .public)")
            }
            if renderedFrames == 0 {
                Log.ui.notice("viewfinder: first frame extent=\(String(describing: frame.extent), privacy: .public) drawable=\(String(describing: size), privacy: .public)")
            }
            renderedFrames &+= 1

            var image = frame
            let gainEV = bus?.previewGainEV ?? 0
            if abs(gainEV) > 0.01 {
                image = ViewfinderEffects.gain(image, ev: gainEV)
            }
            image = LookLibrary.apply(look, to: image)

            // Aspect-fill into the drawable (effects are computed at display size,
            // so zebra stripes / peaking stay a constant on-screen size).
            let extent = image.extent
            let scale = max(size.width / extent.width, size.height / extent.height)
            let dx = (size.width - extent.width * scale) / 2
            let dy = (size.height - extent.height * scale) / 2
            image = image
                .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: dx, y: dy))
                .cropped(to: bounds)

            if zebras {
                let t = CACurrentMediaTime() - startTime
                let phase = CGFloat((t * 24).truncatingRemainder(dividingBy: 10_000))
                image = ViewfinderEffects.zebras(image, phase: phase)
            }
            if peaking {
                image = ViewfinderEffects.peaking(image)
            }

            image = image
                .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: bounds))
                .cropped(to: bounds)

            Developer.shared.context.render(
                image,
                to: drawable.texture,
                commandBuffer: commandBuffer,
                bounds: bounds,
                colorSpace: colorSpace
            )
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        // MARK: Gestures

        func installGestures(on view: UIView) {
            view.isUserInteractionEnabled = true

            let double = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            double.numberOfTapsRequired = 2
            view.addGestureRecognizer(double)

            let single = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            single.numberOfTapsRequired = 1
            single.require(toFail: double)
            view.addGestureRecognizer(single)

            let long = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            long.minimumPressDuration = 0.45
            view.addGestureRecognizer(long)

            let left = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            left.direction = .left
            view.addGestureRecognizer(left)

            let right = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            right.direction = .right
            view.addGestureRecognizer(right)

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            view.addGestureRecognizer(pinch)
        }

        /// Maps a point in the view into normalised coordinates of the 3:4 frame,
        /// taking the aspect-fill crop into account.
        private func normalized(_ location: CGPoint, in view: UIView) -> CGPoint {
            let w = view.bounds.width, h = view.bounds.height
            guard w > 0, h > 0 else { return CGPoint(x: 0.5, y: 0.5) }
            let frameW: CGFloat = 3, frameH: CGFloat = 4
            let s = max(w / frameW, h / frameH)
            let shownW = frameW * s, shownH = frameH * s
            let ox = (w - shownW) / 2, oy = (h - shownH) / 2
            let x = (location.x - ox) / shownW
            let y = (location.y - oy) / shownH
            return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let point = normalized(recognizer.location(in: view), in: view)
            Log.ui.debug("viewfinder: tap \(String(describing: point), privacy: .public)")
            onTap?(point)
        }

        @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let point = normalized(recognizer.location(in: view), in: view)
            Log.ui.debug("viewfinder: double tap \(String(describing: point), privacy: .public)")
            onDoubleTap?(point)
        }

        @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let view = recognizer.view else { return }
            let point = normalized(recognizer.location(in: view), in: view)
            Log.ui.debug("viewfinder: long press \(String(describing: point), privacy: .public)")
            onLongPress?(point)
        }

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                Log.ui.debug("viewfinder: pinch began")
                onPinch?(.began)
                onPinch?(.changed(recognizer.scale))
            case .changed:
                onPinch?(.changed(recognizer.scale))
            case .ended, .cancelled, .failed:
                Log.ui.debug("viewfinder: pinch ended scale=\(Double(recognizer.scale), privacy: .public)")
                onPinch?(.ended)
            default:
                break
            }
        }

        @objc private func handleSwipe(_ recognizer: UISwipeGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            Log.ui.debug("viewfinder: swipe \(recognizer.direction == .left ? "left" : "right", privacy: .public)")
            onSwipe?(recognizer.direction == .left ? 1 : -1)
        }
    }
}
