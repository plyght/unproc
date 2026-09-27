import AVFoundation
import CoreImage
import ImageIO
import XCTest
@testable import Unproc

final class JPEGPipelineTests: XCTestCase {
    private let developer = Developer.shared

    private func frame(width: Int = 64, height: Int = 48,
                       crop: CGFloat = 1,
                       metadata: [String: Any] = TestSupport.realisticMetadata(),
                       rawDNG: Data? = nil) -> CapturedFrame {
        CapturedFrame(rawDNG: rawDNG,
                      rawFlavor: rawDNG == nil ? nil : .bayer,
                      processed: TestSupport.jpegData(width: width, height: height),
                      metadata: metadata,
                      lens: TestSupport.lens(crop: crop, zoom: crop),
                      exposureDuration: 1.0 / 125.0,
                      iso: 100,
                      capturedAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    private func assertCleanJPEG(_ jpeg: Data, width: Int, height: Int,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let props = try XCTUnwrap(TestSupport.properties(ofImageData: jpeg), "JPEG not decodable", file: file, line: line)
        let cg = try XCTUnwrap(TestSupport.cgImage(ofImageData: jpeg), "JPEG has no image", file: file, line: line)
        XCTAssertEqual(cg.width, width, file: file, line: line)
        XCTAssertEqual(cg.height, height, file: file, line: line)
        XCTAssertEqual(props[kCGImagePropertyPixelWidth as String] as? Int, width, file: file, line: line)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight as String] as? Int, height, file: file, line: line)
        if let orientation = props[kCGImagePropertyOrientation as String] as? Int {
            XCTAssertEqual(orientation, 1, "pixels are upright; orientation must be 1", file: file, line: line)
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           let orientation = tiff[kCGImagePropertyTIFFOrientation as String] as? Int {
            XCTAssertEqual(orientation, 1, file: file, line: line)
        }
        XCTAssertNil(props[kCGImagePropertyDNGDictionary as String], "DNG dictionary leaked into the JPEG", file: file, line: line)
        if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            if let x = exif[kCGImagePropertyExifPixelXDimension as String] as? Int {
                XCTAssertEqual(x, width, file: file, line: line)
            }
            if let y = exif[kCGImagePropertyExifPixelYDimension as String] as? Int {
                XCTAssertEqual(y, height, file: file, line: line)
            }
        }
    }

    // MARK: Develop

    func testDevelopProcessedFrameKeepsSizeAndZeroOrigin() throws {
        let image = try developer.develop(frame(width: 64, height: 48))
        XCTAssertEqual(image.extent, CGRect(x: 0, y: 0, width: 64, height: 48))
    }

    func testDevelopDoesNotCropProcessedFrames() throws {
        // Processed photos already carry the device's digital zoom (and demo
        // frames are pre-cropped); only full-sensor RAW gets the lens crop.
        for crop: CGFloat in [2, 2.4, 1.25] {
            let image = try developer.develop(frame(width: 64, height: 48, crop: crop))
            XCTAssertEqual(image.extent, CGRect(x: 0, y: 0, width: 64, height: 48), "crop \(crop)")
        }
        let odd = try developer.develop(frame(width: 81, height: 61, crop: 2))
        XCTAssertEqual(odd.extent, CGRect(x: 0, y: 0, width: 81, height: 61))
    }

    func testDevelopRejectsEmptyAndGarbageFrames() {
        var empty = frame()
        empty.processed = nil
        XCTAssertThrowsError(try developer.develop(empty))

        var garbage = frame()
        garbage.processed = Data("definitely not a jpeg".utf8)
        XCTAssertThrowsError(try developer.develop(garbage))
    }

    func testDevelopHonoursEXIFOrientationOfProcessedData() throws {
        // A 64×48 JPEG tagged orientation 6 (rotate 90° CW) develops to 48×64.
        let cg = try XCTUnwrap(TestSupport.context.createCGImage(TestSupport.gradientImage(width: 64, height: 48),
                                                                  from: CGRect(x: 0, y: 0, width: 64, height: 48)))
        let data = try XCTUnwrap(Developer.encodeJPEG(cg, properties: [kCGImagePropertyOrientation as String: 6]))
        var f = frame()
        f.processed = data
        let image = try developer.develop(f)
        XCTAssertEqual(image.extent, CGRect(x: 0, y: 0, width: 48, height: 64))
    }

