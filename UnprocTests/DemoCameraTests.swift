import AVFoundation
import CoreImage
import ImageIO
import XCTest
@testable import Unproc

/// Exercises `CameraController` in demo mode (Simulator), where it runs on
/// `SimulatorCamera` and never touches AVFoundation capture.
@MainActor
final class DemoCameraTests: XCTestCase {
    private func startedCamera(lens: String? = nil) async throws -> CameraController {
        guard CameraController.isDemo else {
            throw XCTSkip("CameraController tests need demo mode (Simulator or -UNPROC_DEMO)")
        }
        let camera = CameraController()
        await camera.start(preferredLensID: lens, rawFlavor: .bayer)
        return camera
    }

    /// Polls on the main actor (letting other main-actor work run) until `condition` holds.
    private func waitUntil(timeout: TimeInterval = 2, _ what: String,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(what)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testStartPublishesDemoLenses() async throws {
        let camera = try await startedCamera()
        defer { camera.stop() }
        XCTAssertEqual(camera.status, .running)
        XCTAssertFalse(camera.lenses.isEmpty)
        let ids = camera.lenses.map(\.id)
        XCTAssertTrue(ids.contains("back.wide"))
        XCTAssertTrue(ids.contains("front.wide"))
        XCTAssertEqual(Set(ids).count, ids.count, "lens ids are unique")
        XCTAssertEqual(camera.currentLens?.id, "back.wide", "defaults to the main camera")
        XCTAssertEqual(camera.lenses.last?.isFront, true, "front lens is last")
    }

    func testStartHonoursPreferredLensAndIsIdempotent() async throws {
        let camera = try await startedCamera(lens: "back.tele")
        defer { camera.stop() }
        XCTAssertEqual(camera.currentLens?.id, "back.tele")
        let count = camera.lenses.count
        await camera.start(preferredLensID: "back.ultra", rawFlavor: .bayer)
        XCTAssertEqual(camera.lenses.count, count, "restarting must not duplicate lenses")
        XCTAssertEqual(camera.currentLens?.id, "back.tele", "a restart keeps the lens in use")
    }

    func testUnknownPreferredLensFallsBackToWide() async throws {
        let camera = try await startedCamera(lens: "back.nonexistent")
        defer { camera.stop() }
        XCTAssertEqual(camera.currentLens?.id, "back.wide")
    }

    func testZoomStopsAreAscendingUniqueBackOnly() async throws {
        let camera = try await startedCamera()
        defer { camera.stop() }
        let stops = camera.zoomStops
        XCTAssertEqual(stops, [0.5, 1, 2, 4, 8])
        for i in stops.indices.dropFirst() { XCTAssertGreaterThan(stops[i], stops[i - 1]) }
        // And they make a valid Camera Control slider.
        let values = CaptureControlsInstaller.zoomValues(stops: stops.map { Float($0) })
        XCTAssertEqual(values.first, 0.5)
        XCTAssertEqual(values.last, 8)
    }

    func testSetZoomBetweenStopsCropsTheRightPhysicalLens() async throws {
        let camera = try await startedCamera()
        defer { camera.stop() }

        camera.setZoom(2.4)
        await waitUntil("zoom 2.4") { abs((camera.currentLens?.zoom ?? 0) - 2.4) < 0.001 }
        var lens = try XCTUnwrap(camera.currentLens)
        XCTAssertEqual(lens.kind, .wide)
        XCTAssertEqual(lens.crop, 2.4, accuracy: 0.001)
        XCTAssertEqual(lens.position, .back)

        camera.setZoom(5)
        await waitUntil("zoom 5") { abs((camera.currentLens?.zoom ?? 0) - 5) < 0.001 }
        lens = try XCTUnwrap(camera.currentLens)
        XCTAssertEqual(lens.kind, .tele)
        XCTAssertEqual(lens.crop, 1.25, accuracy: 0.001)

        camera.setZoom(0.7)
        await waitUntil("zoom 0.7") { abs((camera.currentLens?.zoom ?? 0) - 0.7) < 0.001 }
        lens = try XCTUnwrap(camera.currentLens)
        XCTAssertEqual(lens.kind, .ultraWide)
        XCTAssertEqual(lens.crop, 1.4, accuracy: 0.001)
    }

    func testSetZoomOnAStopSelectsTheRealLens() async throws {
        let camera = try await startedCamera()
        defer { camera.stop() }
        camera.setZoom(4.02)   // within 1 % of the tele
        await waitUntil("tele") { camera.currentLens?.id == "back.tele" }
        camera.setZoom(2)
        await waitUntil("2x crop") { camera.currentLens?.id == "back.wide.crop2" }
    }

    func testSetZoomClampsToRange() async throws {
        let camera = try await startedCamera()
        defer { camera.stop() }
        camera.setZoom(100)
        await waitUntil("max stop") { camera.currentLens?.id == "back.tele.crop2" }
        camera.setZoom(0.01)
        await waitUntil("min stop") { camera.currentLens?.id == "back.ultra" }
    }

    func testRapidSetZoomCoalescesToLastValue() async throws {
        let camera = try await startedCamera()
        defer { camera.stop() }
        for z in stride(from: CGFloat(1), through: 3, by: 0.05) { camera.setZoom(z) }
        camera.setZoom(3.3)
        await waitUntil("final zoom") { abs((camera.currentLens?.zoom ?? 0) - 3.3) < 0.001 }
        // Give any stale work a moment; the final value must stick.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(camera.currentLens?.zoom ?? 0, 3.3, accuracy: 0.001)
    }

    func testSelectFrontAndBack() async throws {
        let camera = try await startedCamera()
        defer { camera.stop() }
        let front = try XCTUnwrap(camera.lenses.first { $0.isFront })
        await camera.select(front)
        XCTAssertEqual(camera.currentLens?.id, "front.wide")
        XCTAssertEqual(camera.currentLens?.label, "FRONT")

        let wide = try XCTUnwrap(camera.lenses.first { $0.id == "back.wide" })
        await camera.select(wide)
        XCTAssertEqual(camera.currentLens?.id, "back.wide")
    }

    // MARK: Selfie framings

    func testFrontHasTwoFramingsOnOneDevice() async throws {
        let camera = try await startedCamera()
        defer { camera.stop() }
        XCTAssertTrue(camera.frontHasStops)
        XCTAssertEqual(camera.frontLenses.map(\.id), ["front.wide", "front.tight"])
        XCTAssertEqual(Set(camera.frontLenses.map(\.deviceID)).count, 1, "both framings are one device")
        let stops = camera.frontZoomStops
        XCTAssertEqual(stops.count, 2)
        XCTAssertEqual(stops[0], 1 / LensDiscovery.squareFrontFallbackFactor, accuracy: 1e-9)
        XCTAssertEqual(stops[1], 1)
        XCTAssertEqual(camera.backZoomStops, [0.5, 1, 2, 4, 8])
        XCTAssertEqual(camera.zoomStops, camera.backZoomStops, "on the back camera the ruler shows back stops")
    }

    func testFlipLandsOnTheStandardFramingAndRemembersTheLastOne() async throws {
        let camera = try await startedCamera()
        defer { camera.stop() }
        await camera.flip(toFront: true)
        XCTAssertEqual(camera.currentLens?.id, "front.tight", "first flip: the standard selfie framing")
        XCTAssertEqual(camera.zoomStops, camera.frontZoomStops, "on the front the ruler shows the selfie stops")

        await camera.toggleFrontFraming()
        XCTAssertEqual(camera.currentLens?.id, "front.wide")
        await camera.toggleFrontFraming()
        XCTAssertEqual(camera.currentLens?.id, "front.tight")
        await camera.toggleFrontFraming()
        XCTAssertEqual(camera.currentLens?.id, "front.wide")

        await camera.flip(toFront: false)
        XCTAssertEqual(camera.currentLens?.id, "back.wide")
        XCTAssertNil(camera.switchTarget)
        await camera.flip(toFront: true)
        XCTAssertEqual(camera.currentLens?.id, "front.wide", "comes back to the last selfie framing")
        // Flipping to where it already is does nothing.
        await camera.flip(toFront: true)
        XCTAssertEqual(camera.currentLens?.id, "front.wide")
    }

    func testFrontZoomStaysOnTheFrontCamera() async throws {
        let camera = try await startedCamera()
        defer { camera.stop() }
        await camera.flip(toFront: true)
        camera.setZoom(0.9)
        await waitUntil("front zoom 0.9") { abs((camera.currentLens?.zoom ?? 0) - 0.9) < 0.001 }
        var lens = try XCTUnwrap(camera.currentLens)
        XCTAssertTrue(lens.isFront)
        XCTAssertEqual(lens.crop, 0.9 * LensDiscovery.squareFrontFallbackFactor, accuracy: 0.001)
        camera.setZoom(5)
        await waitUntil("front max") { camera.currentLens?.id == "front.tight" }
        camera.setZoom(0.1)
        await waitUntil("front min") { camera.currentLens?.id == "front.wide" }
        lens = try XCTUnwrap(camera.currentLens)
        XCTAssertTrue(lens.isFront, "zooming out on the selfie camera never lands on a back lens")
    }

    func testQueuedBackZoomDoesNotUndoAFlip() async throws {
        // The scrub that pulls past .5× sends zooms right up to the flip; one
        // still queued must not switch back to a back lens afterwards.
        let camera = try await startedCamera()
        defer { camera.stop() }
        camera.setZoom(0.7)
        await camera.flip(toFront: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(camera.currentLens?.isFront, true, "flip undone by a stale zoom (now \(camera.currentLens?.id ?? "nil"))")
        XCTAssertEqual(camera.currentLens?.id, "front.tight")
    }

    func testSelectUnknownDeviceIsIgnored() async throws {
        let camera = try await startedCamera()
        defer { camera.stop() }
        let stranger = Lens(id: "alien", deviceID: "other-device", position: .back, kind: .wide, crop: 1, zoom: 3)
        await camera.select(stranger)
        XCTAssertEqual(camera.currentLens?.id, "back.wide")
    }

    func testCaptureReturnsProcessedFrame() async throws {
        let camera = try await startedCamera()
        defer { camera.stop() }
        let frame = try await camera.capture(output: .jpeg)
        let data = try XCTUnwrap(frame.processed)
        XCTAssertNil(frame.rawDNG, "a JPEG capture carries no DNG")
        XCTAssertEqual(frame.lens.id, "back.wide")
        let cg = try XCTUnwrap(TestSupport.cgImage(ofImageData: data))
        XCTAssertEqual(cg.width, Int(SimulatorCamera.frameSize.width))
        XCTAssertEqual(cg.height, Int(SimulatorCamera.frameSize.height))
    }

    func testCaptureFromZoomedLensIsNotCroppedTwice() async throws {
        let camera = try await startedCamera()
        defer { camera.stop() }
        camera.setZoom(2.4)
        await waitUntil("zoom 2.4") { abs((camera.currentLens?.zoom ?? 0) - 2.4) < 0.001 }
        let frame = try await camera.capture(output: .jpeg)
        XCTAssertEqual(frame.lens.crop, 2.4, accuracy: 0.001)
        XCTAssertNil(frame.rawDNG)
        // Demo frames are already framed for the lens; developing a processed
        // frame must not apply the lens crop again.
        let developed = try Developer.shared.develop(frame)
        XCTAssertEqual(developed.extent, CGRect(origin: .zero, size: SimulatorCamera.frameSize))
    }

    func testRapidCapturesAllSucceedInOrder() async throws {
        let camera = try await startedCamera()
        defer { camera.stop() }
        async let a = camera.capture(output: .jpeg)
        async let b = camera.capture(output: .jpeg)
        async let c = camera.capture(output: .jpeg)
        let frames = try await [a, b, c]
        XCTAssertEqual(frames.count, 3)
        for f in frames { XCTAssertNotNil(f.processed) }
    }

    func testRawCaptureUsesBundledDNGWhenPresent() async throws {
        let camera = try await startedCamera()
        defer { camera.stop() }
        let frame = try await camera.capture(output: .raw)
        if SimulatorCamera.demoDNG != nil {
            XCTAssertNotNil(frame.rawDNG)
            XCTAssertEqual(frame.rawFlavor, .bayer)
        } else {
            XCTAssertNotNil(frame.processed, "without a bundled DNG, RAW falls back to a processed frame")
        }
    }

    func testPreviewFramesArrive() async throws {
        let camera = try await startedCamera()
        defer { camera.stop() }
        // First frame loads + renders the demo scene; slow CI simulators need headroom.
        await waitUntil(timeout: 10, "a preview frame") { camera.frames.latestFrame != nil }
        if let frame = camera.frames.latestFrame {
            XCTAssertEqual(frame.extent.size, SimulatorCamera.frameSize)
        }
    }

    func testManualControlsClampInDemo() async throws {
        let camera = try await startedCamera()
        defer { camera.stop() }
        camera.setISO(1_000_000)
        XCTAssertEqual(camera.exposure.manualISO, camera.exposure.isoRange.upperBound)
        camera.setExposureBias(-50)
        XCTAssertEqual(camera.exposure.bias, camera.exposure.biasRange.lowerBound)
        camera.setWhiteBalance(kelvin: 100)
        XCTAssertEqual(camera.exposure.manualKelvin, CameraController.kelvinRange.lowerBound)
        camera.setAperture(3.0)
        XCTAssertEqual(camera.exposure.manualAperture, 2.8)
        camera.proEnabled = true
        camera.proEnabled = false
        XCTAssertNil(camera.exposure.manualISO, "leaving pro mode reverts to auto")
        XCTAssertNil(camera.exposure.manualAperture)
        XCTAssertEqual(camera.exposure.bias, 0)
    }

    // MARK: Video (demo)

    func testDemoVideoModeRecordsAMovieWithTheLook() async throws {
        let camera = try await startedCamera()
        defer { camera.stop() }
        await waitUntil(timeout: 10, "a preview frame") { camera.frames.latestFrame != nil }
        XCTAssertFalse(camera.isVideoMode)
        await camera.setVideoMode(VideoModeRequest(resolution: .hd1080, fps: .fps30, hdr: false, audio: false))
        XCTAssertTrue(camera.isVideoMode)
        XCTAssertEqual(camera.videoFormat?.label, "1080·30")

        try await camera.startRecording(look: LookLibrary.look(id: "s1-01"))
        XCTAssertTrue(camera.isRecording)
        XCTAssertNotNil(camera.recordingStartedAt)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let video = try await camera.stopRecording()
        defer { try? FileManager.default.removeItem(at: video.url) }
        XCTAssertFalse(camera.isRecording)
        // CI simulators render and encode slowly; any frames prove the pipeline.
        XCTAssertGreaterThan(video.frames, 0, "frames were written")
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.url.path))
        // Demo frames are 3:4 (1080x1440); the recording is their 9:16 centre.
        XCTAssertEqual(video.width, 810)
        XCTAssertEqual(video.height, 1440)
        XCTAssertGreaterThan(video.duration, 0)

        let asset = AVURLAsset(url: video.url)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty, "no audio in demo mode")

        await camera.setVideoMode(nil)
        XCTAssertFalse(camera.isVideoMode)
        XCTAssertNil(camera.videoFormat)
    }

    func testStopWithoutRecordingThrows() async throws {
        let camera = try await startedCamera()
        defer { camera.stop() }
        do {
            _ = try await camera.stopRecording()
            XCTFail("stopRecording must throw when not recording")
        } catch {}
    }

    func testRecordingRefusedInPhotoMode() async throws {
        let camera = try await startedCamera()
        defer { camera.stop() }
        do {
            try await camera.startRecording(look: .zero)
            XCTFail("recording must be refused in photo mode")
        } catch {}
        XCTAssertFalse(camera.isRecording)
    }
}
