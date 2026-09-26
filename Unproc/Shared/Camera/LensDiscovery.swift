import AVFoundation
import CoreGraphics
import CoreMedia

/// Builds the lens list from the *physical* cameras (no virtual-device fusion).
enum LensDiscovery {
    /// Zoom factors relative to the main wide lens.
    struct ZoomFactors: Equatable, Sendable {
        var ultraWide: CGFloat
        var tele: CGFloat
    }

    /// Ordered by zoom, front last. Lenses whose camera is missing are skipped.
    static func discover() -> [Lens] {
        let back = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video,
            position: .back
        ).devices
        let ultra = back.first { $0.deviceType == .builtInUltraWideCamera }
        let wide = back.first { $0.deviceType == .builtInWideAngleCamera }
        let tele = back.first { $0.deviceType == .builtInTelephotoCamera }
        let front = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .front
        ).devices.first

        let zoom = zoomFactors(wide: wide, tele: tele)
        var backLenses: [Lens] = []

        if let ultra {
            backLenses.append(Lens(id: "back.ultra", deviceID: ultra.uniqueID, position: .back,
                                   kind: .ultraWide, crop: 1, zoom: zoom.ultraWide))
        }
        if let wide {
            backLenses.append(Lens(id: "back.wide", deviceID: wide.uniqueID, position: .back,
                                   kind: .wide, crop: 1, zoom: 1))
            // Skip the 2× crop when a real 2× (or shorter) telephoto exists: same button twice.
            if tele == nil || zoom.tele > 2.05 {
                backLenses.append(Lens(id: "back.wide.crop2", deviceID: wide.uniqueID, position: .back,
                                       kind: .wide, crop: 2, zoom: 2))
            }
        }
        if let tele {
            backLenses.append(Lens(id: "back.tele", deviceID: tele.uniqueID, position: .back,
                                   kind: .tele, crop: 1, zoom: zoom.tele))
            backLenses.append(Lens(id: "back.tele.crop2", deviceID: tele.uniqueID, position: .back,
                                   kind: .tele, crop: 2, zoom: zoom.tele * 2))
        }
        backLenses.sort { $0.zoom < $1.zoom }

        if let front {
            backLenses.append(Lens(id: "front.wide", deviceID: front.uniqueID, position: .front,
                                   kind: .front, crop: 1, zoom: 1))
        }
        return backLenses
    }

    /// Reads the switch-over zoom factors of the virtual multi-camera devices to
    /// learn how the physical lenses relate to the wide one.
    ///
    /// - Triple / dual-wide: factors are relative to the ultra-wide, so
    ///   wide = f[0] and tele = f[1] / f[0].
    /// - Dual (wide + tele): factors are relative to the wide, so tele = f[0].
    /// e.g. iPhone 17/18 Pro triple = [2, 8] → tele 4× (and an 8× crop lens).
    /// Without a virtual device, the tele factor is derived from the two lenses'
    /// fields of view; failing that, 0.5× ultra-wide and 3× tele.
    static func zoomFactors(wide: AVCaptureDevice? = nil, tele: AVCaptureDevice? = nil) -> ZoomFactors {
        var result = ZoomFactors(ultraWide: 0.5, tele: 3)
        var teleKnown = false

        func factors(_ type: AVCaptureDevice.DeviceType) -> [CGFloat] {
            guard let device = AVCaptureDevice.default(type, for: .video, position: .back) else { return [] }
            return device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        }

        let triple = factors(.builtInTripleCamera)
        if triple.count >= 2, triple[0] > 0 {
            result.ultraWide = 1 / triple[0]
            result.tele = triple[1] / triple[0]
            teleKnown = true
        } else {
            let dualWide = factors(.builtInDualWideCamera)
            if let first = dualWide.first, first > 0 {
                result.ultraWide = 1 / first
            }
        }
        if !teleKnown {
            let dual = factors(.builtInDualCamera)
            if let first = dual.first, first > 0 {
                result.tele = first
                teleKnown = true
            }
        }
        if !teleKnown, let wide, let tele, let ratio = fieldOfViewRatio(wide: wide, tele: tele) {
            result.tele = ratio
        }
        result.ultraWide = round1(result.ultraWide)
        result.tele = round1(result.tele)
        return result
    }

    /// Rounds to one decimal, snapping to a whole number when within 0.1 (3.96 → 4).
    private static func round1(_ v: CGFloat) -> CGFloat {
        let whole = v.rounded()
        if abs(v - whole) < 0.1 { return whole }
        return (v * 10).rounded() / 10
    }

    /// Magnification of `tele` relative to `wide` from their horizontal fields of
    /// view in comparable (4:3 photo) formats.
    private static func fieldOfViewRatio(wide: AVCaptureDevice, tele: AVCaptureDevice) -> CGFloat? {
        let wideFormat = CaptureFormatPicker.bestPhotoFormat(for: wide) ?? wide.activeFormat
        let teleFormat = CaptureFormatPicker.bestPhotoFormat(for: tele) ?? tele.activeFormat
        let wideFOV = Double(wideFormat.videoFieldOfView) * .pi / 180
        let teleFOV = Double(teleFormat.videoFieldOfView) * .pi / 180
        guard wideFOV > 0, teleFOV > 0, teleFOV < wideFOV else { return nil }
        let ratio = tan(wideFOV / 2) / tan(teleFOV / 2)
        guard ratio.isFinite, ratio > 1 else { return nil }
        return CGFloat(ratio)
    }
}

/// Picks the capture format for a physical device.
enum CaptureFormatPicker {
    /// The highest-photo-resolution 4:3 format that supports high-quality
    /// (RAW-capable) stills at ≥ 30 fps. Ties prefer a video size close to
    /// 1920×1440 (cheap preview) and full-range 4:2:0.
    /// Returns `nil` when nothing matches; the caller then uses the `.photo` preset.
    static func bestPhotoFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let candidates = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width > 0, dims.height > 0 else { return false }
            let aspect = Double(dims.width) / Double(dims.height)
            guard abs(aspect - 4.0 / 3.0) < 0.01 else { return false }
            guard format.isHighestPhotoQualitySupported else { return false }
            guard !format.supportedMaxPhotoDimensions.isEmpty else { return false }
            return format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 29.9 }
        }
        return candidates.max { a, b in score(a) < score(b) }
    }

    /// Largest supported still size of a format.
    static func largestPhotoDimensions(of format: AVCaptureDevice.Format) -> CMVideoDimensions? {
        format.supportedMaxPhotoDimensions.max { area($0) < area($1) }
    }

    static func area(_ d: CMVideoDimensions) -> Int {
        Int(d.width) * Int(d.height)
    }

    /// Lexicographic score: (photo pixels, -distance of video size to 1920×1440, full range).
    private static func score(_ format: AVCaptureDevice.Format) -> (Int, Int, Int) {
        let photo = largestPhotoDimensions(of: format).map(area) ?? 0
        let video = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let distance = abs(area(video) - 1920 * 1440)
        let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        let fullRange = subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 1 : 0
        return (photo, -distance, fullRange)
    }
}