    // MARK: Finish

    func testFinishProducesCleanUprightJPEG() throws {
        let f = frame(width: 64, height: 48)
        let image = try developer.develop(f)
        let photo = try developer.finish(image, look: .zero, frame: f, includeDNG: true)
        XCTAssertNil(photo.dng, "no RAW captured, no DNG")
        XCTAssertEqual(photo.capturedAt, f.capturedAt)
        try assertCleanJPEG(photo.jpeg, width: 64, height: 48)

        let props = try XCTUnwrap(TestSupport.properties(ofImageData: photo.jpeg))
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFSoftware as String] as? String, "unproc")
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFMake as String] as? String, "Apple")
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertNotNil(exif?[kCGImagePropertyExifFNumber as String], "capture EXIF should survive")
    }

    func testFinishWithEveryLook() throws {
        let f = frame(width: 64, height: 48, crop: 2)
        let image = try developer.develop(f)
        for look in LookLibrary.all {
            let photo = try developer.finish(image, look: look, frame: f, includeDNG: false)
            try assertCleanJPEG(photo.jpeg, width: 64, height: 48)
        }
    }

    func testFinishPassesDNGThroughOnlyWhenAsked() throws {
        let dng = Data("fake dng bytes".utf8)
        let f = frame(rawDNG: dng)
        // Develop from the processed data; `finish` only forwards the DNG.
        let image = TestSupport.gradientImage(width: 64, height: 48)
        XCTAssertEqual(try developer.finish(image, look: .zero, frame: f, includeDNG: true).dng, dng)
        XCTAssertNil(try developer.finish(image, look: .zero, frame: f, includeDNG: false).dng)
    }

    func testFinishWithEmptyMetadata() throws {
        let f = frame(metadata: [:])
        let photo = try developer.finish(try developer.develop(f), look: .zero, frame: f, includeDNG: false)
        try assertCleanJPEG(photo.jpeg, width: 64, height: 48)
    }

    func testFinishRejectsInfiniteImage() {
        let f = frame()
        XCTAssertThrowsError(try developer.finish(CIImage(color: .white), look: .zero, frame: f, includeDNG: false))
    }

    func testFinishTranslatedExtentStillEncodes() throws {
        let f = frame()
        let image = TestSupport.gradientImage(width: 64, height: 48)
            .transformed(by: CGAffineTransform(translationX: 10, y: 20))
        let photo = try developer.finish(image, look: .zero, frame: f, includeDNG: false)
        try assertCleanJPEG(photo.jpeg, width: 64, height: 48)
    }

    // MARK: jpegProperties

    func testJPEGPropertiesStripContainerKeysAndResetOrientation() throws {
        let props = Developer.jpegProperties(from: TestSupport.realisticMetadata(), width: 800, height: 600)
        XCTAssertEqual(props[kCGImagePropertyOrientation as String] as? Int, 1)
        for key in [kCGImagePropertyDNGDictionary, kCGImagePropertyRawDictionary, kCGImagePropertyPixelWidth,
                    kCGImagePropertyPixelHeight, kCGImagePropertyDepth, kCGImagePropertyColorModel] {
            XCTAssertNil(props[key as String], "\(key) should be dropped")
        }
        let tiff = try XCTUnwrap(props[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFOrientation as String] as? Int, 1)
        XCTAssertEqual(tiff[kCGImagePropertyTIFFSoftware as String] as? String, "unproc")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFModel as String] as? String, "iPhone Test")
        for key in ["TileWidth", "TileLength", "Compression", "PhotometricInterpretation"] {
            XCTAssertNil(tiff[key], "TIFF \(key) should be dropped")
        }
        let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary as String] as? [String: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifPixelXDimension as String] as? Int, 800)
        XCTAssertEqual(exif[kCGImagePropertyExifPixelYDimension as String] as? Int, 600)
        XCTAssertEqual(exif[kCGImagePropertyExifColorSpace as String] as? Int, 65535)
        XCTAssertNil(exif[kCGImagePropertyExifCompressedBitsPerPixel as String])
        XCTAssertNotNil(exif[kCGImagePropertyExifLensModel as String])
        XCTAssertNotNil(props[kCGImagePropertyMakerAppleDictionary as String], "MakerApple is kept")
        XCTAssertEqual(props[kCGImageDestinationLossyCompressionQuality as String] as? CGFloat, Developer.jpegQuality)
    }

    func testJPEGPropertiesFromEmptyMetadata() {
        let props = Developer.jpegProperties(from: [:], width: 10, height: 20)
        XCTAssertEqual(props[kCGImagePropertyOrientation as String] as? Int, 1)
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifPixelXDimension as String] as? Int, 10)
        XCTAssertEqual(exif?[kCGImagePropertyExifPixelYDimension as String] as? Int, 20)
    }

    func testJPEGPropertiesTolerateWronglyTypedDictionaries() {
        // TIFF / EXIF entries of the wrong type are replaced rather than crashing.
        let odd: [String: Any] = [
            kCGImagePropertyTIFFDictionary as String: "not a dictionary",
            kCGImagePropertyExifDictionary as String: [1, 2, 3],
        ]
        let props = Developer.jpegProperties(from: odd, width: 5, height: 6)
        XCTAssertNotNil(props[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
        XCTAssertNotNil(props[kCGImagePropertyExifDictionary as String] as? [String: Any])
    }

    // MARK: encodeJPEG

    func testEncodeJPEGWithOddMetadataValues() throws {
        let cg = try XCTUnwrap(TestSupport.context.createCGImage(TestSupport.gradientImage(width: 32, height: 32),
                                                                  from: CGRect(x: 0, y: 0, width: 32, height: 32)))
        var metadata = TestSupport.realisticMetadata()
        metadata["{Exif}"] = [
            kCGImagePropertyExifSubjectArea as String: [1, 2, 3, 4],
            kCGImagePropertyExifISOSpeedRatings as String: [Double(100), Double(200)],
            kCGImagePropertyExifUserComment as String: "",
            "SomethingNested": ["a": ["b": [1, 2, ["c": "d"] as [String: Any]] as [Any]] as [String: Any]] as [String: Any],
            "Weird": [[1, 2], [3, 4]] as [[Int]],
        ] as [String: Any]
        metadata[kCGImagePropertyGPSDictionary as String] = [
            kCGImagePropertyGPSLatitude as String: 51.5,
            kCGImagePropertyGPSLatitudeRef as String: "N",
            kCGImagePropertyGPSLongitude as String: 0.12,
            kCGImagePropertyGPSLongitudeRef as String: "W",
        ] as [String: Any]
        metadata["{UnknownVendor}"] = ["x": [1.5, "two", 3] as [Any]] as [String: Any]
        metadata["TopLevelArray"] = [1, 2, 3]
        let props = Developer.jpegProperties(from: metadata, width: 32, height: 32)
        let jpeg = try XCTUnwrap(Developer.encodeJPEG(cg, properties: props))
        try assertCleanJPEG(jpeg, width: 32, height: 32)

        XCTAssertNotNil(Developer.encodeJPEG(cg, properties: [:]))
    }

    // MARK: Real RAW (CI bundles a DNG into simulator builds)

    func testBundledDemoDNGGetsLensCrop() throws {
        guard let dng = SimulatorCamera.demoDNG else {
            throw XCTSkip("DemoRAW.dng not bundled in this build")
        }
        func develop(crop: CGFloat) throws -> CGRect {
            let f = CapturedFrame(rawDNG: dng, rawFlavor: .bayer, processed: nil, metadata: [:],
                                  lens: TestSupport.lens(crop: crop, zoom: crop), exposureDuration: nil, iso: nil,
                                  capturedAt: Date())
            return try developer.develop(f).extent   // lazy: no pixels are rendered
        }
        let full = try develop(crop: 1)
        let cropped = try develop(crop: 2)
        XCTAssertEqual(full.origin, .zero)
        XCTAssertEqual(cropped.origin, .zero)
        XCTAssertEqual(cropped.width, (full.width / 2).rounded(.down), accuracy: 1)
        XCTAssertEqual(cropped.height, (full.height / 2).rounded(.down), accuracy: 1)
    }

    func testBundledDemoDNGDevelopsToCleanJPEG() throws {
        guard let dng = SimulatorCamera.demoDNG else {
            throw XCTSkip("DemoRAW.dng not bundled in this build")
        }
        let metadata = SimulatorCamera.metadata(of: dng)
        XCTAssertFalse(metadata.isEmpty)
        let f = CapturedFrame(rawDNG: dng, rawFlavor: .bayer, processed: nil, metadata: metadata,
                              lens: TestSupport.lens(), exposureDuration: 1.0 / 60.0, iso: 100,
                              capturedAt: Date())
        let full = try developer.develop(f)
        XCTAssertEqual(full.extent.origin, .zero)
        XCTAssertGreaterThan(full.extent.width, 100)
        // Finish a small version to keep the test quick; metadata handling is identical.
        let scale = 256 / max(full.extent.width, full.extent.height)
        let small = full.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rect = small.extent.integral
        let photo = try developer.finish(small, look: LookLibrary.all[1], frame: f, includeDNG: true)
        XCTAssertEqual(photo.dng, dng)
        try assertCleanJPEG(photo.jpeg, width: Int(rect.width), height: Int(rect.height))
    }

    // MARK: RAW crop measured from the DNG's focal length

    private func rawFrame(crop: CGFloat, zoom: CGFloat, focal35: Double?, front: Bool = false) -> CapturedFrame {
        var metadata: [String: Any] = [:]
        if let focal35 {
            metadata[kCGImagePropertyExifDictionary as String] = [kCGImagePropertyExifFocalLenIn35mmFilm as String: focal35]
        }
        return CapturedFrame(rawDNG: Data([0]), rawFlavor: .proRAW, processed: nil, metadata: metadata,
                             lens: TestSupport.lens(position: front ? .front : .back, crop: crop, zoom: zoom),
                             exposureDuration: nil, iso: nil, capturedAt: Date())
    }

    func testRawCropSkipsWhenCameraAlreadyZoomed() {
        // 1× stop, but the RAW came from the ultra-wide with the zoom already applied (macro switch).
        XCTAssertEqual(Developer.rawCrop(for: rawFrame(crop: 2, zoom: 1, focal35: 24)), 1)
        // 2× stop, RAW already at 48mm.
        XCTAssertEqual(Developer.rawCrop(for: rawFrame(crop: 2, zoom: 2, focal35: 48)), 1)
    }

    func testRawCropAppliesWhenRAWIsFullSensor() {
        // 2× on the wide, RAW at the wide's native 24mm: crop the model's exact 2.
        XCTAssertEqual(Developer.rawCrop(for: rawFrame(crop: 2, zoom: 2, focal35: 24)), 2)
        // Older phones (26mm main) still land on the model value.
        XCTAssertEqual(Developer.rawCrop(for: rawFrame(crop: 2, zoom: 2, focal35: 26)), 2)
        // 1× from the ultra-wide at its native 13mm: crop ≈ 2 (the model's value).
        XCTAssertEqual(Developer.rawCrop(for: rawFrame(crop: 2, zoom: 1, focal35: 13)), 2)
    }

    func testRawCropFallsBackWithoutFocalOrOnFront() {
        XCTAssertEqual(Developer.rawCrop(for: rawFrame(crop: 2, zoom: 2, focal35: nil)), 2)
        XCTAssertEqual(Developer.rawCrop(for: rawFrame(crop: 1, zoom: 1, focal35: 30, front: true)), 1)
    }
}
