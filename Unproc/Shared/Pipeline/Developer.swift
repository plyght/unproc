import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Metal
import os
import UniformTypeIdentifiers

/// Turns a `CapturedFrame` into pixels with as little "processing" as a RAW
/// developer allows, and encodes the final JPEG.
final class Developer: @unchecked Sendable {
    static let shared = Developer()

    /// Metal-backed, shared with the viewfinder. `CIContext` is thread-safe.
    let context: CIContext

    /// Working space: extended-range linear Display P3.
    let workingColorSpace: CGColorSpace
    /// Output space of every JPEG / thumbnail.
    let outputColorSpace: CGColorSpace

    /// JPEG quality of the finished photo.
    static let jpegQuality: CGFloat = 0.93

    init() {
        let working = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let output = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        workingColorSpace = working
        outputColorSpace = output

        let options: [CIContextOption: Any] = [
            .workingColorSpace: working,
            .cacheIntermediates: false,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options)
            Log.pipeline.info("developer: CIContext on Metal device \(device.name, privacy: .public)")
        } else {
            context = CIContext(options: options)
            Log.pipeline.error("developer: no Metal device, using default CIContext")
        }
    }

    // MARK: - Develop

    /// Develops the frame into an upright, lens-cropped image in the working
    /// space with extent origin at (0, 0). No look is applied yet.
    func develop(_ frame: CapturedFrame) throws -> CIImage {
        let clock = ContinuousClock()
        let began = clock.now
        var image: CIImage
        if let dng = frame.rawDNG {
            Log.pipeline.info("develop: raw flavor=\(frame.rawFlavor?.rawValue ?? "nil->bayer", privacy: .public) bytes=\(dng.count, privacy: .public) lens=\(frame.lens.id, privacy: .public) crop=\(Double(frame.lens.crop), privacy: .public)")
            image = try developRAW(dng, flavor: frame.rawFlavor ?? .bayer)
        } else if let processed = frame.processed {
            Log.pipeline.info("develop: processed bytes=\(processed.count, privacy: .public) lens=\(frame.lens.id, privacy: .public) crop=\(Double(frame.lens.crop), privacy: .public)")
            // HEIC/JPEG fallback (front camera): honour the EXIF orientation so
            // the result is upright like the RAW path. Mirroring for the front
            // camera is part of that orientation (set by the camera module).
            guard let img = CIImage(data: processed, options: [.applyOrientationProperty: true]) else {
                Log.pipeline.error("develop: CIImage could not read processed data (\(processed.count, privacy: .public) bytes)")
                throw UnprocError.developFailed("Unreadable image data")
            }
            image = img
        } else {
            Log.pipeline.error("develop: frame has neither RAW nor processed data")
            throw UnprocError.developFailed("Frame has no image data")
        }

        let extent = image.extent
        Log.pipeline.debug("develop: decoded extent=\(String(describing: extent), privacy: .public)")
        guard !extent.isInfinite, !extent.isEmpty else {
            Log.pipeline.error("develop: invalid extent \(String(describing: extent), privacy: .public)")
            throw UnprocError.developFailed("Invalid image extent")
        }

        // Centre crop for "2×" style lenses, keeping the aspect ratio. RAW is
        // always full-sensor, so it needs the crop; a processed photo already
        // carries the device's digital zoom (and demo frames are pre-cropped),
        // so cropping it again would zoom twice.
        let crop = frame.rawDNG != nil ? frame.lens.crop : 1
        if crop > 1.001 {
            let w = (extent.width / crop).rounded(.down)
            let h = (extent.height / crop).rounded(.down)
            let rect = CGRect(x: (extent.midX - w / 2).rounded(.down),
                              y: (extent.midY - h / 2).rounded(.down),
                              width: w, height: h)
            image = image.cropped(to: rect)
            Log.pipeline.debug("develop: lens crop \(Double(crop), privacy: .public) -> \(String(describing: rect), privacy: .public)")
        }

        // Normalise origin to zero so downstream code (JPEG, blends) can
        // assume (0, 0, w, h).
        let origin = image.extent.origin
        if origin != .zero {
            image = image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        }
        let ms = CameraLogText.ms(clock.now - began)
        Log.pipeline.info("develop: done extent=\(String(describing: image.extent), privacy: .public) in \(ms, privacy: .public)ms (lazy graph)")
        return image
    }

    private func developRAW(_ dng: Data, flavor: RawFlavor) throws -> CIImage {
        guard let raw = CIRAWFilter(imageData: dng, identifierHint: "com.adobe.raw-image") else {
            Log.pipeline.error("develop: CIRAWFilter could not open DNG (\(dng.count, privacy: .public) bytes, flavor \(flavor.rawValue, privacy: .public))")
            throw UnprocError.developFailed("Could not open RAW")
        }
        Log.pipeline.debug("develop: CIRAWFilter native=\(String(describing: raw.nativeSize), privacy: .public) orientation=\(raw.orientation.rawValue, privacy: .public) sharp=\(raw.isSharpnessSupported, privacy: .public) detail=\(raw.isDetailSupported, privacy: .public) ltm=\(raw.isLocalToneMapSupported, privacy: .public) lumaNR=\(raw.isLuminanceNoiseReductionSupported, privacy: .public) lensCorr=\(raw.isLensCorrectionSupported, privacy: .public) baselineEV=\(raw.baselineExposure, privacy: .public)")

        // Orientation: `CIRAWFilter.orientation` is initialised from the file's
        // Orientation tag, and `outputImage` is rendered with that orientation
        // already applied. The camera module writes the DNG with the
        // orientation of the device at capture time (plus mirroring for the
        // front camera), so the output here is upright. We deliberately do not
        // touch `raw.orientation`.

        // "Zero processing": no sharpening, no local tone mapping, no detail
        // enhancement, no EDR headroom.
        if raw.isSharpnessSupported { raw.sharpnessAmount = 0 }
        if raw.isDetailSupported { raw.detailAmount = 0 }
        if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
        raw.extendedDynamicRangeAmount = 0

        // Global base curve: a gentle film-like response rather than a flat
        // log look. ProRAW already carries more of Apple's rendering intent,
        // so it needs a bit less.
        raw.boostAmount = flavor == .proRAW ? 0.5 : 0.6

        // Modest luminance NR keeps high-ISO grain organic without smearing.
        // Colour NR is left at the RAW default (chroma blotches look digital).
        if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = 0.2 }

        // Distortion-free geometry, and colours mapped into gamut instead of clipped.
        if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = true }
        raw.isGamutMappingEnabled = true

        Log.pipeline.debug("develop: RAW params boost=\(raw.boostAmount, privacy: .public) sharp=\(raw.sharpnessAmount, privacy: .public) detail=\(raw.detailAmount, privacy: .public) ltm=\(raw.localToneMapAmount, privacy: .public) edr=\(raw.extendedDynamicRangeAmount, privacy: .public) lumaNR=\(raw.luminanceNoiseReductionAmount, privacy: .public) lensCorr=\(raw.isLensCorrectionEnabled, privacy: .public) gamutMap=\(raw.isGamutMappingEnabled, privacy: .public)")
        guard let output = raw.outputImage else {
            Log.pipeline.error("develop: CIRAWFilter.outputImage is nil (flavor \(flavor.rawValue, privacy: .public))")
            throw UnprocError.developFailed("RAW decode produced no image")
        }
        Log.pipeline.info("develop: RAW output extent=\(String(describing: output.extent), privacy: .public)")
        return output
    }

    // MARK: - Finish

    /// Applies the look, renders Display P3 8-bit and encodes the JPEG with
    /// the capture metadata (orientation reset to 1, since pixels are upright).
    func finish(_ image: CIImage, look: Look, frame: CapturedFrame, includeDNG: Bool) throws -> DevelopedPhoto {
        let clock = ContinuousClock()
        let began = clock.now
        Log.pipeline.info("finish: begin look=\(String(describing: look), privacy: .public) extent=\(String(describing: image.extent), privacy: .public) includeDNG=\(includeDNG, privacy: .public) hasDNG=\(frame.rawDNG != nil, privacy: .public)")
        let graded = LookLibrary.apply(look, to: image)
        let rect = graded.extent.integral
        guard !rect.isInfinite, !rect.isEmpty else {
            Log.pipeline.error("finish: invalid graded extent \(String(describing: rect), privacy: .public)")
            throw UnprocError.developFailed("Invalid image extent")
        }
        guard let cg = context.createCGImage(graded, from: rect, format: .RGBA8, colorSpace: outputColorSpace) else {
            Log.pipeline.error("finish: createCGImage failed rect=\(String(describing: rect), privacy: .public)")
            throw UnprocError.developFailed("Render failed")
        }
        let renderMs = CameraLogText.ms(clock.now - began)
        Log.pipeline.info("finish: rendered \(cg.width, privacy: .public)x\(cg.height, privacy: .public) in \(renderMs, privacy: .public)ms")
        let properties = Self.jpegProperties(from: frame.metadata, width: cg.width, height: cg.height)
        guard let jpeg = Self.encodeJPEG(cg, properties: properties) else {
            Log.pipeline.error("finish: JPEG encoding failed \(cg.width, privacy: .public)x\(cg.height, privacy: .public)")
            throw UnprocError.developFailed("JPEG encoding failed")
        }
        let totalMs = CameraLogText.ms(clock.now - began)
        Log.pipeline.notice("finish: jpeg \(jpeg.count, privacy: .public)B \(cg.width, privacy: .public)x\(cg.height, privacy: .public) dng=\(includeDNG ? (frame.rawDNG?.count ?? 0) : 0, privacy: .public)B in \(totalMs, privacy: .public)ms")
        return DevelopedPhoto(jpeg: jpeg,
                              dng: includeDNG ? frame.rawDNG : nil,
                              capturedAt: frame.capturedAt)
    }

    /// Small graded render for UI feedback (film strip, capture animation).
    func thumbnail(_ image: CIImage, look: Look, maxSide: CGFloat) -> CGImage? {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty, maxSide > 0 else { return nil }
        let scale = min(1, maxSide / max(extent.width, extent.height))
        var small = image
        if scale < 1 {
            small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        // The LUT is a per-pixel op, so grading after the downscale is cheaper
        // and gives the same result.
        let graded = LookLibrary.apply(look, to: small)
        let rect = graded.extent.integral
        guard !rect.isInfinite, !rect.isEmpty else { return nil }
        return context.createCGImage(graded, from: rect, format: .RGBA8, colorSpace: outputColorSpace)
    }

    // MARK: - JPEG

    static func encodeJPEG(_ image: CGImage, properties: [String: Any]) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData,
                                                          UTType.jpeg.identifier as CFString,
                                                          1, nil) else {
            Log.pipeline.error("jpeg: CGImageDestinationCreateWithData failed")
            return nil
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            Log.pipeline.error("jpeg: CGImageDestinationFinalize failed \(image.width, privacy: .public)x\(image.height, privacy: .public) props=\(properties.count, privacy: .public)")
            return nil
        }
        return data as Data
    }

    /// Capture metadata adapted for an upright, rendered JPEG.
    static func jpegProperties(from metadata: [String: Any], width: Int, height: Int) -> [String: Any] {
        var props = metadata

        // Container / RAW specific keys that don't describe the JPEG.
        let dropTopLevel: [String] = [
            kCGImagePropertyDNGDictionary as String,
            kCGImagePropertyRawDictionary as String,
            kCGImagePropertyCIFFDictionary as String,
            kCGImagePropertyPNGDictionary as String,
            "{HEIF}", "{HEICS}",
            kCGImagePropertyPixelWidth as String,
            kCGImagePropertyPixelHeight as String,
            kCGImagePropertyDepth as String,
            kCGImagePropertyColorModel as String,
            kCGImagePropertyProfileName as String,
            kCGImagePropertyHasAlpha as String,
            kCGImagePropertyIsFloat as String,
            kCGImagePropertyIsIndexed as String,
            kCGImagePropertyDPIWidth as String,
            kCGImagePropertyDPIHeight as String,
        ]
        let removed = dropTopLevel.filter { props[$0] != nil }
        for key in dropTopLevel { props.removeValue(forKey: key) }

        // Pixels are already upright.
        props[kCGImagePropertyOrientation as String] = 1

        var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        tiff[kCGImagePropertyTIFFSoftware as String] = "unproc"
        for key in ["TileWidth", "TileLength", "Compression", "PhotometricInterpretation",
                    "SamplesPerPixel", "BitsPerSample", "PlanarConfiguration",
                    "StripOffsets", "StripByteCounts", "RowsPerStrip", "SubfileType", "NewSubfileType"] {
            tiff.removeValue(forKey: key)
        }
        props[kCGImagePropertyTIFFDictionary as String] = tiff

        var exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String] = width
        exif[kCGImagePropertyExifPixelYDimension as String] = height
        // 65535 = "uncalibrated": the embedded ICC profile (Display P3) is authoritative.
        exif[kCGImagePropertyExifColorSpace as String] = 65535
        exif.removeValue(forKey: kCGImagePropertyExifCompressedBitsPerPixel as String)
        props[kCGImagePropertyExifDictionary as String] = exif

        // GPS, MakerApple, ExifAux (lens info), IPTC etc. are kept as-is.
        props[kCGImageDestinationLossyCompressionQuality as String] = jpegQuality
        let kept = props.keys.sorted().joined(separator: ",")
        Log.pipeline.debug("jpeg: metadata kept=[\(kept, privacy: .public)] removed=[\(removed.joined(separator: ","), privacy: .public)] in=\(metadata.count, privacy: .public)")
        return props
    }
}
