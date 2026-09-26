import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import Unproc

/// Shared fixtures for the unit tests.
enum TestSupport {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

    /// Plain CPU-friendly context for test renders.
    static let context = CIContext(options: [.cacheIntermediates: false])

    /// A deterministic colourful gradient (R varies with x, G with y, B with both).
    static func gradientImage(width: Int, height: Int) -> CIImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8(clamping: x * 255 / max(width - 1, 1))
                bytes[i + 1] = UInt8(clamping: y * 255 / max(height - 1, 1))
                bytes[i + 2] = UInt8(clamping: (x + y) * 255 / max(width + height - 2, 1))
                bytes[i + 3] = 255
            }
        }
        return CIImage(bitmapData: Data(bytes),
                       bytesPerRow: width * 4,
                       size: CGSize(width: width, height: height),
                       format: .RGBA8,
                       colorSpace: sRGB)
    }

    /// A small real JPEG (no orientation tag).
    static func jpegData(width: Int, height: Int) -> Data {
        let image = gradientImage(width: width, height: height)
        guard let data = context.jpegRepresentation(of: image, colorSpace: sRGB, options: [:]) else {
            fatalError("could not encode test JPEG")
        }
        return data
    }

    /// Renders to float RGBA so NaN / Inf are observable.
    static func renderFloat(_ image: CIImage, colorSpace: CGColorSpace = linearP3) -> [Float] {
        let rect = image.extent.integral
        let width = Int(rect.width), height = Int(rect.height)
        var buffer = [Float](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            context.render(image,
                           toBitmap: raw.baseAddress!,
                           rowBytes: width * 4 * MemoryLayout<Float>.size,
                           bounds: rect,
                           format: .RGBAf,
                           colorSpace: colorSpace)
        }
        return buffer
    }

    static func lens(id: String = "back.wide",
                     kind: Lens.Kind = .wide,
                     position: AVCaptureDevice.Position = .back,
                     crop: CGFloat = 1,
                     zoom: CGFloat = 1) -> Lens {
        Lens(id: id, deviceID: "test", position: position, kind: kind, crop: crop, zoom: zoom)
    }

    /// Metadata shaped like `AVCapturePhoto.metadata` for a rotated RAW capture.
    static func realisticMetadata() -> [String: Any] {
        [
            kCGImagePropertyOrientation as String: 6,
            kCGImagePropertyPixelWidth as String: 4032,
            kCGImagePropertyPixelHeight as String: 3024,
            kCGImagePropertyDepth as String: 16,
            kCGImagePropertyColorModel as String: "RGB",
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifExposureTime as String: 1.0 / 125.0,
                kCGImagePropertyExifFNumber as String: 1.78,
                kCGImagePropertyExifISOSpeedRatings as String: [100],
                kCGImagePropertyExifFocalLength as String: 6.86,
                kCGImagePropertyExifFocalLenIn35mmFilm as String: 24,
                kCGImagePropertyExifLensMake as String: "Apple",
                kCGImagePropertyExifLensModel as String: "iPhone Test back camera 6.86mm f/1.78",
                kCGImagePropertyExifSubjectArea as String: [2015, 1511, 2217, 1330],
                kCGImagePropertyExifPixelXDimension as String: 4032,
                kCGImagePropertyExifPixelYDimension as String: 3024,
                kCGImagePropertyExifCompressedBitsPerPixel as String: 12,
                kCGImagePropertyExifDateTimeOriginal as String: "2026:09:26 12:00:00",
            ] as [String: Any],
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "Apple",
                kCGImagePropertyTIFFModel as String: "iPhone Test",
                kCGImagePropertyTIFFOrientation as String: 6,
                "TileWidth": 512,
                "TileLength": 512,
                "Compression": 7,
                "PhotometricInterpretation": 32803,
            ] as [String: Any],
            kCGImagePropertyMakerAppleDictionary as String: [
                "1": 14,
                "4": 1,
                "8": [-0.02, -0.98, 0.1],
            ] as [String: Any],
            kCGImagePropertyDNGDictionary as String: [
                kCGImagePropertyDNGVersion as String: [1, 4, 0, 0],
                kCGImagePropertyDNGUniqueCameraModel as String: "iPhone Test",
            ] as [String: Any],
        ]
    }

    static func properties(ofImageData data: Data) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
    }

    static func cgImage(ofImageData data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unproc-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
