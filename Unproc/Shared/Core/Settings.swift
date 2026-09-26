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

/// Frame shape of the photo (and viewfinder). The sensor is 4:3; other
/// ratios are centre crops applied during development — the DNG stays full.
enum FrameRatio: String, Codable, CaseIterable, Sendable {
    case fourThree = "4:3"
    case threeTwo = "3:2"
    case sixteenNine = "16:9"
    case square = "1:1"

    /// Long side / short side.
    var longOverShort: Double {
        switch self {
        case .fourThree: 4.0 / 3.0
        case .threeTwo: 3.0 / 2.0
        case .sixteenNine: 16.0 / 9.0
        case .square: 1
        }
    }

    /// Width / height when the phone is held upright.
    var portraitAspect: Double { 1 / longOverShort }
}

/// Where the accent colour comes from.
enum AccentMode: String, Codable, CaseIterable, Sendable {
    /// The phone's own finish, when iOS will tell us (falls back to orange).
    case auto
    /// unproc's signal orange.
    case orange
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
    var ratio: FrameRatio = .fourThree
    var accent: AccentMode = .auto

    init() {}

    // Tolerant decoding: settings saved by an older build (or pushed through
    // the capture intent) may lack newer keys; those fall back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CaptureSettings()
        output = (try? c.decodeIfPresent(OutputFormat.self, forKey: .output)) ?? d.output
        rawFlavor = (try? c.decodeIfPresent(RawFlavor.self, forKey: .rawFlavor)) ?? d.rawFlavor
        lookID = (try? c.decodeIfPresent(String.self, forKey: .lookID)) ?? d.lookID
        doubleExposure = (try? c.decodeIfPresent(Bool.self, forKey: .doubleExposure)) ?? d.doubleExposure
        proMode = (try? c.decodeIfPresent(Bool.self, forKey: .proMode)) ?? d.proMode
        zebras = (try? c.decodeIfPresent(Bool.self, forKey: .zebras)) ?? d.zebras
        peaking = (try? c.decodeIfPresent(Bool.self, forKey: .peaking)) ?? d.peaking
        lensID = (try? c.decodeIfPresent(String.self, forKey: .lensID)) ?? d.lensID
        ratio = (try? c.decodeIfPresent(FrameRatio.self, forKey: .ratio)) ?? d.ratio
        accent = (try? c.decodeIfPresent(AccentMode.self, forKey: .accent)) ?? d.accent
    }
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
