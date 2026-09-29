import LockedCameraCapture
import Photos
import SwiftUI
import os

/// Lock-screen / Control Centre / Action Button camera. Runs while the device
/// is locked: no shared defaults. Each shot is written into the session content
/// directory (for the lock-screen viewer) and, with the app's Photos add access
/// (inherited by the extension), saved straight to the library. Shots that
/// couldn't be saved directly are imported by the app after unlock.
@main
struct UnprocCaptureExtension: LockedCameraCaptureExtension {
    var body: some LockedCameraCaptureExtensionScene {
        LockedCameraCaptureUIScene { session in
            CaptureRootView(session: session)
        }
    }
}

struct CaptureRootView: View {
    let session: LockedCameraCaptureSession

    /// Created exactly once, after the app's settings have been pulled, so the
    /// camera starts on the right lens and look.
    @State private var parts: Parts?

    private struct Parts {
        let camera: CameraController
        let sink: SessionContentSink
        let store: SessionPhotoStore
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let parts {
                CameraScreen(camera: parts.camera, store: parts.store, sink: parts.sink, hooks: hooks)
            }
        }
        // Inside a LockedCameraCaptureUIScene the scene phase never reports
        // .active on its own; the camera UI relies on it to run the session.
        .environment(\.scenePhase, .active)
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task {
            guard parts == nil else { return }
            Log.lockscreen.notice("extension: launch, pulling settings")
            let clock = ContinuousClock()
            let began = clock.now
            if let settings = await Self.pullSettings(timeout: .milliseconds(600)) {
                let pulledMs = CameraLogText.ms(clock.now - began)
                let text = String(describing: settings)
                Log.lockscreen.notice("extension: settings pulled in \(pulledMs, privacy: .public)ms \(text, privacy: .public)")
                SettingsStore.shared.value = settings
            } else {
                let pulledMs = CameraLogText.ms(clock.now - began)
                Log.lockscreen.notice("extension: no settings pulled (timeout or none) after \(pulledMs, privacy: .public)ms; using local")
            }
            let root = session.sessionContentURL
            Log.lockscreen.info("extension: session content \(root.path, privacy: .public)")
            let addStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            let direct = addStatus == .authorized || addStatus == .limited
            Log.lockscreen.notice("extension: Photos add status=\(addStatus.rawValue, privacy: .public) directSave=\(direct, privacy: .public)")
            parts = Parts(
                camera: CameraController(),
                // Always try: status can change while we're open, and the sink
                // re-checks it per shot without ever prompting.
                sink: SessionContentSink(root: root, library: PhotoLibrarySink(promptForAccess: false)),
                store: SessionPhotoStore(root: root)
            )
        }
    }

    private var hooks: HostHooks {
        let session = session
        return HostHooks(
            setIdleTimerDisabled: { _ in },
            openFullApp: {
                Task {
                    let activity = NSUserActivity(activityType: NSUserActivityTypeLockedCameraCapture)
                    Log.lockscreen.notice("extension: openApplication requested")
                    do {
                        try await session.openApplication(for: activity)
                        Log.lockscreen.notice("extension: openApplication succeeded")
                    } catch {
                        Log.lockscreen.error("extension: openApplication failed: \(Log.describe(error), privacy: .public)")
                    }
                }
            },
            isLockedCapture: true
        )
    }

    /// The settings the app last pushed, without ever holding the viewfinder
    /// back for long if the system is slow to answer.
    private static func pullSettings(timeout: Duration) async -> CaptureSettings? {
        await withTaskGroup(of: CaptureSettings?.self) { group in
            group.addTask { await CaptureSettingsSync.pull() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
