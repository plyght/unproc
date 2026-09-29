import AVFoundation
import CoreGraphics
import CoreMedia
import os

/// Builds the lens list.
///
/// Back lenses run on the best *virtual* back camera (triple, dual-wide or
/// dual) when the phone has one: every back stop shares that one device and
/// differs only in `videoZoomFactor` (`Lens.crop`), so switching 0.5× ↔ 1× ↔
/// 4× is a zoom change — AVFoundation moves between the physical constituents
/// itself, like the Camera app — instead of a session reconfiguration.
/// Single-camera phones use the physical camera (with a 2× crop). The front
/// camera is always its own physical device.
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
        // iPhone 17+ front camera is a square Center Stage sensor exposed as a
        // front *ultra-wide*; older phones have a front wide. Prefer the former.
        let frontDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: .front
        ).devices
        let front = frontDevices.first { $0.deviceType == .builtInUltraWideCamera } ?? frontDevices.first
        let backText = back.map { "\($0.deviceType.rawValue)=\($0.uniqueID)" }.joined(separator: " ")
        Log.camera.info("lenses: back devices [\(backText, privacy: .public)] front=\(front?.uniqueID ?? "none", privacy: .public)")

        let zoom = zoomFactors(wide: wide, tele: tele)
        Log.camera.info("lenses: zoom factors ultraWide=\(Double(zoom.ultraWide), privacy: .public) tele=\(Double(zoom.tele), privacy: .public)")
        let virtual = virtualBackCamera(zoom: zoom)
        var backLenses: [Lens] = []

        /// Physical lens (device + crop on it) or, when its camera is a
        /// constituent of the virtual device, the virtual device at
        /// `displayZoom / baseZoom`.
        func lens(_ id: String, _ physical: AVCaptureDevice, kind: Lens.Kind, crop: CGFloat, displayZoom: CGFloat) -> Lens {
            if let virtual, virtual.constituentTypes.contains(physical.deviceType) {
                return Lens(id: id, deviceID: virtual.device.uniqueID, position: .back,
                            kind: kind, crop: displayZoom / virtual.baseZoom, zoom: displayZoom)
            }
            return Lens(id: id, deviceID: physical.uniqueID, position: .back,
                        kind: kind, crop: crop, zoom: displayZoom)
        }

        if let ultra {
            backLenses.append(lens("back.ultra", ultra, kind: .ultraWide, crop: 1, displayZoom: zoom.ultraWide))
        }
        if let wide {
            backLenses.append(lens("back.wide", wide, kind: .wide, crop: 1, displayZoom: 1))
            // Skip the 2× crop when a real 2× (or shorter) telephoto exists: same button twice.
            if tele == nil || zoom.tele > 2.05 {
                backLenses.append(lens("back.wide.crop2", wide, kind: .wide, crop: 2, displayZoom: 2))
            }
        }
        if let tele {
            backLenses.append(lens("back.tele", tele, kind: .tele, crop: 1, displayZoom: zoom.tele))
            backLenses.append(lens("back.tele.crop2", tele, kind: .tele, crop: 2, displayZoom: zoom.tele * 2))
        }
        backLenses.sort { $0.zoom < $1.zoom }

        if let front {
            backLenses.append(Lens(id: "front.wide", deviceID: front.uniqueID, position: .front,
                                   kind: .front, crop: 1, zoom: 1))
        }
        let list = backLenses.map(CameraLogText.lens).joined(separator: " ")
        Log.camera.notice("lenses: \(backLenses.count, privacy: .public) [\(list, privacy: .public)]")
        return backLenses
    }

    /// The back virtual device the lenses run on, with the display zoom of its
    /// widest constituent (`videoZoomFactor` 1 on the virtual device).
    struct VirtualCamera {
        let device: AVCaptureDevice
        let constituentTypes: Set<AVCaptureDevice.DeviceType>
        /// Display zoom at `videoZoomFactor` 1: 0.5 (ultra-wide) for triple /
        /// dual-wide, 1 (wide) for dual.
        let baseZoom: CGFloat
    }

    /// Best back virtual camera: triple, else dual-wide, else dual. `nil` on
    /// single-camera phones.
    static func virtualBackCamera(zoom: ZoomFactors) -> VirtualCamera? {
        let candidates: [(AVCaptureDevice.DeviceType, CGFloat)] = [
            (.builtInTripleCamera, zoom.ultraWide),
            (.builtInDualWideCamera, zoom.ultraWide),
            (.builtInDualCamera, 1),
        ]
        for (type, baseZoom) in candidates {
            guard let device = AVCaptureDevice.default(type, for: .video, position: .back),
                  device.isVirtualDevice, baseZoom > 0 else { continue }
            let types = Set(device.constituentDevices.map(\.deviceType))
            let typeText = device.constituentDevices.map(\.deviceType.rawValue).joined(separator: ",")
            let switchOver = device.virtualDeviceSwitchOverVideoZoomFactors.map { String(format: "%.2f", $0.doubleValue) }.joined(separator: ",")
            Log.camera.notice("lenses: virtual back camera \(type.rawValue, privacy: .public) id=\(device.uniqueID, privacy: .public) constituents=[\(typeText, privacy: .public)] switchOver=[\(switchOver, privacy: .public)] baseZoom=\(Double(baseZoom), privacy: .public)")
            return VirtualCamera(device: device, constituentTypes: types, baseZoom: baseZoom)
        }
        Log.camera.notice("lenses: no back virtual camera; using physical cameras")
        return nil
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
        Log.camera.debug("lenses: triple switch-over factors \(String(describing: triple), privacy: .public)")
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
            Log.camera.info("lenses: tele factor from field of view ratio \(Double(ratio), privacy: .public)")
            result.tele = ratio
        } else if !teleKnown {
            Log.camera.debug("lenses: tele factor unknown, default \(Double(result.tele), privacy: .public)")
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
        // Square Center Stage front sensor: the best square format that can crop
        // both portrait and landscape (dynamic aspect ratio).
        if device.position == .front {
            let square = device.formats.filter { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard dims.width > 0, dims.width == dims.height else { return false }
                let ratios = format.supportedDynamicAspectRatios
                return ratios.contains(.ratio3x4) && ratios.contains(.ratio4x3)
                    && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 29.9 }
            }
            if let best = square.max(by: { score($0) < score($1) }) { return best }
        }
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

    /// A video-mode format and what it can do.
    struct VideoChoice {
        let format: AVCaptureDevice.Format
        let resolution: VideoResolution
        let fps: VideoFrameRate
        /// 10-bit 4:2:0 ('x420' / 'xf20').
        let tenBit: Bool
        /// The format records HLG BT.2020 and HDR was asked for.
        let hdr: Bool
        /// Frame rates offered for this resolution (and dynamic range) on this device.
        let offered: [VideoFrameRate]
    }

    static let tenBitSubtypes: Set<OSType> = [
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
    ]
    static let eightBitSubtypes: Set<OSType> = [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    ]

    /// The 16:9 format for video mode: exactly `resolution` (else 1080p, else
    /// the largest 16:9 below it), supporting `fps` (else the fastest rate it
    /// has), 10-bit 4:2:0 when available, unbinned, video range. SDR needs an
    /// sRGB-capable format; HDR needs HLG BT.2020 (falls back to SDR when no
    /// format has it). Nothing that only records ProRes / Apple Log.
    static func bestVideoFormat(for device: AVCaptureDevice, resolution: VideoResolution,
                                fps: VideoFrameRate, hdr: Bool) -> VideoChoice? {
        if hdr, let choice = videoChoice(for: device, resolution: resolution, fps: fps, hdr: true) {
            return choice
        }
        return videoChoice(for: device, resolution: resolution, fps: fps, hdr: false)
    }

    private static func videoChoice(for device: AVCaptureDevice, resolution: VideoResolution,
                                    fps: VideoFrameRate, hdr: Bool) -> VideoChoice? {
        let usable = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width > 0, dims.height > 0 else { return false }
            let long = max(dims.width, dims.height), short = min(dims.width, dims.height)
            guard abs(Double(long) / Double(short) - 16.0 / 9.0) < 0.02 else { return false }
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            if hdr {
                guard tenBitSubtypes.contains(subtype),
                      format.supportedColorSpaces.contains(.HLG_BT2020) else { return false }
            } else {
                guard tenBitSubtypes.contains(subtype) || eightBitSubtypes.contains(subtype),
                      format.supportedColorSpaces.contains(.sRGB) else { return false }
            }
            return format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 23.5 }
        }
        guard !usable.isEmpty else { return nil }

        func longSide(_ format: AVCaptureDevice.Format) -> Int {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return Int(max(dims.width, dims.height))
        }
        // Resolution: exact, else 1080p, else the largest one below the request.
        let sizes = Set(usable.map(longSide))
        let chosenLong: Int
        let chosenResolution: VideoResolution
        if sizes.contains(resolution.longSide) {
            chosenLong = resolution.longSide
            chosenResolution = resolution
        } else if sizes.contains(VideoResolution.hd1080.longSide) {
            chosenLong = VideoResolution.hd1080.longSide
            chosenResolution = .hd1080
        } else if let below = sizes.filter({ $0 < resolution.longSide }).max() {
            chosenLong = below
            chosenResolution = below >= VideoResolution.uhd4K.longSide ? .uhd4K : .hd1080
        } else {
            return nil
        }
        let sameSize = usable.filter { longSide($0) == chosenLong }
        let maxRate = sameSize.flatMap { $0.videoSupportedFrameRateRanges.map(\.maxFrameRate) }.max() ?? 30
        let offered = VideoSpec.offeredRates(maxRate: maxRate)
        let rate = VideoSpec.resolve(fps, offered: offered)

        func supports(_ format: AVCaptureDevice.Format, _ rate: VideoFrameRate) -> Bool {
            let r = Double(rate.rawValue)
            return format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= r + 0.01 && $0.maxFrameRate >= r - 0.01 }
        }
        // (supports the rate, 10-bit, unbinned, video range, zoom headroom)
        func score(_ format: AVCaptureDevice.Format) -> (Int, Int, Int, Int, Double) {
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let videoRange = subtype == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                || subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            return (supports(format, rate) ? 1 : 0,
                    tenBitSubtypes.contains(subtype) ? 1 : 0,
                    format.isVideoBinned ? 0 : 1,
                    videoRange ? 1 : 0,
                    Double(format.videoMaxZoomFactor))
        }
        guard let best = sameSize.max(by: { score($0) < score($1) }) else { return nil }
        let subtype = CMFormatDescriptionGetMediaSubType(best.formatDescription)
        return VideoChoice(format: best,
                           resolution: chosenResolution,
                           fps: supports(best, rate) ? rate : (offered.last(where: { supports(best, $0) }) ?? rate),
                           tenBit: tenBitSubtypes.contains(subtype),
                           hdr: hdr,
                           offered: offered)
    }

    /// Largest supported still size of a format.
    static func largestPhotoDimensions(of format: AVCaptureDevice.Format) -> CMVideoDimensions? {
        format.supportedMaxPhotoDimensions.max { area($0) < area($1) }
    }

    static func area(_ d: CMVideoDimensions) -> Int {
        Int(d.width) * Int(d.height)
    }

    /// True for the square (portrait-mounted) Center Stage front sensor.
    static func isSquareFront(_ device: AVCaptureDevice) -> Bool {
        guard device.position == .front else { return false }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        return dims.width > 0 && dims.width == dims.height
            && !device.activeFormat.supportedDynamicAspectRatios.isEmpty
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
