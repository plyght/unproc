import CoreGraphics
import XCTest
@testable import Unproc

@MainActor
final class ZoomScrubModelTests: XCTestCase {
    private let stopSets: [[CGFloat]] = [
        [0.5, 1, 2, 4, 8],
        [1, 2],
        [0.5, 1, 2, 5, 10],
        [0.5, 1, 1.2, 2, 3],
        [1],
    ]

    private func model(_ stops: [CGFloat], zoom: CGFloat = 1, front: Bool = false) -> ZoomScrubModel {
        let m = ZoomScrubModel()
        m.present(stops: stops, zoom: zoom, isFront: front)
        return m
    }

    // MARK: Mapping

    func testZoomIsMonotonicAndBoundedAcrossTrack() {
        for stops in stopSets {
            let m = model(stops)
            var previous: CGFloat = -.infinity
            var s: CGFloat = -20
            while s <= m.length + 20 {
                let z = m.zoom(at: s)
                XCTAssertTrue(z.isFinite, "zoom(at: \(s)) not finite for \(stops)")
                XCTAssertGreaterThanOrEqual(z, previous - 1e-9, "zoom decreased at s=\(s) for \(stops)")
                XCTAssertGreaterThanOrEqual(z, stops.first! - 1e-9)
                XCTAssertLessThanOrEqual(z, stops.last! + 1e-9)
                previous = z
                s += 0.25
            }
            XCTAssertEqual(m.zoom(at: 0), stops.first!)
            XCTAssertEqual(m.zoom(at: m.length), stops.last!)
        }
    }

    func testLengthIsPositiveAndSingleStopIsOneDetent() {
        XCTAssertEqual(model([1]).length, ZoomScrubModel.detent)
        for stops in stopSets where stops.count > 1 {
            XCTAssertGreaterThan(model(stops).length, ZoomScrubModel.detent * CGFloat(stops.count))
        }
    }

    func testEachStopDetentReturnsExactlyTheStop() {
        for stops in stopSets {
            let m = model(stops)
            for (i, stop) in stops.enumerated() {
                let centre = m.position(ofStop: i)
                XCTAssertEqual(m.zoom(at: centre), stop, "centre of stop \(i) in \(stops)")
                let half = ZoomScrubModel.detent / 2 - 0.5
                XCTAssertEqual(m.zoom(at: centre - half), stop, "low edge of stop \(i) in \(stops)")
                XCTAssertEqual(m.zoom(at: centre + half), stop, "high edge of stop \(i) in \(stops)")
                XCTAssertEqual(m.position(forZoom: stop), centre, accuracy: 1e-9)
            }
        }
    }

    func testStopPositionsAscendAndStayOnTrack() {
        for stops in stopSets {
            let m = model(stops)
            var previous: CGFloat = -1
            for i in stops.indices {
                let p = m.position(ofStop: i)
                XCTAssertGreaterThan(p, previous)
                XCTAssertGreaterThanOrEqual(p, 0)
                XCTAssertLessThanOrEqual(p, m.length)
                previous = p
            }
        }
    }

    func testZoomToPositionRoundTripsOnRamps() {
        let m = model([0.5, 1, 2, 4, 8])
        for z: CGFloat in [0.6, 0.7, 0.8, 0.9, 1.3, 1.5, 1.7, 2.4, 3, 3.5, 5, 6, 7.5] {
            let s = m.position(forZoom: z)
            XCTAssertEqual(m.zoom(at: s), z, accuracy: z * 1e-6, "zoom \(z) did not round-trip")
        }
    }

    func testPositionToZoomRoundTripsOnRamps() {
        let m = model([0.5, 1, 2, 4, 8])
        var s: CGFloat = 0
        while s <= m.length {
            let z = m.zoom(at: s)
            // Skip detents (and anything within the 1 % snap of a stop).
            let nearStop = m.stops.contains { abs($0 - z) / $0 < 0.011 }
            if !nearStop {
                XCTAssertEqual(m.position(forZoom: z), s, accuracy: 1e-6, "position \(s) did not round-trip")
            }
            s += 1.3
        }
    }

    func testPositionForOutOfRangeZoomClampsToEnds() {
        let m = model([0.5, 1, 2, 4, 8])
        XCTAssertEqual(m.position(forZoom: 0.2), ZoomScrubModel.detent / 2, accuracy: 1e-9)
        XCTAssertEqual(m.position(forZoom: 30), m.length - ZoomScrubModel.detent / 2, accuracy: 1e-9)
    }

