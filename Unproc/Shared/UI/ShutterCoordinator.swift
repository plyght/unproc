import SwiftUI
import CoreImage
import Observation
import os

private let log = Logger(subsystem: "lol.peril.unproc", category: "shutter")

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
            log.notice("shoot ignored: camera status \(String(describing: self.camera.status), privacy: .public)")
            return
        }
        // Keep the queue shallow: at most one extra press waiting behind the active one.
        guard inFlight < 2 else { return }

        let settings = SettingsStore.shared.value
        let look = LookLibrary.look(id: settings.lookID)
        let output = settings.output

        inFlight += 1
        pressCount += 1
        flash += 1

        let previous = tail
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.process(output: output, look: look, after: previous)
            self.inFlight -= 1
        }
        tail = task
    }

    /// Drops a waiting first exposure.
    func cancelDoubleExposure() {
        pendingFirst = nil
        pendingFrame = nil
        awaitingSecondExposure = false
    }

    // MARK: - Pipeline

    private func process(output: OutputFormat, look: Look, after previous: Task<Void, Never>?) async {
        // 1. Capture (the camera serialises concurrent requests).
        let frame: CapturedFrame
        do {
            frame = try await camera.capture(output: output)
            log.notice("captured raw=\(frame.rawDNG?.count ?? -1) processed=\(frame.processed?.count ?? -1)")
        } catch {
            await previous?.value
            report(error)
            return
        }

        // 2. Develop off main, concurrently with any earlier press still finishing.
        let developed: Result<ShotImage, Error>
        do {
            developed = .success(try await ShutterWork.develop(frame))
        } catch {
            developed = .failure(error)
        }

        // 3. From here on, strictly in press order.
        await previous?.value

        let image: ShotImage
        switch developed {
        case .success(let d): image = d
        case .failure(let error):
            report(error)
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
            } else {
                pendingFirst = image
                pendingFrame = frame
                awaitingSecondExposure = true
                return
            }
        }

        // 4. Encode off main.
        let includeDNG = output == .raw && !isBlend
        let toFinish = finalImage
        let photo: DevelopedPhoto
        do {
            photo = try await ShutterWork.finish(toFinish, look: look, frame: frame, includeDNG: includeDNG)
        } catch {
            report(error)
            return
        }

        // 5. Store.
        do {
            let id = try await sink.save(photo)
            savedCount += 1
            log.notice("saved \(id, privacy: .public) jpeg=\(photo.jpeg.count)")
            await store.reload()
            log.notice("store reloaded: \(self.store.items.count) items")
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        log.error("shot failed: \(message, privacy: .public)")
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
