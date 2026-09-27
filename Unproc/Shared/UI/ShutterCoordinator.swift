import SwiftUI
import CoreImage
import Observation
import os

private let log = Log.capture

/// Runs one press of the shutter end to end:
/// capture → develop (off main) → (double exposure) → finish with Look → sink → store reload.
///
/// Presses may overlap: a second press while the first is still developing
/// captures immediately (the camera serialises captures), develops in parallel,
/// and is then paired / finished / saved strictly in press order.
@MainActor
@Observable
final class ShutterCoordinator {
    /// True while any press is still being captured, developed or saved.
    var isBusy: Bool { inFlight > 0 }
    /// A first double-exposure frame is waiting for its partner.
    private(set) var awaitingSecondExposure = false
    /// Short human-readable description of the last failure (auto-clears).
    var lastError: String?
    /// Incremented each time the shutter fires — drive a viewfinder blink with it.
    private(set) var flash = 0
    /// Incremented on every accepted press — drive haptics with it.
    private(set) var pressCount = 0
    /// Incremented after each photo is saved.
    private(set) var savedCount = 0

    private var inFlight = 0

    @ObservationIgnored private let camera: CameraController
    @ObservationIgnored private let sink: any CaptureSink
    @ObservationIgnored private let store: any PhotoStore

    /// Double exposure: the first developed image and its frame. Survives
    /// exposure / shutter / lens changes; cleared only by `cancelDoubleExposure()`,
    /// by blending, or by turning double exposure off.
    @ObservationIgnored private var pendingFirst: ShotImage?
    @ObservationIgnored private var pendingFrame: CapturedFrame?

    /// Tail of the ordered post-processing chain.
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var errorClearTask: Task<Void, Never>?

    init(camera: CameraController, sink: any CaptureSink, store: any PhotoStore) {
        self.camera = camera
        self.sink = sink
        self.store = store
    }

    // MARK: - Public

    func shoot() {
        guard camera.status == .running else {
            log.notice("shutter: press ignored, camera status \(String(describing: self.camera.status), privacy: .public)")
            return
        }
        // Keep the queue shallow: at most one extra press waiting behind the active one.
        guard inFlight < 2 else {
            log.notice("shutter: press dropped, queue full inFlight=\(self.inFlight, privacy: .public)")
            return
        }

        let settings = SettingsStore.shared.value
        let look = LookLibrary.look(id: settings.lookID)
        let output = settings.output
        let ratio = settings.ratio

        inFlight += 1
        pressCount += 1
        flash += 1
        let seq = pressCount
        log.notice("shutter: press #\(seq, privacy: .public) queue=\(self.inFlight, privacy: .public) output=\(String(describing: output), privacy: .public) look=\(look.id, privacy: .public) ratio=\(String(describing: ratio), privacy: .public) double=\(settings.doubleExposure, privacy: .public) awaitingSecond=\(self.awaitingSecondExposure, privacy: .public)")

        let previous = tail
        // Ask for time to finish if we're backgrounded / the lock-screen
        // extension is dismissed mid-shot, so the photo still gets written.
        let activity = ExpiringActivity.begin("unproc shot #\(seq)")
        let task = Task { @MainActor [weak self] in
            defer { activity.end() }
            guard let self else { return }
            await self.process(seq: seq, output: output, look: look, ratio: ratio, after: previous)
            self.inFlight -= 1
            log.debug("shutter: #\(seq, privacy: .public) done, queue=\(self.inFlight, privacy: .public)")
        }
        tail = task
    }

    /// Drops a waiting first exposure.
    func cancelDoubleExposure() {
        log.info("shutter: double exposure cancelled (had first=\(self.pendingFirst != nil, privacy: .public))")
        pendingFirst = nil
        pendingFrame = nil
        awaitingSecondExposure = false
    }

    // MARK: - Pipeline