    func testEmptyStopsFallBackToOne() {
        let m = ZoomScrubModel()
        m.present(stops: [], zoom: 1, isFront: false)
        XCTAssertEqual(m.stops, [1])
        XCTAssertEqual(m.zoom(at: 0), 1)
        XCTAssertEqual(m.zoom(at: 1000), 1)
    }

    // MARK: Gesture

    func testUpdateBeforeBeginDoesNothing() {
        let m = model([0.5, 1, 2])
        XCTAssertNil(m.update(dy: -50))
        XCTAssertFalse(m.isActive)
    }

    func testBeginPlacesThumbAtCurrentZoom() {
        let m = ZoomScrubModel()
        m.begin(stops: [0.5, 1, 2, 4, 8], zoom: 1, isFront: false)
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(m.position, m.position(ofStop: 1), accuracy: 1e-9)
        XCTAssertEqual(m.zoom, 1)
        XCTAssertNil(m.update(dy: 0), "no movement, no action")
    }

    func testDraggingUpClampsAtLongestStop() {
        let stops: [CGFloat] = [0.5, 1, 2, 4, 8]
        let m = ZoomScrubModel()
        m.begin(stops: stops, zoom: 1, isFront: false)
        var dy: CGFloat = 0
        while dy >= -2000 {
            let action = m.update(dy: dy)
            switch action {
            case .some(.zoom(let z)):
                XCTAssertLessThanOrEqual(z, stops.last!)
                XCTAssertGreaterThanOrEqual(z, stops.first!)
            case .some(.flip):
                XCTFail("pulling up from the back camera must never flip")
            case .none:
                break
            }
            XCTAssertLessThanOrEqual(m.zoom, stops.last!)
            XCTAssertLessThanOrEqual(m.position, m.length + 1e-9)
            dy -= 7
        }
        XCTAssertEqual(m.zoom, stops.last!)
        XCTAssertEqual(m.position, m.length, accuracy: 1e-9)
        XCTAssertGreaterThan(m.stretch, 0)
        XCTAssertLessThan(m.stretch, ZoomScrubModel.stretchLimit)
        XCTAssertEqual(m.flipProgress, 0)
        XCTAssertNil(m.end(), "sitting on the last stop needs no snap")
        XCTAssertFalse(m.isActive)
        XCTAssertEqual(m.stretch, 0)
    }

    func testLargeSingleJumpUpReportsMaxZoom() {
        let m = ZoomScrubModel()
        m.begin(stops: [0.5, 1, 2, 4, 8], zoom: 1, isFront: false)
        XCTAssertEqual(m.update(dy: -10_000), .zoom(8))
    }

    func testDraggingDownPastBottomFlipsToFrontExactlyOnce() {
        let m = ZoomScrubModel()
        m.begin(stops: [0.5, 1, 2, 4, 8], zoom: 1, isFront: false)
        let start = m.position
        var flips: [ZoomScrubModel.Action] = []
        var dy: CGFloat = 0
        while dy <= start + ZoomScrubModel.flipDistance * 3 {
            if let action = m.update(dy: dy), case .flip = action { flips.append(action) }
            if dy > start {
                XCTAssertEqual(m.zoom, 0.5, "below the bottom the zoom holds at the widest stop")
                XCTAssertLessThanOrEqual(m.stretch, 0)
                XCTAssertGreaterThan(m.stretch, -ZoomScrubModel.stretchLimit)
            }
            dy += 3
        }
        XCTAssertEqual(flips, [.flip(.front)])
        XCTAssertEqual(m.flipProgress, 1)
        XCTAssertNil(m.end(), "no snap after a flip")
    }

    func testDraggingDownJustShortOfFlipDistanceDoesNotFlip() {
        let m = ZoomScrubModel()
        m.begin(stops: [0.5, 1, 2], zoom: 1, isFront: false)
        let start = m.position
        let action = m.update(dy: start + ZoomScrubModel.flipDistance - 1)
        XCTAssertEqual(action, .zoom(0.5))
        XCTAssertLessThan(m.flipProgress, 1)
        XCTAssertGreaterThan(m.flipProgress, 0.9)
    }

    func testFlipOnlyAfterReleaseAndRegrab() {
        let m = ZoomScrubModel()
        m.begin(stops: [0.5, 1, 2], zoom: 1, isFront: false)
        let start = m.position
        XCTAssertEqual(m.update(dy: start + ZoomScrubModel.flipDistance + 5), .flip(.front))
        XCTAssertNotEqual(m.update(dy: start + ZoomScrubModel.flipDistance + 50), .flip(.front))
        _ = m.end()
        // A fresh drag can flip again.
        m.begin(stops: [0.5, 1, 2], zoom: 1, isFront: false)
        XCTAssertEqual(m.update(dy: start + ZoomScrubModel.flipDistance + 5), .flip(.front))
    }

