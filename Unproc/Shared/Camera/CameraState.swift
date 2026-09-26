import CoreGraphics
import Foundation

/// Live + manual exposure / white balance state published by `CameraController`.
struct ExposureState: Equatable, Sendable {
    var isoRange: ClosedRange<Float>
    var shutterRange: ClosedRange<Double>
    var biasRange: ClosedRange<Float>
    /// Live values (what the sensor is doing right now; for a simulated long
    /// shutter these report the requested exposure, not the preview's).
    var iso: Float
    var shutter: Double
    var bias: Float
    var kelvin: Float
    /// Manual overrides; `nil` = automatic.
    var manualISO: Float?
    var manualShutter: Double?
    var manualKelvin: Float?
    /// Live f-number of the lens (`AVCaptureDevice.lensAperture`).
    var aperture: Float = 1.8
    /// Selectable f-numbers on a variable-aperture lens; empty when the aperture is fixed.
    var apertureStops: [Float] = []
    /// Manual f-number; `nil` = automatic / fixed.
    var manualAperture: Float? = nil

    /// Placeholder until a device reports its real ranges.
    static let initial = ExposureState(
        isoRange: 25...3200,
        shutterRange: (1.0 / 8000.0)...1.0,
        biasRange: -8...8,
        iso: 100,
        shutter: 1.0 / 60.0,
        bias: 0,
        kelvin: 5500,
        manualISO: nil,
        manualShutter: nil,
        manualKelvin: nil
    )
}

/// Live + manual focus state published by `CameraController`.
struct FocusState: Equatable, Sendable {
    var lensPosition: Float          // 0…1 live
    var manualLensPosition: Float?   // nil = auto
    var point: CGPoint?              // normalized viewfinder coords, nil = centre
    var isTracking: Bool
    var trackedRect: CGRect?         // normalized viewfinder coords

    static let initial = FocusState(
        lensPosition: 0.5,
        manualLensPosition: nil,
        point: nil,
        isTracking: false,
        trackedRect: nil
    )
}

/// Small numeric helpers, namespaced to avoid clashing with other modules.
enum CameraMath {
    static func clamp<T: Comparable>(_ value: T, _ range: ClosedRange<T>) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }

    static func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
        min(max(value, lower), upper)
    }
}
