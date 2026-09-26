import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

extension CameraController {
    /// True in the Simulator, or on device when launched with `-UNPROC_DEMO`.
    /// In demo mode no `AVCaptureSession` is touched: `SimulatorCamera` publishes
    /// a synthetic scene and captures return a processed JPEG of it.
    nonisolated static let isDemo: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        return ProcessInfo.processInfo.arguments.contains("-UNPROC_DEMO")
        #endif
    }()
}

/// Fake camera for the Simulator / screenshots. Publishes a 1080×1440 portrait
/// frame at 30 fps; each lens shows a different framing of the same scene.
final class SimulatorCamera: @unchecked Sendable {
    static let frameSize = CGSize(width: 1080, height: 1440)

    static let lenses: [Lens] = [
        Lens(id: "back.ultra", deviceID: "sim", position: .back, kind: .ultraWide, crop: 1, zoom: 0.5),
        Lens(id: "back.wide", deviceID: "sim", position: .back, kind: .wide, crop: 1, zoom: 1),
        Lens(id: "back.wide.crop2", deviceID: "sim", position: .back, kind: .wide, crop: 2, zoom: 2),
        Lens(id: "back.tele", deviceID: "sim", position: .back, kind: .tele, crop: 1, zoom: 4),
        Lens(id: "back.tele.crop2", deviceID: "sim", position: .back, kind: .tele, crop: 2, zoom: 8),
        Lens(id: "front.wide", deviceID: "sim", position: .front, kind: .front, crop: 1, zoom: 1),
    ]

    static let exposure = ExposureState(
        isoRange: 32...6400,
        shutterRange: (1.0 / 8000.0)...1.0,
        biasRange: -3...3,
        iso: 100,
        shutter: 1.0 / 125.0,
        bias: 0,
        kelvin: 5200,
        manualISO: nil,
        manualShutter: nil,
        manualKelvin: nil,
        aperture: 1.48,
        apertureStops: [1.48, 1.8, 2.8, 4],
        manualAperture: nil
    )

    static let focus = FocusState(
        lensPosition: 0.5,
        manualLensPosition: nil,
        point: nil,
        isTracking: false,
        trackedRect: nil
    )

    private let frames: PreviewFrameBus
    private let queue = DispatchQueue(label: "lol.peril.unproc.camera.demo.video", qos: .userInteractive)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()

    // Confined to `queue`.
    private var timer: DispatchSourceTimer?
    private var scene: CIImage?
    private var cache: [String: CIImage] = [:]
    private var lens: Lens?
    private var currentFrame: CIImage?

    init(frames: PreviewFrameBus) {
        self.frames = frames
    }