    private func process(seq: Int, output: OutputFormat, look: Look, ratio: FrameRatio, after previous: Task<Void, Never>?) async {
        let clock = ContinuousClock()
        let began = clock.now
        var stage = began
        func lap() -> Double {
            let now = clock.now
            defer { stage = now }
            return CameraLogText.ms(now - stage)
        }

        // 1. Capture (the camera serialises concurrent requests).
        let frame: CapturedFrame
        do {
            frame = try await camera.capture(output: output)
            let captureMs = lap()
            log.notice("shutter: #\(seq, privacy: .public) captured raw=\(frame.rawDNG?.count ?? -1, privacy: .public) flavor=\(frame.rawFlavor?.rawValue ?? "nil", privacy: .public) processed=\(frame.processed?.count ?? -1, privacy: .public) lens=\(frame.lens.id, privacy: .public) shutter=\(frame.exposureDuration ?? -1, privacy: .public) iso=\(frame.iso ?? -1, privacy: .public) in \(captureMs, privacy: .public)ms")
        } catch {
            let captureMs = lap()
            log.error("shutter: #\(seq, privacy: .public) capture failed after \(captureMs, privacy: .public)ms: \(Log.describe(error), privacy: .public)")
            await previous?.value
            report(error, stage: "capture", seq: seq)
            return
        }

        // 2. Develop off main, concurrently with any earlier press still finishing.
        let developed: Result<ShotImage, Error>
        do {
            let shot = try await ShutterWork.develop(frame)
            developed = .success(ShotImage(image: RatioCrop.crop(shot.image, to: ratio)))
            let developMs = lap()
            log.info("shutter: #\(seq, privacy: .public) developed extent=\(String(describing: shot.image.extent), privacy: .public) ratio=\(String(describing: ratio), privacy: .public) in \(developMs, privacy: .public)ms")
        } catch {
            developed = .failure(error)
            let developMs = lap()
            log.error("shutter: #\(seq, privacy: .public) develop failed after \(developMs, privacy: .public)ms: \(Log.describe(error), privacy: .public)")
        }

        // 3. From here on, strictly in press order.
        await previous?.value
        let waitMs = lap()
        log.debug("shutter: #\(seq, privacy: .public) waited \(waitMs, privacy: .public)ms for earlier press")

        let image: ShotImage
        switch developed {
        case .success(let d): image = d
        case .failure(let error):
            report(error, stage: "develop", seq: seq)
            return
        }

        var finalImage = image
        var isBlend = false
        if SettingsStore.shared.value.doubleExposure {
            if let first = pendingFirst {
                let firstImage = first.image
                let secondImage = image.image
                finalImage = ShotImage(image: MultiExposure.blend(firstImage, secondImage))
                isBlend = true
                pendingFirst = nil
                pendingFrame = nil
                awaitingSecondExposure = false
                log.notice("shutter: #\(seq, privacy: .public) double exposure: second frame, blended")
            } else {
                pendingFirst = image
                pendingFrame = frame
                awaitingSecondExposure = true
                log.notice("shutter: #\(seq, privacy: .public) double exposure: first frame held, awaiting second")
                return
            }
        } else if pendingFirst != nil {
            log.debug("shutter: #\(seq, privacy: .public) double exposure off but a first frame is still held")
        }

        // 4. Encode off main.
        let includeDNG = output == .raw && !isBlend
        let toFinish = finalImage
        let photo: DevelopedPhoto
        do {
            photo = try await ShutterWork.finish(toFinish, look: look, frame: frame, includeDNG: includeDNG)
            let finishMs = lap()
            log.info("shutter: #\(seq, privacy: .public) finished jpeg=\(photo.jpeg.count, privacy: .public)B dng=\(photo.dng?.count ?? 0, privacy: .public)B blend=\(isBlend, privacy: .public) in \(finishMs, privacy: .public)ms")
        } catch {
            let finishMs = lap()
            log.error("shutter: #\(seq, privacy: .public) finish failed after \(finishMs, privacy: .public)ms: \(Log.describe(error), privacy: .public)")
            report(error, stage: "finish", seq: seq)
            return
        }

        // 5. Store.
        do {
            let id = try await sink.save(photo)
            savedCount += 1
            let saveMs = lap()
            log.notice("shutter: #\(seq, privacy: .public) saved \(id, privacy: .public) jpeg=\(photo.jpeg.count, privacy: .public)B in \(saveMs, privacy: .public)ms (total saved \(self.savedCount, privacy: .public))")
            await store.reload()
            let reloadMs = lap()
            let totalMs = CameraLogText.ms(clock.now - began)
            log.notice("shutter: #\(seq, privacy: .public) store reloaded \(self.store.items.count, privacy: .public) items in \(reloadMs, privacy: .public)ms; total \(totalMs, privacy: .public)ms")
        } catch {
            let saveMs = lap()
            log.error("shutter: #\(seq, privacy: .public) save failed after \(saveMs, privacy: .public)ms: \(Log.describe(error), privacy: .public)")
            report(error, stage: "save", seq: seq)
        }
    }

    private func report(_ error: Error, stage: String = "unknown", seq: Int = 0) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        log.error("shutter: #\(seq, privacy: .public) shot failed at \(stage, privacy: .public): \(message, privacy: .public) [\(Log.describe(error), privacy: .public)]")
        lastError = message.uppercased()
        errorClearTask?.cancel()
        errorClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.lastError = nil
        }
    }
}

/// Sendable box so a developed `CIImage` can cross isolation domains.
/// (`CIImage` is immutable; the box only exists to satisfy the checker.)
struct ShotImage: @unchecked Sendable {
    let image: CIImage
}

/// The CPU/GPU-heavy steps, always run on the concurrent pool (never on main).
enum ShutterWork {
    @concurrent
    static func develop(_ frame: CapturedFrame) async throws -> ShotImage {
        ShotImage(image: try Developer.shared.develop(frame))
    }

    @concurrent
    static func finish(_ image: ShotImage, look: Look, frame: CapturedFrame, includeDNG: Bool) async throws -> DevelopedPhoto {
        try Developer.shared.finish(image.image, look: look, frame: frame, includeDNG: includeDNG)
    }
}
