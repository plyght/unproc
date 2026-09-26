import LockedCameraCapture
import SwiftUI
import UIKit

@main
struct UnprocApp: App {
    @Environment(\.scenePhase) private var scenePhase

    // Created once for the lifetime of the app.
    @State private var camera = CameraController()
    @State private var store: any PhotoStore = Self.makeStore()
    @State private var sink: any CaptureSink = Self.makeSink()

    /// Demo mode (Simulator / CI screenshots) keeps photos in a local folder
    /// instead of Photos, so it never depends on library permissions.
    private static var demoRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("unproc-demo", isDirectory: true)
    }

    private static func makeStore() -> any PhotoStore {
        CameraController.isDemo ? SessionPhotoStore(root: demoRoot) : LibraryPhotoStore()
    }

    private static func makeSink() -> any CaptureSink {
        CameraController.isDemo ? SessionContentSink(root: demoRoot) : PhotoLibrarySink()
    }

    var body: some Scene {
        WindowGroup {
            CameraScreen(
                camera: camera,
                store: store,
                sink: sink,
                hooks: HostHooks(
                    setIdleTimerDisabled: { UIApplication.shared.isIdleTimerDisabled = $0 },
                    openFullApp: nil,
                    isLockedCapture: false
                )
            )
            .background(Color.black.ignoresSafeArea())
            .preferredColorScheme(.dark)
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .task { launch() }
            // Opened from the lock-screen capture extension after unlocking.
            .onContinueUserActivity(NSUserActivityTypeLockedCameraCapture) { _ in
                LockedCaptureImporter.importPending()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                LockedCaptureImporter.importPending()
            }
        }
    }

    @MainActor
    private func launch() {
        // Keep the lock-screen extension's settings in step with the app's.
        let settings = SettingsStore.shared
        settings.onChange = { CaptureSettingsSync.push($0) }
        CaptureSettingsSync.push(settings.value)

        // Bring lock-screen captures into Photos, now and as they arrive.
        let importer = LockedCaptureImporter.shared
        let store = self.store
        importer.onImport = { await store.reload() }
        importer.startObserving()
        importer.importPending()
    }
}
