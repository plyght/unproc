import CoreImage
import Foundation

/// Hands live viewfinder frames from the capture engine to whoever renders them.
///
/// Frames arrive on the engine's video queue, already rotated to portrait (and
/// mirrored for the front camera), in full 4:3 (w:h = 3:4). The handler is
/// invoked synchronously on that queue, so it must be cheap (typically it just
/// stores the latest image and asks a view to redraw).
final class PreviewFrameBus: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (CIImage) -> Void)?
    private var gainEV: Float = 0
    private var latest: CIImage?

    init() {}

    /// Installs (or removes, with `nil`) the frame consumer.
    func setHandler(_ handler: (@Sendable (CIImage) -> Void)?) {
        lock.withLock { self.handler = handler }
    }

    /// Called by the camera engine for every preview frame.
    func publish(_ image: CIImage) {
        let current: (@Sendable (CIImage) -> Void)? = lock.withLock {
            latest = image
            return handler
        }
        current?(image)
    }

    /// EV the viewfinder must add to simulate a long shutter it isn't actually using.
    /// Thread-safe.
    var previewGainEV: Float {
        get { lock.withLock { gainEV } }
        set { lock.withLock { gainEV = newValue } }
    }

    /// The most recently published frame, if any (e.g. for a freeze-frame). Thread-safe.
    var latestFrame: CIImage? {
        lock.withLock { latest }
    }
}
