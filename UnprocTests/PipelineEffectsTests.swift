import CoreImage
import XCTest
@testable import Unproc

final class PipelineEffectsTests: XCTestCase {
    private func solid(_ v: CGFloat, _ rect: CGRect) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v)).cropped(to: rect)
    }

    private func stats(_ px: [Float]) -> (min: Float, max: Float, nonFinite: Int) {
        var lo = Float.infinity, hi = -Float.infinity, bad = 0
        for (i, v) in px.enumerated() where i % 4 != 3 {
            if !v.isFinite { bad += 1; continue }
            lo = min(lo, v)
            hi = max(hi, v)
        }
        return (lo, hi, bad)
    }

    // MARK: MultiExposure

    func testBlendKeepsFirstExtent() {
        let first = TestSupport.gradientImage(width: 64, height: 48)
        let second = TestSupport.gradientImage(width: 30, height: 90)
        XCTAssertEqual(MultiExposure.blend(first, second).extent, first.extent)
        XCTAssertEqual(MultiExposure.blend(second, first).extent, second.extent)
    }

    func testBlendOfTwoWhitesSoftClipsToWhite() {
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let out = MultiExposure.blend(solid(1, rect), solid(1, rect))
        let s = stats(TestSupport.renderFloat(out))
        XCTAssertEqual(s.nonFinite, 0)
        XCTAssertEqual(s.max, 1, accuracy: 0.02, "1.2 × white must land on white, not above")
        XCTAssertEqual(s.min, 1, accuracy: 0.02)
    }

    func testBlendOfTwoBlacksIsBlack() {
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let s = stats(TestSupport.renderFloat(MultiExposure.blend(solid(0, rect), solid(0, rect))))
        XCTAssertEqual(s.nonFinite, 0)
        XCTAssertEqual(s.max, 0, accuracy: 0.005)
    }

    func testBlendStaysInRangeAndKeepsAlpha() {
        let a = TestSupport.gradientImage(width: 64, height: 64)
        let b = TestSupport.gradientImage(width: 64, height: 64)
            .transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -64, y: 0))
        let px = TestSupport.renderFloat(MultiExposure.blend(a, b))
        let s = stats(px)
        XCTAssertEqual(s.nonFinite, 0)
        XCTAssertGreaterThanOrEqual(s.min, -0.001)
        XCTAssertLessThanOrEqual(s.max, 1.001)
        for i in stride(from: 3, to: px.count, by: 4) where abs(px[i] - 1) > 0.001 {
            return XCTFail("alpha \(px[i]) at \(i / 4); a double exposure must stay opaque")
        }
    }

    func testBlendWithEmptyOrInfiniteFirstReturnsFirst() {
        let infinite = CIImage(color: .white)
        XCTAssertTrue(MultiExposure.blend(infinite, TestSupport.gradientImage(width: 8, height: 8)) === infinite)
    }

    // MARK: ViewfinderEffects

    func testGainZeroIsIdentity() {
        let image = TestSupport.gradientImage(width: 8, height: 8)
        XCTAssertTrue(ViewfinderEffects.gain(image, ev: 0) === image)
    }

    func testGainOneStopDoublesLinearValues() {
        let rect = CGRect(x: 0, y: 0, width: 4, height: 4)
        let base = stats(TestSupport.renderFloat(solid(0.5, rect)))
        let brighter = stats(TestSupport.renderFloat(ViewfinderEffects.gain(solid(0.5, rect), ev: 1)))
        XCTAssertEqual(brighter.max, base.max * 2, accuracy: 0.01)
    }

    func testZebrasAndPeakingKeepExtentAndStayFinite() {
        let image = TestSupport.gradientImage(width: 96, height: 128)
        for out in [ViewfinderEffects.zebras(image), ViewfinderEffects.zebras(image, threshold: 0.5, phase: 7),
                    ViewfinderEffects.peaking(image)] {
            XCTAssertEqual(out.extent, image.extent)
            XCTAssertEqual(stats(TestSupport.renderFloat(out)).nonFinite, 0)
        }
    }

    func testZebrasLeaveDarkImageUntouched() {
        let rect = CGRect(x: 0, y: 0, width: 32, height: 32)
        let dark = solid(0.2, rect)
        let before = TestSupport.renderFloat(dark)
        let after = TestSupport.renderFloat(ViewfinderEffects.zebras(dark))
        XCTAssertEqual(before.count, after.count)
        let maxDiff = zip(before, after).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(maxDiff, 0.002)
    }

    func testEffectsPassThroughInfiniteImages() {
        let infinite = CIImage(color: .white)
        XCTAssertTrue(ViewfinderEffects.zebras(infinite) === infinite)
        XCTAssertTrue(ViewfinderEffects.peaking(infinite) === infinite)
    }
}
