import Foundation
import Observation

/// What a single press of the shutter writes out.
enum OutputFormat: String, Codable, CaseIterable, Sendable {
    /// A developed, graded JPEG only.
    case jpeg
    /// The developed JPEG plus the untouched RAW (DNG) as one Photos asset.
    case raw
}

/// Which flavour of RAW the sensor is read out as.
enum RawFlavor: String, Codable, CaseIterable, Sendable {
    /// Plain Bayer RAW: straight off the sensor, no Apple processing at all.
    case bayer
    /// Apple ProRAW: demosaiced linear DNG (multi-frame, but no tone mapping baked in).
    case proRAW
}

/// Everything the user can change. Codable so it can be handed to the
/// lock-screen extension through the capture intent's app context (≤ 4 KB).
struct CaptureSettings: Codable, Equatable, Sendable {
    var output: OutputFormat = .jpeg
    var rawFlavor: RawFlavor = .bayer
    var lookID: String = "zero"
    var doubleExposure: Bool = false
    var proMode: Bool = false
    var zebras: Bool = true
    var peaking: Bool = false
    /// `Lens.id` of the last lens used, restored on launch.
    var lensID: String? = nil
}

/// Observable, persisted wrapper around `CaptureSettings`.
///
/// The app persists to `UserDefaults.standard`. The lock-screen extension has
/// no shared container, so it seeds itself from `UnprocCaptureIntent.appContext`
/// (see `CaptureSettingsSync`) and keeps its own defaults.
@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    var value: CaptureSettings {
        didSet {
            guard value != oldValue else { return }
            persist()
            onChange?(value)
        }
    }

    /// Hook used to push changes into the capture intent's app context.
    @ObservationIgnored var onChange: ((CaptureSettings) -> Void)?

    private static let key = "unproc.settings.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(CaptureSettings.self, from: data) {
            value = decoded
        } else {
            value = CaptureSettings()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
