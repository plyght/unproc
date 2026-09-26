import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Viewfinder-only overlays. Built-in filters only (no custom kernels), all
/// cheap enough to run every preview frame in `Developer.shared.context`
/// (linear extended Display P3 working space).
enum ViewfinderEffects {
    /// Peaking accent, #FF5A1F.
    static let accent: CIColor =
        CIColor(red: 1.0, green: 90.0 / 255.0, blue: 31.0 / 255.0,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        ?? CIColor(red: 1.0, green: 90.0 / 255.0, blue: 31.0 / 255.0)

    // MARK: Gain

    /// Simulated exposure (e.g. a long shutter the preview can't run at).
    static func gain(_ image: CIImage, ev: Float) -> CIImage {
        guard ev != 0 else { return image }
        let f = CIFilter.exposureAdjust()
        f.inputImage = image
        f.ev = ev
        return f.outputImage ?? image
    }

    // MARK: Zebras

    /// Diagonal stripes over areas where any channel reaches `threshold`.
    /// `threshold` is in display-encoded terms (what a histogram would show);
    /// it's converted to linear because filters run in the linear working space.
    /// Animate by advancing `phase` (points, one stripe period ≈ 2 × width).
    static func zebras(_ image: CIImage, threshold: Float = 0.96, phase: CGFloat = 0) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else { return image }

        let maxComp = CIFilter.maximumComponent()
        maxComp.inputImage = image
        let thresh = CIFilter.colorThreshold()
        thresh.inputImage = maxComp.outputImage
        thresh.threshold = srgbToLinear(threshold)
        guard let mask = thresh.outputImage else { return image }

        // ~5 px stripes on a typical 1080-wide preview; scales with frame size.
        let width = Float(max(3, min(extent.width, extent.height) / 216))
        let stripes = CIFilter.stripesGenerator()
        stripes.center = .zero
        stripes.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0.9)
        stripes.color1 = CIColor.clear
        stripes.width = width
        stripes.sharpness = 1
        guard let raw = stripes.outputImage else { return image }

        let striped = raw
            .transformed(by: CGAffineTransform(rotationAngle: .pi / 4))
            .transformed(by: CGAffineTransform(translationX: phase, y: 0))
            .cropped(to: extent)
            .composited(over: image)

        let blend = CIFilter.blendWithMask()
        blend.inputImage = striped
        blend.backgroundImage = image
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: extent) ?? image
    }

    // MARK: Focus peaking

    /// Accent-coloured edges over in-focus detail.
    static func peaking(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else { return image }

        // Half resolution is plenty for a focus aid and 4× cheaper.
        let half = image.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        let halfExtent = half.extent

        // Luma, then back to a perceptual encoding so shadow edges count too.
        let mono = CIFilter.colorControls()
        mono.inputImage = half
        mono.saturation = 0
        mono.brightness = 0
        mono.contrast = 1
        let encoded = CIFilter.linearToSRGBToneCurve()
        encoded.inputImage = mono.outputImage

        // Clamp before the edge filter so the frame border isn't an "edge".
        let edges = CIFilter.edges()
        edges.inputImage = encoded.outputImage?.clampedToExtent()
        edges.intensity = 5

        let thresh = CIFilter.colorThreshold()
        thresh.inputImage = edges.outputImage?.cropped(to: halfExtent)
        thresh.threshold = 0.35
        guard let halfMask = thresh.outputImage else { return image }

        let mask = halfMask
            .transformed(by: CGAffineTransform(scaleX: 2, y: 2))
            .cropped(to: extent)
        let color = CIImage(color: accent).cropped(to: extent)

        let blend = CIFilter.blendWithMask()
        blend.inputImage = color
        blend.backgroundImage = image
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: extent) ?? image
    }

    // MARK: Helpers

    private static func srgbToLinear(_ v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
}
