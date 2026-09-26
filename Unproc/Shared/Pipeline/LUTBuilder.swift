import Foundation

// MARK: - Colour toolkit
//
// Everything here operates on *display-encoded* Display P3 values in 0…1
// (the same space the 3D LUT is indexed in — see `LookLibrary.cubeColorSpace`).
// Working on encoded values is what film/grading curves are usually authored
// in, and keeps a 33³ cube well-behaved in the shadows.

typealias GradeRGB = SIMD3<Float>

enum GradeKit {
    /// Display P3 luminance weights (Y row of the P3 → XYZ matrix).
    static let lumaWeights = GradeRGB(0.2290, 0.6917, 0.0793)

    @inline(__always)
    static func luma(_ c: GradeRGB) -> Float {
        c.x * lumaWeights.x + c.y * lumaWeights.y + c.z * lumaWeights.z
    }

    @inline(__always)
    static func clamp01(_ x: Float) -> Float { x.isNaN ? 0 : min(max(x, 0), 1) }

    @inline(__always)
    static func clamp01(_ c: GradeRGB) -> GradeRGB { GradeRGB(clamp01(c.x), clamp01(c.y), clamp01(c.z)) }

    @inline(__always)
    static func perChannel(_ c: GradeRGB, _ f: (Float) -> Float) -> GradeRGB { GradeRGB(f(c.x), f(c.y), f(c.z)) }

    @inline(__always)
    static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

