import Foundation
import Observation
import os

// The widget target compiles this file without Log.swift.
#if UNPROC_WIDGETS
private let settingsLog = Logger(subsystem: "lol.peril.unproc", category: "settings")
#else
private let settingsLog = Log.settings
#endif

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

/// Flash for the next shot.
enum FlashSetting: String, Codable, CaseIterable, Sendable {
    case off, auto, on
}

/// Accent ids: "orange" (unproc's signal orange) or a `DeviceModel.Finish.id`.
enum AccentID {
    static let orange = "orange"
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
    /// "orange" or one of the phone's finishes (see `DeviceModel`). Older
    /// builds stored "auto" here; anything unknown resolves to orange.
    var accent: String = AccentID.orange
    var flash: FlashSetting = .off
    /// Left-handed layout: thumbnail and lens/zoom button swap sides.
    var lefty: Bool = false

    // Spelled out (not synthesized) so helpers can name the type in signatures.
    enum CodingKeys: String, CodingKey {
        case output, rawFlavor, lookID, doubleExposure, proMode, zebras, peaking, lensID, ratio, accent, flash, lefty
    }

    init() {}

    // Tolerant decoding: settings saved by an older build (or pushed through
    // the capture intent) may lack newer keys; those fall back to defaults.
    init(from decoder: Decoder) throws {
        let c: KeyedDecodingContainer<CodingKeys>
        do {
            c = try decoder.container(keyedBy: CodingKeys.self)
        } catch {
            settingsLog.error("settings: decode container failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        let d = CaptureSettings()
        output = Self.field(c, .output, d.output)
        rawFlavor = Self.field(c, .rawFlavor, d.rawFlavor)
        lookID = Self.field(c, .lookID, d.lookID)
        doubleExposure = Self.field(c, .doubleExposure, d.doubleExposure)
        proMode = Self.field(c, .proMode, d.proMode)
        zebras = Self.field(c, .zebras, d.zebras)
        peaking = Self.field(c, .peaking, d.peaking)
        lensID = Self.field(c, .lensID, d.lensID)
        ratio = Self.field(c, .ratio, d.ratio)
        accent = Self.field(c, .accent, d.accent)
        flash = Self.field(c, .flash, d.flash)
        lefty = Self.field(c, .lefty, d.lefty)
    }

    /// `decodeIfPresent` with a fallback; failures are logged, never thrown.
    private static func field<T: Decodable>(_ c: KeyedDecodingContainer<CodingKeys>,
                                            _ key: CodingKeys, _ fallback: T) -> T {
        do {
            if let value = try c.decodeIfPresent(T.self, forKey: key) { return value }
            settingsLog.debug("settings: key \(key.stringValue, privacy: .public) missing, using default")
            return fallback
        } catch {
            settingsLog.error("settings: key \(key.stringValue, privacy: .public) failed to decode, using default: \(error.localizedDescription, privacy: .public)")
            return fallback
        }
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
        let data = UserDefaults.standard.data(forKey: Self.key)
        var decoded: CaptureSettings?
        if let data {
            do {
                decoded = try JSONDecoder().decode(CaptureSettings.self, from: data)
            } catch {
                settingsLog.error("settings: stored settings (\(data.count, privacy: .public)B) failed to decode, using defaults: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            settingsLog.info("settings: nothing stored, using defaults")
        }
        if let decoded {
            value = decoded
        } else {
            value = CaptureSettings()
        }
        let loaded = String(describing: value)
        settingsLog.info("settings: loaded \(loaded, privacy: .public)")
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(value)
            UserDefaults.standard.set(data, forKey: Self.key)
            let saved = String(describing: value)
            settingsLog.debug("settings: persisted \(data.count, privacy: .public)B \(saved, privacy: .public)")
        } catch {
            settingsLog.error("settings: encode failed, not persisted: \(error.localizedDescription, privacy: .public)")
        }
    }
}
