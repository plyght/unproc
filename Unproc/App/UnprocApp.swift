import LockedCameraCapture
import SwiftUI
import UIKit
import os

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

    /// Demo mode normally avoids Photos; `-UNPROC_PHOTOS` forces the real
    /// library path (used by the CI test that exercises saving to Photos).
    private static var useLocalStore: Bool {
        CameraController.isDemo && !ProcessInfo.processInfo.arguments.contains("-UNPROC_PHOTOS")
    }

    private static func makeStore() -> any PhotoStore {
        let local = useLocalStore
        let target = local ? "session(local folder)" : "photo library"
        let demo = CameraController.isDemo
        Log.app.info("app: store=\(target, privacy: .public) demo=\(demo, privacy: .public)")
        return local ? SessionPhotoStore(root: demoRoot) : LibraryPhotoStore()
    }

    private static func makeSink() -> any CaptureSink {
        let local = useLocalStore
        let target = local ? "session(local folder) " + demoRoot.path : "photo library"
        Log.app.info("app: sink=\(target, privacy: .public)")
        return local ? SessionContentSink(root: demoRoot) : PhotoLibrarySink()
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
                Log.lockscreen.notice("app: continued locked-camera-capture activity")
                LockedCaptureImporter.importPending()
            }
        }
        .onChange(of: scenePhase) { old, phase in
            Log.app.notice("app: scenePhase \(String(describing: old), privacy: .public) -> \(String(describing: phase), privacy: .public)")
            if phase == .active {
                LockedCaptureImporter.importPending()
            }
        }
    }

    @MainActor
    private func launch() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let args = ProcessInfo.processInfo.arguments.dropFirst().joined(separator: " ")
        let system = UIDevice.current.systemVersion
        let model = UIDevice.current.model
        let demo = CameraController.isDemo
        Log.app.notice("app: launch v\(version, privacy: .public) (\(build, privacy: .public)) iOS \(system, privacy: .public) model=\(model, privacy: .public) demo=\(demo, privacy: .public) args=[\(args, privacy: .public)]")
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
