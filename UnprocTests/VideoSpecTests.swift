import CoreGraphics
import XCTest
@testable import Unproc

/// Pure video-mode and self-timer helpers.
final class VideoSpecTests: XCTestCase {
    func testTimerCycles() {
        XCTAssertEqual(SelfTimer.off.next, .three)
        XCTAssertEqual(SelfTimer.three.next, .ten)
        XCTAssertEqual(SelfTimer.ten.next, .off)
        XCTAssertEqual(SelfTimer.off.seconds, 0)
        XCTAssertEqual(SelfTimer.three.seconds, 3)
        XCTAssertEqual(SelfTimer.ten.seconds, 10)
        var t = SelfTimer.off
        for _ in 0..<3 { t = t.next }
        XCTAssertEqual(t, .off, "three presses come back to off")
    }

    func testBitrates() {
        XCTAssertEqual(VideoSpec.bitrate(resolution: .uhd4K, fps: 30), 50_000_000)
        XCTAssertEqual(VideoSpec.bitrate(resolution: .uhd4K, fps: 60), 80_000_000)
        XCTAssertEqual(VideoSpec.bitrate(resolution: .uhd4K, fps: 24), 42_000_000)
        XCTAssertEqual(VideoSpec.bitrate(resolution: .hd1080, fps: 30), 20_000_000)
        XCTAssertEqual(VideoSpec.bitrate(resolution: .hd1080, fps: 60), 32_000_000)
        XCTAssertEqual(VideoSpec.bitrate(resolution: .uhd4K, fps: 30, hdr: true), 60_000_000)
        XCTAssertLessThan(VideoSpec.bitrate(resolution: .hd1080, fps: 30), VideoSpec.bitrate(resolution: .uhd4K, fps: 30))
        XCTAssertLessThan(VideoSpec.bitrate(resolution: .uhd4K, fps: 30), VideoSpec.bitrate(resolution: .uhd4K, fps: 60))
    }

    func testBadges() {
        XCTAssertEqual(VideoSpec.badge(resolution: .uhd4K, fps: 30), "4K30")
        XCTAssertEqual(VideoSpec.badge(resolution: .uhd4K, fps: 60), "4K60")
        XCTAssertEqual(VideoSpec.badge(resolution: .hd1080, fps: 24), "1080·24")
    }

    func testResolutionSizes() {
        XCTAssertEqual(VideoResolution.uhd4K.longSide, 3840)
        XCTAssertEqual(VideoResolution.uhd4K.shortSide, 2160)
        XCTAssertEqual(VideoResolution.hd1080.longSide, 1920)
        XCTAssertEqual(VideoResolution.hd1080.shortSide, 1080)
    }

    func testOfferedRatesAndResolve() {
        XCTAssertEqual(VideoSpec.offeredRates(maxRate: 30), [.fps24, .fps30])
        XCTAssertEqual(VideoSpec.offeredRates(maxRate: 60), [.fps24, .fps30, .fps60])
        XCTAssertEqual(VideoSpec.offeredRates(maxRate: 59.94), [.fps24, .fps30, .fps60])
        XCTAssertEqual(VideoSpec.offeredRates(maxRate: 25), [.fps24])
        XCTAssertEqual(VideoSpec.resolve(.fps60, offered: [.fps24, .fps30]), .fps30)
        XCTAssertEqual(VideoSpec.resolve(.fps24, offered: [.fps30]), .fps30)
        XCTAssertEqual(VideoSpec.resolve(.fps30, offered: [.fps24, .fps30, .fps60]), .fps30)
        XCTAssertEqual(VideoSpec.resolve(.fps60, offered: []), .fps60)
    }

