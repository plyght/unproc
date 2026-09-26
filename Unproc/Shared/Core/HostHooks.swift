import Foundation

/// Things only the hosting process can do. The app and the lock-screen
/// extension each provide their own implementation, so shared UI code never
/// touches `UIApplication.shared` (unavailable in extensions).
struct HostHooks {
    /// Keep the screen awake while the camera is on.
    var setIdleTimerDisabled: @MainActor (Bool) -> Void = { _ in }
    /// Lock-screen only: ask the system to unlock and continue in the full app.
    var openFullApp: (@MainActor () -> Void)? = nil
    /// True when running inside the lock-screen capture extension.
    var isLockedCapture: Bool = false
}
