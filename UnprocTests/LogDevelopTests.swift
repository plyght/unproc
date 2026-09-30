import CoreImage
import CoreVideo
import XCTest
@testable import Unproc

/// Apple Log decode + the neutral video develop curve.
final class LogDevelopTests: XCTestCase {
    func testDecodeInvertsEncode() {
        var r = -0.05
        while r <= 12 {
            let back = LogDevelop.decode(LogDevelop.encode(r))
            XCTAssertEqual(back, r, accuracy: max(1e-9, abs(r) * 1e-9), "r=\(r)")
            r += r < 0.1 ? 0.001 : 0.01
        }
    }

    func testProfileKnownValues() {
        // Continuity at the switch point and the documented range.
        XCTAssertEqual(LogDevelop.encode(LogDevelop.rt), LogDevelop.pt, accuracy: 1e-6)
        XCTAssertEqual(LogDevelop.gamma * log2(LogDevelop.rt + LogDevelop.beta) + LogDevelop.delta,
                       LogDevelop.pt, accuracy: 1e-4)
        XCTAssertEqual(LogDevelop.encode(LogDevelop.r0), 0, accuracy: 1e-12)
        XCTAssertEqual(LogDevelop.decode(0), LogDevelop.r0, accuracy: 1e-12)
        XCTAssertEqual(LogDevelop.decode(-0.1), LogDevelop.r0)
        XCTAssertEqual(LogDevelop.encode(0.18), 0.4883, accuracy: 0.001)
        XCTAssertEqual(LogDevelop.decode(1), 12, accuracy: 0.01)
    }

    func testZeroMapsToZero() {
        XCTAssertEqual(LogDevelop.tone(0), 0, accuracy: 1e-9)
        XCTAssertEqual(LogDevelop.tone(-0.05), 0, accuracy: 1e-9)
    }

    func testGreyTarget() {
        XCTAssertEqual(LogDevelop.tone(0.18), LogDevelop.greyTarget, accuracy: 0.01)
        // Neutral grey stays neutral through the primaries matrix.
        let grey = LogDevelop.develop(SIMD3(repeating: LogDevelop.encode(0.18)))
        XCTAssertEqual(grey.x, grey.y, accuracy: 0.002)
        XCTAssertEqual(grey.y, grey.z, accuracy: 0.002)
        XCTAssertEqual(grey.y, LogDevelop.greyTarget, accuracy: 0.01)
    }

    func testMonotonicWithoutShadowLift() {
        var previous = -1.0
        var x = 0.0
        while x <= 12 {
            let v = LogDevelop.tone(x)
            XCTAssertGreaterThanOrEqual(v, previous, "x=\(x)")
            XCTAssertLessThanOrEqual(v, 1)
            previous = v
            x += 0.0005 + x * 0.01
        }
        // Deep shadows stay dark (no lift): 4+ stops under grey is < 0.1.
        XCTAssertLessThan(LogDevelop.tone(0.01), 0.1)
    }

    func testHighlightsCompressSmoothly() {
        // One stop over grey is well below white, +3 stops still not clipped.
        let plus1 = LogDevelop.tone(0.36), plus2 = LogDevelop.tone(0.72), plus3 = LogDevelop.tone(1.44)
        XCTAssertLessThan(plus1, 0.7)
        XCTAssertLessThan(plus3, 0.95)
        // Shoulder: each stop adds less than the one before.
        XCTAssertGreaterThan(plus1 - LogDevelop.tone(0.18), plus2 - plus1)
        XCTAssertGreaterThan(plus2 - plus1, plus3 - plus2)
        // White is reached smoothly near `whiteScene`, not before +4 stops.
        XCTAssertLessThan(LogDevelop.tone(2.88), 0.99)
        XCTAssertEqual(LogDevelop.tone(LogDevelop.whiteScene), 1, accuracy: 1e-6)
        XCTAssertEqual(LogDevelop.tone(12), 1, accuracy: 1e-6)
    }

    func testCubeShape() {
        let n = 17
        let data = LogDevelop.cube(dimension: n)
        XCTAssertEqual(data.count, n * n * n * 4 * MemoryLayout<Float>.size)
        let values: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        func entry(_ r: Int, _ g: Int, _ b: Int) -> SIMD4<Float> {
            let i = ((b * n + g) * n + r) * 4
            return SIMD4(values[i], values[i + 1], values[i + 2], values[i + 3])
        }
        XCTAssertEqual(entry(0, 0, 0).x, 0, accuracy: 1e-6)
        XCTAssertEqual(entry(n - 1, n - 1, n - 1).y, 1, accuracy: 1e-6)
        // Along the neutral axis: monotonic and neutral.
        var previous: Float = -1
        for i in 0..<n {
            let e = entry(i, i, i)
            XCTAssertGreaterThanOrEqual(e.y, previous)
            XCTAssertEqual(e.x, e.y, accuracy: 0.003)
            XCTAssertEqual(e.z, e.y, accuracy: 0.003)
            XCTAssertEqual(e.w, 1)
            previous = e.y
        }
    }

    func testRuntimeCubeGreyTarget() {
        let n = LogDevelop.dimension
        let data = LogDevelopFilter.cubeData
        XCTAssertEqual(data.count, n * n * n * 4 * MemoryLayout<Float>.size)
        // Interpolate the neutral axis at the 18 % grey code value.
        let values: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let pos = LogDevelop.encode(0.18) * Double(n - 1)
        let lo = Int(pos), t = Float(pos - Double(lo))
        func g(_ i: Int) -> Float { values[((i * n + i) * n + i) * 4 + 1] }
        let grey = g(lo) + (g(lo + 1) - g(lo)) * t
        XCTAssertEqual(Double(grey), LogDevelop.greyTarget, accuracy: 0.015)
    }

    /// End to end through Core Image: a flat Log grey buffer renders to about
    /// the grey target in Rec.709 (checks the colour-management assumptions).
    func testFilterRendersGrey() throws {
        var created: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 8, 8, kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary, &created)
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(created)
        let code = UInt8((LogDevelop.encode(0.18) * 255).rounded())
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<8 {
            for x in 0..<8 {
                let p = base + y * rowBytes + x * 4
                p[0] = code; p[1] = code; p[2] = code; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let image = LogDevelopFilter.developed(buffer)
        var pixel = [Float](repeating: 0, count: 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.itur_709))
        pixel.withUnsafeMutableBytes { raw in
            Developer.shared.context.render(image, toBitmap: raw.baseAddress!, rowBytes: 16,
                                            bounds: CGRect(x: 4, y: 4, width: 1, height: 1),
                                            format: .RGBAf, colorSpace: space)
        }
        XCTAssertEqual(Double(pixel[1]), LogDevelop.greyTarget, accuracy: 0.03, "rendered \(pixel)")
        XCTAssertEqual(pixel[0], pixel[1], accuracy: 0.01)
        XCTAssertEqual(pixel[2], pixel[1], accuracy: 0.01)
    }
}
