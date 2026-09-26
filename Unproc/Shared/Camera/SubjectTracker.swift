import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Follows a subject across preview frames with Vision's object tracker.
///
/// Frames fed in are the portrait-rotated (and, for the front camera, mirrored)
/// preview buffers, so Vision runs with orientation `.up` and its results map
/// straight onto viewfinder coordinates (after flipping y).
/// Runs at most `maxRate` times a second on its own queue, dropping frames while busy.
final class SubjectTracker: @unchecked Sendable {
    /// Called on the tracker queue with the subject rect in normalized viewfinder
    /// coordinates (top-left origin), or `nil` once the subject is lost.
    typealias UpdateHandler = @Sendable (CGRect?) -> Void

    var minimumConfidence: Float = 0.3
    var maxRate: Double = 15

    private let queue = DispatchQueue(label: "lol.peril.unproc.camera.tracker", qos: .userInitiated)
    private let lock = NSLock()
    private var request: VNTrackObjectRequest?
    private var sequenceHandler: VNSequenceRequestHandler?
    private var generation = 0
    private var busy = false
    private var lastRun: TimeInterval = 0
    private var onUpdate: UpdateHandler?

    init() {}

    func setUpdateHandler(_ handler: UpdateHandler?) {
        lock.withLock { onUpdate = handler }
    }

    var isActive: Bool {
        lock.withLock { request != nil }
    }

    /// Starts tracking whatever is inside `seed` (normalized viewfinder rect).
    func start(seed: CGRect) {
        let observation = VNDetectedObjectObservation(boundingBox: ViewfinderGeometry.visionRect(fromViewfinder: seed))
        let newRequest = VNTrackObjectRequest(detectedObjectObservation: observation)
        newRequest.trackingLevel = .accurate
        lock.withLock {
            request = newRequest
            sequenceHandler = VNSequenceRequestHandler()
            generation += 1
            lastRun = 0
        }
    }

    func stop() {
        lock.withLock {
            request = nil
            sequenceHandler = nil
            generation += 1
        }
    }

    /// Offers a preview frame. Cheap when idle, throttled, or busy.
    func feed(_ pixelBuffer: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard let request, let sequenceHandler, !busy, now - lastRun >= 1.0 / maxRate else {
            lock.unlock()
            return
        }
        busy = true
        lastRun = now
        let token = generation
        lock.unlock()

        queue.async { [self] in
            run(request, sequenceHandler, on: pixelBuffer, token: token)
        }
    }

    private func run(_ request: VNTrackObjectRequest,
                     _ sequenceHandler: VNSequenceRequestHandler,
                     on pixelBuffer: CVPixelBuffer,
                     token: Int) {
        var observation: VNDetectedObjectObservation?
        do {
            try sequenceHandler.perform([request], on: pixelBuffer, orientation: .up)
            observation = request.results?.first as? VNDetectedObjectObservation
        } catch {
            observation = nil
        }

        lock.lock()
        busy = false
        let current = token == generation
        let handler = onUpdate
        lock.unlock()
        guard current else { return }

        if let observation, observation.confidence >= minimumConfidence {
            request.inputObservation = observation
            handler?(ViewfinderGeometry.viewfinderRect(fromVision: observation.boundingBox))
        } else {
            stop()
            handler?(nil)
        }
    }
}