    static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = clamp01((x - e0) / (e1 - e0))
        return t * t * (3 - 2 * t)
    }

    // MARK: Tone curves

    /// Filmic S-curve built from a normalised logistic. `contrast` 0 = identity,
    /// ~0.1–0.4 = gentle to punchy, negative = flatter. Monotone for
    /// contrast in about −1…1. `pivot` is the point contrast rotates around.
    static func filmic(_ x: Float, contrast: Float, pivot: Float = 0.5, steepness: Float = 6) -> Float {
        guard contrast != 0 else { return x }
        func sig(_ v: Float) -> Float { 1 / (1 + exp(-steepness * (v - pivot))) }
        let s0 = sig(0), s1 = sig(1)
        let n = (sig(clamp01(x)) - s0) / (s1 - s0)
        return x + contrast * (n - x)
    }

    /// Soft highlight roll-off: identity below `knee`, then a curve whose slope
    /// eases from 1 down to `1 - strength` at white. White lands at
    /// `1 - (1 - knee) * strength / 2`, so highlights compress instead of clip.
    static func shoulder(_ x: Float, knee: Float, strength: Float) -> Float {
        guard x > knee, strength > 0 else { return x }
        let range = 1 - knee
        let t = min((x - knee) / range, 1)
        return knee + range * (t - strength * t * t * 0.5)
    }

    /// Toe: compresses (positive `amount`) or opens (negative) the deepest
    /// shadows below `end`, with slope continuity at `end`. Keeps 0 → 0.
    static func toe(_ x: Float, end: Float, amount: Float) -> Float {
        guard x < end, amount != 0, end > 0 else { return x }
        let t = x / end
        // t - amount * t * (1 - t)^2 keeps f(0)=0, f(1)=1, f'(1)=1.
        return end * (t - amount * t * (1 - t) * (1 - t))
    }

    /// Matte black point: remaps 0…1 to black…1.
    @inline(__always)
    static func lift(_ x: Float, black: Float) -> Float { black + (1 - black) * x }

    /// Classic per-channel lift / gamma / gain.
    static func liftGammaGain(_ c: GradeRGB, lift: GradeRGB = .zero, gamma: GradeRGB = .one, gain: GradeRGB = .one) -> GradeRGB {
        var o = gain * (c + lift * (GradeRGB.one - c))
        o = GradeRGB(pow(max(o.x, 0), 1 / gamma.x),
                pow(max(o.y, 0), 1 / gamma.y),
                pow(max(o.z, 0), 1 / gamma.z))
        return o
    }

    // MARK: Colour

    /// Scales chroma around luminance (keeps brightness).
    static func saturation(_ c: GradeRGB, _ s: Float) -> GradeRGB {
        let l = luma(c)
        return GradeRGB(repeating: l) + (c - GradeRGB(repeating: l)) * s
    }

    /// 3×3 channel mixer. Rows are output R, G, B.
    static func channelMix(_ c: GradeRGB, r: GradeRGB, g: GradeRGB, b: GradeRGB) -> GradeRGB {
        GradeRGB((c * r).gradeSum, (c * g).gradeSum, (c * b).gradeSum)
    }

    /// Black & white conversion with filter-like channel weights (normalised).
    static func mono(_ c: GradeRGB, weights: GradeRGB) -> Float {
        let w = weights / weights.gradeSum
        return (c * w).gradeSum
    }

    /// Fully saturated colour at `hue` degrees minus its own luminance: a
    /// zero-luma direction to push a colour towards that hue.
    static func tintVector(hue: Float) -> GradeRGB {
        let c = hsvToRGB(h: hue, s: 1, v: 1)
        return c - GradeRGB(repeating: luma(c))
    }

    /// Luminance-weighted split toning. Amounts are small (0.01–0.05).
    static func splitTone(_ c: GradeRGB,
                          shadowHue: Float, shadowAmount: Float,
                          highlightHue: Float, highlightAmount: Float,
                          midHue: Float = 0, midAmount: Float = 0) -> GradeRGB {
        let l = clamp01(luma(c))
        let ws = (1 - l) * (1 - l)
        let wh = l * l
        let wm = 4 * l * (1 - l)
        var o = c
        if shadowAmount != 0 { o += tintVector(hue: shadowHue) * (shadowAmount * ws) }
        if highlightAmount != 0 { o += tintVector(hue: highlightHue) * (highlightAmount * wh) }
        if midAmount != 0 { o += tintVector(hue: midHue) * (midAmount * wm) }
        return o
    }

    /// A band of hues to adjust, like a secondary in a grading app.
    struct HueBand {
        /// Centre hue in degrees (0 red, 60 yellow, 120 green, 180 cyan, 240 blue, 300 magenta).
        var center: Float
        /// Gaussian half-width in degrees.
        var width: Float
        /// Chroma multiplier (1 = unchanged).
        var saturation: Float = 1
        /// Hue rotation in degrees.
        var hueShift: Float = 0
        /// Brightness offset for saturated colours in this band (scaled by chroma).
        var luminance: Float = 0
    }

    /// Per-hue saturation / hue / luminance. Neutral greys are untouched
    /// (every adjustment is proportional to chroma).
    static func hueBands(_ c: GradeRGB, _ bands: [HueBand]) -> GradeRGB {
        let (h, s, v) = rgbToHSV(c)
        guard s > 0.0001 else { return c }
        var shift: Float = 0, sat: Float = 0, lum: Float = 0
        for b in bands {
            var d = abs(h - b.center).truncatingRemainder(dividingBy: 360)
            if d > 180 { d = 360 - d }
            let w = exp(-(d / b.width) * (d / b.width))
            shift += w * b.hueShift
            sat += w * (b.saturation - 1)
            lum += w * b.luminance
        }
        var o = shift != 0 ? hsvToRGB(h: h + shift, s: s, v: v) : c
        if sat != 0 { o = saturation(o, max(0, 1 + sat)) }
        if lum != 0 { o += GradeRGB(repeating: lum * s) }
        return o
    }

    // MARK: HSV

    static func rgbToHSV(_ c: GradeRGB) -> (h: Float, s: Float, v: Float) {
        let mx = max(c.x, max(c.y, c.z))
        let mn = min(c.x, min(c.y, c.z))
        let d = mx - mn
        let s: Float = mx > 0 ? d / mx : 0
        var h: Float = 0
        if d > 0 {
            if mx == c.x { h = 60 * ((c.y - c.z) / d) }
            else if mx == c.y { h = 60 * ((c.z - c.x) / d + 2) }
            else { h = 60 * ((c.x - c.y) / d + 4) }
        }
        if h < 0 { h += 360 }
        return (h, s, mx)
    }

    static func hsvToRGB(h: Float, s: Float, v: Float) -> GradeRGB {
        var hh = h.truncatingRemainder(dividingBy: 360)
        if hh < 0 { hh += 360 }
        let c = v * s
        let x = c * (1 - abs((hh / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let rgb: GradeRGB
        switch hh {
        case ..<60: rgb = GradeRGB(c, x, 0)
        case ..<120: rgb = GradeRGB(x, c, 0)
        case ..<180: rgb = GradeRGB(0, c, x)
        case ..<240: rgb = GradeRGB(0, x, c)
        case ..<300: rgb = GradeRGB(x, 0, c)
        default: rgb = GradeRGB(c, 0, x)
        }
        return rgb + GradeRGB(repeating: m)
    }
}

extension SIMD3 where Scalar == Float {
    /// Written out explicitly rather than relying on stdlib reductions.
    @inline(__always)
    var gradeSum: Float { x + y + z }
}

// MARK: - LUT builder

enum LUTBuilder {
    /// Builds `CIColorCube`-style data: RGBA float32, red varying fastest,
    /// then green, then blue. Output is clamped to 0…1, alpha = 1.
    static func cube(dimension n: Int, _ transform: (GradeRGB) -> GradeRGB) -> Data {
        var values = [Float](repeating: 0, count: n * n * n * 4)
        let scale = 1 / Float(n - 1)
        var i = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let input = GradeRGB(Float(r) * scale, Float(g) * scale, Float(b) * scale)
                    let o = GradeKit.clamp01(transform(input))
                    values[i] = o.x
                    values[i + 1] = o.y
                    values[i + 2] = o.z
                    values[i + 3] = 1
                    i += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
