import LockedCameraCapture
import SwiftUI
import UIKit

@main
struct UnprocApp: App {
    @Environment(\.scenePhase) private var scenePhase

    // Created once for the lifetime of the app.
    @State private var camera = CameraController()
    @State private var store = LibraryPhotoStore()
    @State private var sink = PhotoLibrarySink()

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
