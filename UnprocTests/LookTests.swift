import CoreImage
import XCTest
@testable import Unproc

final class LookTests: XCTestCase {
    private var gradedLooks: [Look] { LookLibrary.all.filter { $0.id != Look.zero.id } }

    // MARK: Catalogue

    func testZeroIsFirstAndDefault() {
        XCTAssertEqual(LookLibrary.all.first, Look.zero)
        XCTAssertEqual(Look.zero.id, "zero")
        XCTAssertEqual(CaptureSettings().lookID, Look.zero.id, "default setting points at the neutral look")
    }

    func testIdsAndCodesAreUnique() {
        let ids = LookLibrary.all.map(\.id)
        let codes = LookLibrary.all.map(\.code)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(Set(codes).count, codes.count)
        for look in LookLibrary.all {
            XCTAssertFalse(look.name.isEmpty)
            XCTAssertFalse(look.code.isEmpty)
        }
    }

    func testLookLookupFallsBackToZero() {
        for look in LookLibrary.all {
            XCTAssertEqual(LookLibrary.look(id: look.id), look)
        }
        XCTAssertEqual(LookLibrary.look(id: "no-such-look"), .zero)
        XCTAssertEqual(LookLibrary.look(id: ""), .zero)
    }

    func testEveryGradedLookHasARecipe() {
        for look in gradedLooks {
            XCTAssertNotNil(LookRecipes.transform(for: look.id), "missing recipe for \(look.id)")
        }
        XCTAssertNil(LookRecipes.transform(for: Look.zero.id))
    }

    // MARK: Apply

    func testApplyZeroReturnsSameImage() {
        let image = TestSupport.gradientImage(width: 8, height: 8)
        XCTAssertTrue(LookLibrary.apply(.zero, to: image) === image)
        XCTAssertNil(LookLibrary.cubeData(for: .zero))
    }

    func testApplyUnknownLookReturnsSameImage() {
        let image = TestSupport.gradientImage(width: 8, height: 8)
        let bogus = Look(id: "bogus", code: "XX", name: "Bogus")
        XCTAssertTrue(LookLibrary.apply(bogus, to: image) === image)
        XCTAssertNil(LookLibrary.cubeData(for: bogus))
    }

    func testApplyKeepsExtent() {
        let image = TestSupport.gradientImage(width: 64, height: 48)
        for look in gradedLooks {
            let out = LookLibrary.apply(look, to: image)
            XCTAssertFalse(out === image, "\(look.id) did nothing")
            XCTAssertEqual(out.extent, image.extent, look.id)
        }
    }

    // MARK: Cubes

    func testCubeDataSizeAndRange() throws {
        let n = LookLibrary.dimension
        XCTAssertEqual(n, 33)
        for look in gradedLooks {
            let data = try XCTUnwrap(LookLibrary.cubeData(for: look), look.id)
            XCTAssertEqual(data.count, n * n * n * 4 * MemoryLayout<Float>.size, look.id)
            let floats = Self.floats(data)
            var outOfRange = 0
            var badAlpha = 0
            for i in stride(from: 0, to: floats.count, by: 4) {
                for c in floats[i..<(i + 3)] where !(c.isFinite && c >= 0 && c <= 1) { outOfRange += 1 }
                if floats[i + 3] != 1 { badAlpha += 1 }
            }
            XCTAssertEqual(outOfRange, 0, "\(look.id): \(outOfRange) components out of 0…1 or non-finite")
            XCTAssertEqual(badAlpha, 0, "\(look.id): \(badAlpha) entries with alpha != 1")
        }
    }

    private static func floats(_ data: Data) -> [Float] {
        var out = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = out.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return out
    }

    func testCubeIsCachedAndStable() {
        for look in gradedLooks {
            XCTAssertEqual(LookLibrary.cubeData(for: look), LookLibrary.cubeData(for: look))
        }
    }

    func testLUTBuilderIdentityLayout() {
        let n = 5
        let data = LUTBuilder.cube(dimension: n) { $0 }
        let f = Self.floats(data)
        XCTAssertEqual(f.count, n * n * n * 4)
        // Red varies fastest, then green, then blue.
        func entry(r: Int, g: Int, b: Int) -> SIMD4<Float> {
            let i = ((b * n + g) * n + r) * 4
            return SIMD4(f[i], f[i + 1], f[i + 2], f[i + 3])
        }
        XCTAssertEqual(entry(r: 0, g: 0, b: 0), SIMD4(0, 0, 0, 1))
        XCTAssertEqual(entry(r: 4, g: 0, b: 0), SIMD4(1, 0, 0, 1))
        XCTAssertEqual(entry(r: 0, g: 4, b: 0), SIMD4(0, 1, 0, 1))
        XCTAssertEqual(entry(r: 0, g: 0, b: 4), SIMD4(0, 0, 1, 1))
        XCTAssertEqual(entry(r: 2, g: 1, b: 3), SIMD4(0.5, 0.25, 0.75, 1))
    }

