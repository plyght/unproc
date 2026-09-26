import LockedCameraCapture
import SwiftUI

/// Lock-screen / Control Centre / Action Button camera. Runs while the device
/// is locked: no Photos access, no shared defaults. Photos are written into the
/// session content directory and imported by the app after unlock.
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
            if let settings = await Self.pullSettings(timeout: .milliseconds(600)) {
                SettingsStore.shared.value = settings
            }
            let root = session.sessionContentURL
            parts = Parts(
                camera: CameraController(),
                sink: SessionContentSink(root: root),
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
                    try? await session.openApplication(for: activity)
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
