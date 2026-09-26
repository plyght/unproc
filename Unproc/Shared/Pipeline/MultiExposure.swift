import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Film-style in-camera double exposure: two exposures summed on the same
/// "frame" in linear light, each pulled down so the sum stays printable,
/// with a soft shoulder instead of a hard clip.
enum MultiExposure {
    /// Per-exposure gain. Two frames at 0.6 sum to 1.2 × white at most.
    static let exposureGain: CGFloat = 0.6

    /// Blends two *developed* images (working space = linear, before the Look).
    /// The result has `first`'s extent; `second` is scaled to fill it.
    static func blend(_ first: CIImage, _ second: CIImage) -> CIImage {
        let target = first.extent
        guard !target.isInfinite, !target.isEmpty else { return first }
        let other = fill(second, to: target)

        // Additive exposure: 0.6·a + 0.6·b == 1.2 · mix(a, b, 0.5).
        // A 50 % dissolve keeps alpha exactly 1 (CIAdditionCompositing would
        // also sum the alpha channels), then a linear gain restores the sum.
        let dissolve = CIFilter.dissolveTransition()
        dissolve.inputImage = first
        dissolve.targetImage = other
        dissolve.time = 0.5
        guard let averaged = dissolve.outputImage else { return first }

        let g = 2 * exposureGain
        let gain = CIFilter.colorMatrix()
        gain.inputImage = averaged
        gain.rVector = CIVector(x: g, y: 0, z: 0, w: 0)
        gain.gVector = CIVector(x: 0, y: g, z: 0, w: 0)
        gain.bVector = CIVector(x: 0, y: 0, z: g, w: 0)
        gain.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        gain.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        guard let summed = gain.outputImage else { return first }

        return softClip(summed).cropped(to: target)
    }

    /// Soft clip for linear values in 0…1.2 → 0…1: y = x − k·x³ with
    /// k chosen so 1.2 ↦ 1. Midtones are essentially untouched (0.18 ↦ 0.179),
    /// slope eases to 0.5 at the top. Input is clamped to 1.2 first so the
    /// cubic stays monotone.
    static func softClip(_ image: CIImage) -> CIImage {
        let top: CGFloat = 2 * exposureGain
        let k = (top - 1) / (top * top * top)

        let clamp = CIFilter.colorClamp()
        clamp.inputImage = image
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: top, y: top, z: top, w: 1)
        guard let clamped = clamp.outputImage else { return image }

        let poly = CIFilter.colorPolynomial()
        poly.inputImage = clamped
        let curve = CIVector(x: 0, y: 1, z: 0, w: -k)
        poly.redCoefficients = curve
        poly.greenCoefficients = curve
        poly.blueCoefficients = curve
        poly.alphaCoefficients = CIVector(x: 0, y: 1, z: 0, w: 0)
        return poly.outputImage ?? clamped
    }

    /// Aspect-fill `image` into `target`, centred.
    private static func fill(_ image: CIImage, to target: CGRect) -> CIImage {
        let src = image.extent
        guard !src.isInfinite, !src.isEmpty else { return image.cropped(to: target) }
        if src == target { return image }
        let s = max(target.width / src.width, target.height / src.height)
        let t = CGAffineTransform(translationX: -src.midX, y: -src.midY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: target.midX, y: target.midY))
        return image.transformed(by: t).clampedToExtent().cropped(to: target)
    }
}