    func testOutputSize() {
        // Portrait 4K frame from the camera: kept.
        XCTAssertEqual(VideoSpec.outputSize(frame: CGSize(width: 2160, height: 3840), longSide: 3840),
                       CGSize(width: 2160, height: 3840))
        // Capped to 1080p.
        XCTAssertEqual(VideoSpec.outputSize(frame: CGSize(width: 2160, height: 3840), longSide: 1920),
                       CGSize(width: 1080, height: 1920))
        // 3:4 demo frame: its 9:16 centre.
        XCTAssertEqual(VideoSpec.outputSize(frame: CGSize(width: 1080, height: 1440), longSide: 3840),
                       CGSize(width: 810, height: 1440))
        // Landscape stays landscape.
        XCTAssertEqual(VideoSpec.outputSize(frame: CGSize(width: 1920, height: 1440), longSide: 3840),
                       CGSize(width: 1920, height: 1080))
        // Square: 9:16 inside it, even sizes.
        let square = VideoSpec.outputSize(frame: CGSize(width: 1001, height: 1001), longSide: 3840)
        XCTAssertEqual(square.height, 1000)
        XCTAssertEqual(Int(square.width) % 2, 0)
        XCTAssertEqual(VideoSpec.outputSize(frame: .zero, longSide: 3840), .zero)
    }

    func testTrackRotation() {
        XCTAssertEqual(VideoSpec.trackRotation(captureAngle: 90, recordedAngle: 90), 0)
        XCTAssertEqual(VideoSpec.trackRotation(captureAngle: 0, recordedAngle: 90), 270)
        XCTAssertEqual(VideoSpec.trackRotation(captureAngle: 180, recordedAngle: 90), 90)
        XCTAssertEqual(VideoSpec.trackRotation(captureAngle: 270, recordedAngle: 90), 180)
        XCTAssertEqual(VideoSpec.trackRotation(captureAngle: 89.4, recordedAngle: 0), 90)
    }

    func testTrackTransformKeepsFramesInPositiveQuadrant() {
        let w: CGFloat = 1080, h: CGFloat = 1920
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        XCTAssertEqual(VideoSpec.trackTransform(degrees: 0, width: w, height: h), .identity)
        for degrees in [90, 180, 270] {
            let t = VideoSpec.trackTransform(degrees: degrees, width: w, height: h)
            let out = rect.applying(t)
            XCTAssertEqual(out.minX, 0, accuracy: 0.001, "\(degrees)")
            XCTAssertEqual(out.minY, 0, accuracy: 0.001, "\(degrees)")
            if degrees == 180 {
                XCTAssertEqual(out.size, CGSize(width: w, height: h))
            } else {
                XCTAssertEqual(out.size, CGSize(width: h, height: w))
            }
        }
        // 90° clockwise: the top-left corner goes to the top-right.
        let t90 = VideoSpec.trackTransform(degrees: 90, width: w, height: h)
        XCTAssertEqual(CGPoint.zero.applying(t90), CGPoint(x: h, y: 0))
    }

    func testTimecode() {
        XCTAssertEqual(Timecode.string(0), "00:00")
        XCTAssertEqual(Timecode.string(5.9), "00:05")
        XCTAssertEqual(Timecode.string(65), "01:05")
        XCTAssertEqual(Timecode.string(3599), "59:59")
        XCTAssertEqual(Timecode.string(3600), "60:00")
        XCTAssertEqual(Timecode.string(-3), "00:00")
        XCTAssertEqual(Timecode.string(.nan), "00:00")
        XCTAssertEqual(Timecode.short(5), "0:05")
        XCTAssertEqual(Timecode.short(83.4), "1:23")
        XCTAssertEqual(Timecode.short(3723), "1:02:03")
    }

    @MainActor
    func testVideoRequestFromSettings() {
        var s = CaptureSettings()
        XCTAssertNil(CameraScreen.videoRequest(s, locked: false), "photo mode")
        s.mode = .video
        s.videoResolution = .hd1080
        s.videoFPS = .fps60
        s.videoHDR = true
        let request = CameraScreen.videoRequest(s, locked: false)
        XCTAssertEqual(request, VideoModeRequest(resolution: .hd1080, fps: .fps60, hdr: true, audio: true))
        XCTAssertNil(CameraScreen.videoRequest(s, locked: true), "the lock-screen extension is photos only")
    }
}