    func start(lens: Lens) {
        queue.async { [self] in
            self.lens = lens
            currentFrame = frame(for: lens)
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(4))
            source.setEventHandler { [weak self] in
                self?.tick()
            }
            source.resume()
            timer = source
        }
    }

    func setLens(_ lens: Lens) {
        queue.async { [self] in
            self.lens = lens
            currentFrame = frame(for: lens)
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    func capture(lens: Lens, exposureDuration: Double, iso: Float) async throws -> CapturedFrame {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CapturedFrame, Error>) in
            queue.async { [self] in
                let activeLens = self.lens ?? lens
                let image = currentFrame ?? frame(for: activeLens)
                guard let data = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [:]) else {
                    continuation.resume(throwing: UnprocError.captureFailed("Demo frame could not be encoded"))
                    return
                }
                continuation.resume(returning: CapturedFrame(
                    rawDNG: nil,
                    rawFlavor: nil,
                    processed: data,
                    metadata: [:],
                    lens: activeLens,
                    exposureDuration: exposureDuration,
                    iso: iso,
                    capturedAt: Date()
                ))
            }
        }
    }

    private func tick() {
        guard let currentFrame else { return }
        frames.publish(currentFrame)
    }

    // MARK: - Framing

    /// How much tighter than the full scene each lens frames (before its crop).
    private static func magnification(for lens: Lens) -> CGFloat {
        let physical: CGFloat
        switch lens.kind {
        case .ultraWide: physical = 1
        case .wide: physical = 1.4
        case .tele: physical = 1.4 * max(1, (lens.zoom / max(lens.crop, 1))).squareRoot()
        case .front: physical = 1.2
        }
        return max(1, physical * max(lens.crop, 1))
    }

    private func frame(for lens: Lens) -> CIImage {
        if let cached = cache[lens.id] { return cached }
        let source = sceneImage()
        let extent = source.extent

        // Largest centred 3:4 portrait region of the scene = the ultra-wide view.
        let aspect: CGFloat = 3.0 / 4.0
        let region: CGRect
        if extent.width / extent.height > aspect {
            let width = extent.height * aspect
            region = CGRect(x: extent.midX - width / 2, y: extent.minY, width: width, height: extent.height)
        } else {
            let height = extent.width / aspect
            region = CGRect(x: extent.minX, y: extent.midY - height / 2, width: extent.width, height: height)
        }

        let mag = Self.magnification(for: lens)
        let cropWidth = region.width / mag
        let cropHeight = region.height / mag
        let crop = CGRect(x: region.midX - cropWidth / 2, y: region.midY - cropHeight / 2,
                          width: cropWidth, height: cropHeight)
        let scale = Self.frameSize.width / cropWidth
        let output = CGRect(origin: .zero, size: Self.frameSize)

        var image = source.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if lens.isFront {
            image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: Self.frameSize.width, ty: 0))
        }
        image = image.clampedToExtent().cropped(to: output)

        let rendered: CIImage
        if let cgImage = context.createCGImage(image, from: output, format: .RGBA8, colorSpace: colorSpace) {
            rendered = CIImage(cgImage: cgImage)
        } else {
            rendered = image
        }
        if cache.count > 24 { cache.removeAll(keepingCapacity: true) }
        cache[lens.id] = rendered
        return rendered
    }

    // MARK: - Scene

    private func sceneImage() -> CIImage {
        if let scene { return scene }
        let loaded = Self.bundledScene() ?? Self.proceduralScene()
        scene = loaded
        return loaded
    }

    private static func bundledScene() -> CIImage? {
        guard let url = Bundle.main.url(forResource: "DemoScene", withExtension: "jpg"),
              let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return nil }
        return image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }

    /// A dusk landscape: gradient sky, sun with glow, three layers of hills.
    /// Built from resolution-independent generators, so it stays sharp at any zoom.
    private static func proceduralScene() -> CIImage {
        let size = CGSize(width: 2400, height: 3200)
        let bounds = CGRect(origin: .zero, size: size)

        let sky = CIFilter.linearGradient()
        sky.point0 = CGPoint(x: 0, y: size.height)
        sky.color0 = CIColor(red: 0.10, green: 0.20, blue: 0.43)
        sky.point1 = CGPoint(x: 0, y: 1500)
        sky.color1 = CIColor(red: 0.98, green: 0.63, blue: 0.36)

        let glow = CIFilter.radialGradient()
        glow.center = CGPoint(x: 1450, y: 1650)
        glow.radius0 = 90
        glow.radius1 = 720
        glow.color0 = CIColor(red: 1.0, green: 0.92, blue: 0.74, alpha: 1)
        glow.color1 = CIColor(red: 1.0, green: 0.72, blue: 0.45, alpha: 0)

        let sun = CIFilter.radialGradient()
        sun.center = CGPoint(x: 1450, y: 1650)
        sun.radius0 = 110
        sun.radius1 = 118
        sun.color0 = CIColor(red: 1.0, green: 0.97, blue: 0.88, alpha: 1)
        sun.color1 = CIColor(red: 1.0, green: 0.97, blue: 0.88, alpha: 0)

        func hill(centre: CGPoint, radius: Float, color: CIColor) -> CIImage? {
            let filter = CIFilter.radialGradient()
            filter.center = centre
            filter.radius0 = radius
            filter.radius1 = radius + 6
            filter.color0 = color
            filter.color1 = CIColor(red: color.red, green: color.green, blue: color.blue, alpha: 0)
            return filter.outputImage
        }

        var layers: [CIImage?] = [
            glow.outputImage,
            sun.outputImage,
            hill(centre: CGPoint(x: 700, y: -2600), radius: 4000,
                 color: CIColor(red: 0.33, green: 0.27, blue: 0.38)),
            hill(centre: CGPoint(x: 2100, y: -3300), radius: 4550,
                 color: CIColor(red: 0.15, green: 0.16, blue: 0.17)),
            hill(centre: CGPoint(x: -200, y: -5200), radius: 6000,
                 color: CIColor(red: 0.05, green: 0.06, blue: 0.05)),
        ]
        var image = sky.outputImage ?? CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.7))
        while !layers.isEmpty {
            if let layer = layers.removeFirst() {
                image = layer.composited(over: image)
            }
        }
        return image.cropped(to: bounds)
    }
}
