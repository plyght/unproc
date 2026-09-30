import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import os

/// "Develops" scene-referred Apple Log video the way `Developer` develops RAW
/// stills: a neutral, deterministic tone curve instead of Apple's video look
/// (display tone curve, shadow lifting, saturation).
///
/// Pure math (unit tested). Per pixel:
/// 1. Apple Log code value → scene-linear (exact inverse of the Apple Log
///    Profile, per channel), Rec.2020 primaries.
/// 2. Rec.2020 → Rec.709 linear (3×3), negatives clipped.
/// 3. Filmic curve (Hable form: gentle toe, soft highlight shoulder), scaled so
///    18 % grey lands near display 0.46 like the RAW photo pipeline, and
///    scene-linear `whiteScene` reaches white (no hard clip of skies).
/// 4. Rec.709 OETF → display code value.
///
/// All of it is folded into one 3D cube (`cube(dimension:)`), so the GPU does
/// a single lookup per pixel (`LogDevelopFilter`).
enum LogDevelop {
    /// Master switch: prefer Apple Log formats in SDR video mode (Pro iPhones).
    static let enabled = true

    // MARK: Apple Log Profile (Apple white paper; colour-science apple_log_profile)

    static let r0 = -0.05641088
    static let rt = 0.01
    static let c = 47.28711236
    static let beta = 0.00964052
    static let gamma = 0.08550479
    static let delta = 0.69336945
    /// Code value at `rt`, where the curve switches from quadratic to log.
    static let pt = c * (rt - r0) * (rt - r0)

    /// Scene-linear reflectance → Apple Log code value (0…1).
    static func encode(_ r: Double) -> Double {
        if r < r0 { return 0 }
        if r < rt { return c * (r - r0) * (r - r0) }
        return gamma * log2(r + beta) + delta
    }

    /// Apple Log code value → scene-linear (exact inverse of `encode`).
    static func decode(_ p: Double) -> Double {
        if p < 0 { return r0 }
        if p < pt { return (p / c).squareRoot() + r0 }
        return pow(2, (p - delta) / gamma) - beta
    }

    // MARK: Tone curve

    /// Hable filmic constants (shoulder, linear, toe).
    static let shoulderStrength = 0.15
    static let linearStrength = 0.50
    static let linearAngle = 0.10
    static let toeStrength = 0.20
    static let toeNumerator = 0.02
    static let toeDenominator = 0.30
    /// Curve-space white point.
    static let whitePoint = 40.0
    /// Scene-linear → curve space. With `whitePoint` this puts 18 % grey at
    /// display ≈ 0.46 (Rec.709 code) and white at scene-linear ≈ 8.6
    /// (≈ 5.6 stops over grey; Apple Log itself tops out at ≈ 12).
    static let exposureScale = 4.6611
    /// Scene-linear value that reaches display white.
    static var whiteScene: Double { whitePoint / exposureScale }
    /// Display code value 18 % grey is aimed at (the RAW pipeline's mid-grey).
    static let greyTarget = 0.46

    private static func hable(_ x: Double) -> Double {
        let a = shoulderStrength, b = linearStrength, cc = linearAngle
        let d = toeStrength, e = toeNumerator, f = toeDenominator
        return ((x * (a * x + cc * b) + d * e) / (x * (a * x + b) + d * f)) - e / f
    }

    private static let hableWhite = hable(whitePoint)

    /// Scene-linear → display-linear 0…1 (no shadow lift: 0 → 0).
    static func toneLinear(_ scene: Double) -> Double {
        let x = min(max(scene, 0), whiteScene) * exposureScale
        return min(max(hable(x) / hableWhite, 0), 1)
    }

    /// Rec.709 OETF (display-linear → code value).
    static func oetf709(_ l: Double) -> Double {
        let v = max(l, 0)
        return v < 0.018 ? 4.5 * v : 1.099 * pow(v, 0.45) - 0.099
    }

    /// Scene-linear → Rec.709 display code value 0…1.
    static func tone(_ scene: Double) -> Double {
        min(max(oetf709(toneLinear(scene)), 0), 1)
    }

    // MARK: Primaries

    /// Linear Rec.2020 → linear Rec.709 (ITU-R BT.2087), rows = output R, G, B.
    static let rec2020To709: [SIMD3<Double>] = [
        SIMD3(1.6605, -0.5876, -0.0728),
        SIMD3(-0.1246, 1.1329, -0.0083),
        SIMD3(-0.0182, -0.1006, 1.1187),
    ]

    /// One Apple Log RGB code value → Rec.709 display code values.
    static func develop(_ log: SIMD3<Double>) -> SIMD3<Double> {
        let lin = SIMD3(decode(log.x), decode(log.y), decode(log.z))
        let m = rec2020To709
        let r = (m[0] * lin).sum(), g = (m[1] * lin).sum(), b = (m[2] * lin).sum()
        return SIMD3(tone(r), tone(g), tone(b))
    }

    // MARK: Cube

    /// Cube edge length used at runtime (64³ RGBA float = 4 MB).
    static let dimension = 64

    /// `CIColorCube` data: input = Apple Log code values, output = Rec.709
    /// display code values (red fastest, then green, then blue).
    static func cube(dimension n: Int) -> Data {
        LUTBuilder.cube(dimension: n) { input in
            let o = develop(SIMD3(Double(input.x), Double(input.y), Double(input.z)))
            return GradeRGB(Float(o.x), Float(o.y), Float(o.z))
        }
    }
}

/// The Core Image side of `LogDevelop`: one cube lookup, then the result is
/// tagged Rec.709 and matched into the working space, so the Look, the
/// viewfinder and the recorder treat it like any other frame. Shared by the
/// viewfinder and the recorder so preview == recording.
enum LogDevelopFilter {
    /// Built once (a few ms); `prewarm()` builds it off the video queue.
    static let cubeData: Data = {
        let clock = ContinuousClock()
        let began = clock.now
        let data = LogDevelop.cube(dimension: LogDevelop.dimension)
        let ms = CameraLogText.ms(clock.now - began)
        Log.video.notice("log: built develop cube dim=\(LogDevelop.dimension, privacy: .public) bytes=\(data.count, privacy: .public) in \(ms, privacy: .public)ms grey=\(LogDevelop.tone(0.18), privacy: .public) whiteScene=\(LogDevelop.whiteScene, privacy: .public)")
        return data
    }()

    /// What the cube's output values are encoded in.
    static let outputColorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

    static func prewarm() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = cubeData
        }
    }

    /// A Log camera buffer as raw code values (no colour management: Core
    /// Image must not linearise Apple Log with some other transfer function).
    static func image(from buffer: CVPixelBuffer) -> CIImage {
        CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
    }

    /// Raw Log code values → developed image in the working space.
    static func develop(_ log: CIImage) -> CIImage {
        let filter = CIFilter.colorCube()
        filter.inputImage = log
        filter.cubeDimension = Float(LogDevelop.dimension)
        filter.cubeData = cubeData
        guard let coded = filter.outputImage else { return log }
        return coded.matchedToWorkingSpace(from: outputColorSpace) ?? coded
    }

    /// Convenience: a Log camera buffer → developed image.
    static func developed(_ buffer: CVPixelBuffer) -> CIImage {
        develop(image(from: buffer))
    }
}
