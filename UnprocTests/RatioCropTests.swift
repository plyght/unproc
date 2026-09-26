import CoreImage
import XCTest
@testable import Unproc

final class RatioCropTests: XCTestCase {
    private func solid(_ rect: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: rect)
    }

    private let portraitSizes: [CGSize] = [
        CGSize(width: 3024, height: 4032),
        CGSize(width: 1080, height: 1440),
        CGSize(width: 2999, height: 4001),
        CGSize(width: 1512, height: 2016),
    ]

    func testFourThreeReturnsTheSameImage() {
        let image = solid(CGRect(x: 0, y: 0, width: 3024, height: 4032))
        let out = RatioCrop.crop(image, to: .fourThree)
        XCTAssertTrue(out === image)
        XCTAssertEqual(out.extent, image.extent)
    }

    func testPortraitCropsMatchPortraitAspect() {
        for size in portraitSizes {
            let image = solid(CGRect(origin: .zero, size: size))
            for ratio in FrameRatio.allCases where ratio != .fourThree {
                let out = RatioCrop.crop(image, to: ratio).extent
                let target = CGFloat(ratio.portraitAspect)
                XCTAssertEqual(out.origin, .zero, "\(ratio) \(size)")
                XCTAssertLessThanOrEqual(out.height, size.height)
                XCTAssertLessThanOrEqual(out.width, size.width)
                XCTAssertLessThanOrEqual(out.width, out.height, "portrait stays portrait (\(ratio))")
                XCTAssertEqual(out.width, out.height * target, accuracy: 1, "\(ratio) on \(size) -> \(out.size)")
                // Only one side is cut.
                XCTAssertTrue(out.width == size.width || out.height == size.height, "\(ratio) \(size) -> \(out.size)")
            }
        }
    }

    func testLandscapeCropsMatchLongOverShort() {
        for p in portraitSizes {
            let size = CGSize(width: p.height, height: p.width)
            let image = solid(CGRect(origin: .zero, size: size))
            for ratio in FrameRatio.allCases where ratio != .fourThree {
                let out = RatioCrop.crop(image, to: ratio).extent
                let target = CGFloat(ratio.longOverShort)
                XCTAssertEqual(out.origin, .zero)
                XCTAssertGreaterThanOrEqual(out.width, out.height, "landscape stays landscape (\(ratio))")
                XCTAssertEqual(out.width, out.height * target, accuracy: 1, "\(ratio) on \(size) -> \(out.size)")
            }
        }
    }

    func testExpectedPixelSizes() {
        let portrait = solid(CGRect(x: 0, y: 0, width: 3024, height: 4032))
        XCTAssertEqual(RatioCrop.crop(portrait, to: .square).extent.size, CGSize(width: 3024, height: 3024))
        XCTAssertEqual(RatioCrop.crop(portrait, to: .sixteenNine).extent.size, CGSize(width: 2268, height: 4032))
        XCTAssertEqual(RatioCrop.crop(portrait, to: .threeTwo).extent.size, CGSize(width: 2688, height: 4032))

        let landscape = solid(CGRect(x: 0, y: 0, width: 4032, height: 3024))
        XCTAssertEqual(RatioCrop.crop(landscape, to: .sixteenNine).extent.size, CGSize(width: 4032, height: 2268))
        XCTAssertEqual(RatioCrop.crop(landscape, to: .threeTwo).extent.size, CGSize(width: 4032, height: 2688))
    }

    func testNonZeroOriginIsNormalised() {
        let image = solid(CGRect(x: 120, y: -80, width: 1500, height: 2000))
        for ratio in FrameRatio.allCases where ratio != .fourThree {
            let out = RatioCrop.crop(image, to: ratio).extent
            XCTAssertEqual(out.origin, .zero, "\(ratio)")
            XCTAssertEqual(out.width, out.height * CGFloat(ratio.portraitAspect), accuracy: 1)
        }
    }

    func testCropIsCentred() {
        // Landscape 200×100, red left half / blue right half. A square crop
        // must take 50 px from each side, leaving the seam in the middle.
        let left = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let right = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 100, y: 0, width: 100, height: 100))
        let image = right.composited(over: left)
        let out = RatioCrop.crop(image, to: .square)
        XCTAssertEqual(out.extent, CGRect(x: 0, y: 0, width: 100, height: 100))
        let px = TestSupport.renderFloat(out, colorSpace: TestSupport.sRGB)
        let w = Int(out.extent.width)
        let row = 50
        func red(_ x: Int) -> Float { px[(row * w + x) * 4] }
        func blue(_ x: Int) -> Float { px[(row * w + x) * 4 + 2] }
        XCTAssertGreaterThan(red(1), 0.9, "left edge should be red")
        XCTAssertGreaterThan(red(48), 0.9, "just left of centre should be red")
        XCTAssertGreaterThan(blue(51), 0.9, "just right of centre should be blue")
        XCTAssertGreaterThan(blue(w - 2), 0.9, "right edge should be blue")
    }

    func testInfiniteOrEmptyImagesPassThrough() {
        let infinite = CIImage(color: .white)
        XCTAssertTrue(RatioCrop.crop(infinite, to: .square) === infinite)
        let empty = CIImage.empty()
        XCTAssertTrue(RatioCrop.crop(empty, to: .square) === empty)
    }

    func testFrameRatioValues() {
        XCTAssertEqual(FrameRatio.fourThree.rawValue, "4:3")
        XCTAssertEqual(FrameRatio.threeTwo.rawValue, "3:2")
        XCTAssertEqual(FrameRatio.sixteenNine.rawValue, "16:9")
        XCTAssertEqual(FrameRatio.square.rawValue, "1:1")
        XCTAssertEqual(FrameRatio.allCases.count, 4)
        XCTAssertEqual(FrameRatio.allCases.first, .fourThree, "4:3 is the default / first")
        XCTAssertEqual(FrameRatio.fourThree.longOverShort, 4.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(FrameRatio.threeTwo.longOverShort, 1.5, accuracy: 1e-12)
        XCTAssertEqual(FrameRatio.sixteenNine.longOverShort, 16.0 / 9.0, accuracy: 1e-12)
        XCTAssertEqual(FrameRatio.square.longOverShort, 1, accuracy: 1e-12)
        for r in FrameRatio.allCases {
            XCTAssertGreaterThanOrEqual(r.longOverShort, 1)
            XCTAssertEqual(r.portraitAspect * r.longOverShort, 1, accuracy: 1e-12)
            XCTAssertEqual(FrameRatio(rawValue: r.rawValue), r)
        }
    }
}
