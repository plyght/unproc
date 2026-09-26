import AppIntents
import Foundation

/// The capture intent that ties the app, the lock-screen capture extension and
/// the Control Centre / Lock Screen control together.
///
/// It must be compiled into every one of those targets (not a shared framework)
/// or the system won't discover it.
struct UnprocCaptureIntent: CameraCaptureIntent {
    /// Settings handed from the app to the lock-screen extension (≤ 4 KB).
    typealias AppContext = CaptureSettings

    static let title: LocalizedStringResource = "Open unproc"
    static let description = IntentDescription(
        "Opens the unproc camera. Zero processing, straight off the sensor."
    )

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}

/// Moves `CaptureSettings` between the app and the lock-screen extension
/// through the capture intent's app context (the extension has no shared
/// container or shared defaults).
enum CaptureSettingsSync {
    /// App side: publish the latest settings so the extension starts the same way.
    static func push(_ settings: CaptureSettings) {
        Task {
            try? await UnprocCaptureIntent.updateAppContext(settings)
        }
    }

    /// Extension side: the settings the app last pushed, if any.
    static func pull() async -> CaptureSettings? {
        do {
            return try await UnprocCaptureIntent.appContext
        } catch {
            return nil
        }
    }
}