    func testLUTBuilderClampsOutput() {
        let data = LUTBuilder.cube(dimension: 3) { $0 * 4 - GradeRGB(repeating: 1) }
        let f = Self.floats(data)
        for v in f { XCTAssertTrue((0...1).contains(v)) }
    }

    // MARK: Recipes

    func testMidGreyStaysSaneThroughEveryLook() throws {
        for look in gradedLooks {
            let transform = try XCTUnwrap(LookRecipes.transform(for: look.id))
            let out = transform(GradeRGB(repeating: 0.5))
            for c in [out.x, out.y, out.z] {
                XCTAssertTrue(c.isFinite, look.id)
                XCTAssertGreaterThan(c, 0.35, "\(look.id) moved mid-grey too far: \(out)")
                XCTAssertLessThan(c, 0.7, "\(look.id) moved mid-grey too far: \(out)")
            }
            let spread = max(out.x, out.y, out.z) - min(out.x, out.y, out.z)
            XCTAssertLessThan(spread, 0.12, "\(look.id) tints grey too strongly: \(out)")
        }
    }

    func testGreyRampIsMonotonicThroughEveryLook() throws {
        for look in gradedLooks {
            let transform = try XCTUnwrap(LookRecipes.transform(for: look.id))
            var previous: Float = -1
            for step in 0...64 {
                let v = Float(step) / 64
                let y = GradeKit.luma(GradeKit.clamp01(transform(GradeRGB(repeating: v))))
                XCTAssertTrue(y.isFinite)
                XCTAssertGreaterThanOrEqual(y, previous - 1e-4, "\(look.id) reverses tone at \(v)")
                previous = y
            }
        }
    }

    func testRecipesStayFiniteOnExtremeInputs() throws {
        let probes: [GradeRGB] = [
            GradeRGB(0, 0, 0), GradeRGB(1, 1, 1), GradeRGB(1, 0, 0), GradeRGB(0, 1, 0), GradeRGB(0, 0, 1),
            GradeRGB(1, 1, 0), GradeRGB(0, 1, 1), GradeRGB(1, 0, 1), GradeRGB(0.001, 0, 0), GradeRGB(0.95, 0.9, 0.2),
        ]
        for look in gradedLooks {
            let transform = try XCTUnwrap(LookRecipes.transform(for: look.id))
            for p in probes {
                let o = transform(p)
                XCTAssertTrue(o.x.isFinite && o.y.isFinite && o.z.isFinite, "\(look.id) on \(p) -> \(o)")
            }
        }
    }

    func testMonoLooksAreNeutral() throws {
        for id in ["s1-06", "s1-07"] {
            let transform = try XCTUnwrap(LookRecipes.transform(for: id))
            for p in [GradeRGB(1, 0, 0), GradeRGB(0.2, 0.6, 0.9), GradeRGB(0.5, 0.5, 0.5)] {
                let o = transform(p)
                XCTAssertEqual(o.x, o.y)
                XCTAssertEqual(o.y, o.z)
            }
        }
    }

    // MARK: Rendering

    func testRenderGradientThroughEveryLookHasNoNaN() {
        let image = TestSupport.gradientImage(width: 64, height: 64)
        for look in LookLibrary.all {
            let graded = LookLibrary.apply(look, to: image)
            let px = TestSupport.renderFloat(graded)
            XCTAssertEqual(px.count, 64 * 64 * 4)
            var bad = 0
            var maxValue: Float = 0
            for v in px {
                if !v.isFinite { bad += 1 } else { maxValue = max(maxValue, v) }
            }
            XCTAssertEqual(bad, 0, "\(look.id) produced \(bad) non-finite components")
            XCTAssertLessThan(maxValue, 1.5, "\(look.id) blew out: \(maxValue)")
        }
    }

    func testDeveloperThumbnailRendersEveryLook() throws {
        let image = TestSupport.gradientImage(width: 120, height: 160)
        for look in LookLibrary.all {
            let cg = try XCTUnwrap(Developer.shared.thumbnail(image, look: look, maxSide: 40), look.id)
            XCTAssertEqual(max(cg.width, cg.height), 40, look.id)
        }
        XCTAssertNil(Developer.shared.thumbnail(image, look: .zero, maxSide: 0))
        XCTAssertNil(Developer.shared.thumbnail(CIImage(color: .white), look: .zero, maxSide: 40))
    }
}
