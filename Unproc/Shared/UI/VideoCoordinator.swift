import Foundation
import Observation
import os

/// Starts and stops recordings and saves each finished movie through the
/// sink (Photos in the app, the local folder in demo mode), then reloads
/// the store so the thumbnail shows it.
@MainActor
@Observable
final class VideoCoordinator {
    /// Movies still being finished / saved.
    private(set) var savingCount = 0
    /// Short human-readable description of the last failure (auto-clears).
    var lastError: String?
    /// Incremented when a recording starts / stops — drive haptics with them.
    private(set) var startTick = 0
    private(set) var stopTick = 0
    private(set) var savedCount = 0

    @ObservationIgnored private let camera: CameraController
    @ObservationIgnored private let sink: any CaptureSink
    @ObservationIgnored private let store: any PhotoStore
    @ObservationIgnored private var starting: Task<Void, Never>?
    @ObservationIgnored private var errorClearTask: Task<Void, Never>?

    init(camera: CameraController, sink: any CaptureSink, store: any PhotoStore) {
        self.camera = camera
        self.sink = sink
        self.store = store
    }

    var isRecording: Bool { camera.isRecording }
    var isSaving: Bool { savingCount > 0 }

    func toggle() {
        if camera.isRecording { stop() } else { start() }
    }

    func start() {
        guard starting == nil, !camera.isRecording else {
            Log.video.notice("video: start ignored (starting=\(self.starting != nil, privacy: .public) recording=\(self.camera.isRecording, privacy: .public))")
            return
        }
        let look = LookLibrary.look(id: SettingsStore.shared.value.lookID)
        Log.video.notice("video: start look=\(look.id, privacy: .public)")
        startTick += 1
        starting = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.starting = nil }
            do {
                try await self.camera.startRecording(look: look)
            } catch {
                self.report(error, stage: "start")
            }
        }
    }

    func stop() {
        guard camera.isRecording else { return }
        stopTick += 1
        savingCount += 1
        Log.video.notice("video: stop (saving \(self.savingCount, privacy: .public))")
        // Ask for time to finish the file and the save if we're backgrounded.
        let activity = ExpiringActivity.begin("unproc video")
        Task { @MainActor [weak self] in
            defer { activity.end() }
            guard let self else { return }
            await self.finishAndSave()
            self.savingCount -= 1
        }
    }

    private func finishAndSave() async {
        let clock = ContinuousClock()
        let began = clock.now
        let video: RecordedVideo
        do {
            video = try await camera.stopRecording()
        } catch {
            report(error, stage: "finish")
            return
        }
        let finishMs = CameraLogText.ms(clock.now - began)
        Log.video.notice("video: finished \(video.url.lastPathComponent, privacy: .public) \(video.width, privacy: .public)x\(video.height, privacy: .public) \(video.codec, privacy: .public) \(video.duration, privacy: .public)s frames=\(video.frames, privacy: .public) dropped=\(video.dropped, privacy: .public) in \(finishMs, privacy: .public)ms")
        do {
            let id = try await sink.saveVideo(at: video.url, capturedAt: video.startedAt)
            savedCount += 1
            Log.video.notice("video: saved \(id, privacy: .public) (total \(self.savedCount, privacy: .public))")
            await store.reload()
        } catch {
            report(error, stage: "save")
        }
    }

    private func report(_ error: Error, stage: String) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        Log.video.error("video: failed at \(stage, privacy: .public): \(message, privacy: .public) [\(Log.describe(error), privacy: .public)]")
        lastError = message.uppercased()
        errorClearTask?.cancel()
        errorClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.lastError = nil
        }
    }
}
