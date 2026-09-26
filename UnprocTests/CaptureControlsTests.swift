import CoreGraphics
import XCTest
@testable import Unproc

/// `AVCaptureSlider(values:)` raises on unsorted or duplicate values, and a
/// stop missing from the list makes the Camera Control unable to land on a lens.
final class CaptureControlsTests: XCTestCase {
    private let stopSets: [[Float]] = [
        [0.5, 1, 2, 4, 8],
        [1, 2],
        [0.5, 1, 2, 5, 10],
        [1],
        [0.5, 1, 2, 3, 4, 8],
        [0.5, 1, 1.2, 1.5, 2, 4, 8],
        [0.5, 0.6, 1, 25],
    ]

    private func assertValidValues(for stops: [Float], file: StaticString = #filePath, line: UInt = #line) {
        let values = CaptureControlsInstaller.zoomValues(stops: stops)
        let sorted = stops.sorted()
        XCTAssertFalse(values.isEmpty, "no values for \(stops)", file: file, line: line)
        XCTAssertEqual(values.first, sorted.first, "first value must be the widest stop for \(stops)", file: file, line: line)
        XCTAssertEqual(values.last, sorted.last, "last value must be the longest stop for \(stops)", file: file, line: line)
        for i in values.indices.dropFirst() {
            XCTAssertGreaterThan(values[i], values[i - 1],
                                 "not strictly increasing at \(i) for \(stops): \(values)", file: file, line: line)
        }
        XCTAssertEqual(Set(values).count, values.count, "duplicates in \(values)", file: file, line: line)
        for stop in sorted {
            // Bitwise: the exact Float the camera reports must be selectable.
            XCTAssertEqual(values.filter { $0.bitPattern == stop.bitPattern }.count, 1,
                           "stop \(stop) must appear exactly once in \(values)", file: file, line: line)
        }
        for v in values {
            XCTAssertTrue(v.isFinite && v > 0, "bad value \(v)", file: file, line: line)
        }
    }

    func testZoomValuesAreStrictlyIncreasingAndContainEveryStop() {
        for stops in stopSets {
            assertValidValues(for: stops)
        }
    }

    func testZoomValuesForTypicalProLineup() {
        let values = CaptureControlsInstaller.zoomValues(stops: [0.5, 1, 2, 4, 8])
        // 5 intermediate steps per gap at most, plus the stops.
        XCTAssertLessThanOrEqual(values.count, 4 * 5 + 5)
        XCTAssertGreaterThan(values.count, 5, "there should be intermediate values between stops")
        // Below 1× values sit on a 0.05 grid, above on a 0.1 grid.
        for v in values where !([0.5, 1, 2, 4, 8] as [Float]).contains(v) {
            let grid: Float = v < 1 ? 20 : 10
            XCTAssertEqual((v * grid).rounded(), v * grid, accuracy: 1e-3, "\(v) is off its grid")
        }
    }

    func testSingleStopReturnsJustThatStop() {
        XCTAssertEqual(CaptureControlsInstaller.zoomValues(stops: [1]), [1])
        XCTAssertEqual(CaptureControlsInstaller.zoomValues(stops: []), [])
    }

    func testUnsortedInputGivesSameResultAsSorted() {
        let sorted = CaptureControlsInstaller.zoomValues(stops: [0.5, 1, 2, 4, 8])
        XCTAssertEqual(CaptureControlsInstaller.zoomValues(stops: [8, 1, 4, 0.5, 2]), sorted)
        XCTAssertEqual(CaptureControlsInstaller.zoomValues(stops: [2, 1]), CaptureControlsInstaller.zoomValues(stops: [1, 2]))
        assertValidValues(for: [10, 0.5, 5, 2, 1])
    }

    func testStopsConvertedFromCGFloatSurviveExactly() {
        // The controller passes `zoomStops.map { Float($0) }`.
        let cg: [CGFloat] = [0.5, 1, 2, 4, 8]
        let stops = cg.map { Float($0) }
        let values = CaptureControlsInstaller.zoomValues(stops: stops)
        for s in stops { XCTAssertTrue(values.contains(s)) }
    }

    func testNearestReturnsAnElementOfTheArray() {
        let values = CaptureControlsInstaller.zoomValues(stops: [0.5, 1, 2, 4, 8])
        let probes: [Float] = [0, 0.01, 0.1, 0.49, 0.5, 0.52, 0.77, 1, 1.05, 1.9, 2.4, 3.3, 5, 7.99, 8, 9, 100, 10_000]
        for p in probes {
            let n = CaptureControlsInstaller.nearest(p, in: values)
            XCTAssertTrue(values.contains(n), "nearest(\(p)) = \(n) is not one of the slider values")
        }
        XCTAssertEqual(CaptureControlsInstaller.nearest(0.1, in: values), 0.5)
        XCTAssertEqual(CaptureControlsInstaller.nearest(100, in: values), 8)
        XCTAssertEqual(CaptureControlsInstaller.nearest(1, in: values), 1)
        XCTAssertEqual(CaptureControlsInstaller.nearest(2, in: values), 2)
        XCTAssertEqual(CaptureControlsInstaller.nearest(8, in: values), 8)
    }

    func testNearestIsLogarithmic() {
        // ln(1.4) = 0.336 < ln(2 / 1.4) = 0.357 → 1.
        XCTAssertEqual(CaptureControlsInstaller.nearest(1.4, in: [1, 2]), 1)
        // 1.45: ln(1.45)=0.372 > ln(2/1.45)=0.322 → 2 even though linearly nearer 1.
        XCTAssertEqual(CaptureControlsInstaller.nearest(1.45, in: [1, 2]), 2)
    }

    func testNearestInEmptyArrayReturnsInput() {
        XCTAssertEqual(CaptureControlsInstaller.nearest(3, in: []), 3)
    }
}