    func testFromFrontPullingUpFlipsBackOnce() {
        let m = ZoomScrubModel()
        m.begin(stops: [0.5, 1, 2, 4, 8], zoom: 1, isFront: true)
        XCTAssertEqual(m.position, 0)
        var flips: [ZoomScrubModel.Action] = []
        var dy: CGFloat = 0
        while dy >= -ZoomScrubModel.flipDistance * 3 {
            if let action = m.update(dy: dy) {
                XCTAssertEqual(action, .flip(.back), "from the front camera only a flip back is reported")
                flips.append(action)
            }
            XCTAssertEqual(m.position, 0)
            XCTAssertGreaterThanOrEqual(m.stretch, 0)
            dy -= 4
        }
        XCTAssertEqual(flips, [.flip(.back)])
        XCTAssertNil(m.end())
    }

    func testFromFrontPullingDownDoesNothing() {
        let m = ZoomScrubModel()
        m.begin(stops: [0.5, 1, 2], zoom: 1, isFront: true)
        for dy in stride(from: CGFloat(0), through: 400, by: 10) {
            XCTAssertNil(m.update(dy: dy))
        }
        XCTAssertEqual(m.flipProgress, 0)
        XCTAssertNil(m.end())
    }

    func testEndSnapsNearStopZoomToTheStop() {
        let m = ZoomScrubModel()
        m.begin(stops: [0.5, 1, 2, 4, 8], zoom: 1, isFront: false)
        let start = m.position
        let target = m.position(forZoom: 2.1)
        let action = m.update(dy: start - target)
        guard case .some(.zoom(let z)) = action else { return XCTFail("expected a zoom action, got \(String(describing: action))") }
        XCTAssertEqual(z, 2.1, accuracy: 1e-6)
        XCTAssertEqual(m.end(), .zoom(2))
        XCTAssertEqual(m.zoom, 2)
        XCTAssertEqual(m.position, m.position(ofStop: 2), accuracy: 1e-9)
        XCTAssertFalse(m.isActive)
    }

    func testEndLeavesFarFromStopZoomAlone() {
        let m = ZoomScrubModel()
        m.begin(stops: [0.5, 1, 2, 4, 8], zoom: 1, isFront: false)
        let start = m.position
        _ = m.update(dy: start - m.position(forZoom: 2.8))
        XCTAssertNil(m.end())
        XCTAssertEqual(m.zoom, 2.8, accuracy: 1e-6)
    }

    func testCrossingIntoADetentTicks() {
        let m = ZoomScrubModel()
        m.begin(stops: [0.5, 1, 2, 4, 8], zoom: 1, isFront: false)
        let start = m.position
        let before = m.detentTick
        let target = m.position(ofStop: 2)
        var s = start
        while s <= target {
            _ = m.update(dy: start - s)
            s += 1
        }
        XCTAssertGreaterThan(m.detentTick, before)
        XCTAssertEqual(m.zoom, 2, accuracy: 0.02)
    }

    func testPresentDoesNotActivate() {
        let m = ZoomScrubModel()
        m.present(stops: [0.5, 1, 2], zoom: 2, isFront: false)
        XCTAssertFalse(m.isActive)
        XCTAssertEqual(m.position, m.position(ofStop: 2), accuracy: 1e-9)
        XCTAssertNil(m.update(dy: -40))
    }

    // MARK: Labels

    func testZoomDialLabels() {
        XCTAssertEqual(ZoomDial.label(0.5), ".5\u{00D7}")
        XCTAssertEqual(ZoomDial.label(0.7), ".7\u{00D7}")
        XCTAssertEqual(ZoomDial.label(1), "1\u{00D7}")
        XCTAssertEqual(ZoomDial.label(2), "2\u{00D7}")
        XCTAssertEqual(ZoomDial.label(2.4), "2.4\u{00D7}")
        XCTAssertEqual(ZoomDial.label(4), "4\u{00D7}")
        XCTAssertEqual(ZoomDial.label(8), "8\u{00D7}")
        XCTAssertEqual(ZoomDial.label(10), "10\u{00D7}")
        XCTAssertEqual(ZoomDial.label(1.02), "1\u{00D7}", "near-integers read as the integer")
    }
}
