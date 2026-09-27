import CoreGraphics
import Foundation
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

    // MARK: Magnetic stops

    /// Drags the thumb of an active scrub to track position `s`.
    private func scrub(_ m: ZoomScrubModel, to s: CGFloat, now: TimeInterval = 0) -> ZoomScrubModel.Action? {
        m.update(dy: m.startPosition - s, now: now)
    }

    func testReleaseJustOffAStopSettlesExactlyOnIt() {
        for z: CGFloat in [1.03, 1.06, 0.95, 0.94, 2.12, 1.9] {
            let m = ZoomScrubModel()
            m.begin(stops: [0.5, 1, 2, 4, 8], zoom: z < 1.5 ? 2 : 1, isFront: false)
            _ = scrub(m, to: m.position(forZoom: z))
            let stop: CGFloat = z < 1.5 ? 1 : 2
            XCTAssertEqual(m.end(), .zoom(stop), "\(z)× should settle on \(stop)×")
            XCTAssertEqual(m.zoom, stop)
            XCTAssertEqual(m.position, m.position(ofStop: stop == 1 ? 1 : 2), accuracy: 1e-9)
        }
    }

    func testReleaseBetweenStopsKeepsTheValueRoundedToATenth() {
        let cases: [(CGFloat, CGFloat)] = [(1.1, 1.1), (1.2, 1.2), (1.34, 1.3), (1.46, 1.5), (2.8, 2.8), (0.73, 0.7), (5.56, 5.6)]
        for (dragged, expected) in cases {
            let m = ZoomScrubModel()
            m.begin(stops: [0.5, 1, 2, 4, 8], zoom: 1, isFront: false)
            _ = scrub(m, to: m.position(forZoom: dragged))
            let action = m.end()
            XCTAssertEqual(m.zoom, expected, accuracy: 1e-9, "\(dragged)× released")
            if abs(dragged - expected) > 1e-6 {
                XCTAssertEqual(action, .zoom(m.zoom))
            }
        }
    }

    func testInsideTheBandZoomIsExactlyTheStop() {
        let m = ZoomScrubModel()
        m.begin(stops: [0.5, 1, 2, 4, 8], zoom: 2, isFront: false)
        let c = m.position(ofStop: 1)
        var s = m.position
        while s >= c - ZoomScrubModel.detent / 2 + 0.5 {
            _ = scrub(m, to: s)
            if abs(s - c) <= ZoomScrubModel.detent / 2 {
                XCTAssertEqual(m.zoom, 1, "exactly 1× at \(s - c) pt from the stop")
            }
            s -= 0.5
        }
    }

    func testEnteringTheBandTicksOnceAndTheEdgeDoesNotChatter() {
        let m = ZoomScrubModel()
        m.begin(stops: [0.5, 1, 2, 4, 8], zoom: 2, isFront: false)
        let edge = m.position(ofStop: 1) + ZoomScrubModel.detent / 2
        let before = m.detentTick
        var s = m.position
        while s > edge - 1 {
            _ = scrub(m, to: s)
            s -= 1
        }
        XCTAssertEqual(m.detentTick, before + 1, "one tick on entering 1×")
        XCTAssertEqual(m.zoom, 1)
        // Resting on the edge: jitter in and out within the hysteresis.
        for _ in 0..<10 {
            _ = scrub(m, to: edge + ZoomScrubModel.detentHysteresis - 1)
            _ = scrub(m, to: edge - 1)
        }
        XCTAssertEqual(m.detentTick, before + 1, "no chatter at the band's edge")
        // Properly leaving and coming back ticks again.
        _ = scrub(m, to: edge + ZoomScrubModel.detentHysteresis + 3)
        _ = scrub(m, to: edge - 1)
        XCTAssertEqual(m.detentTick, before + 2)
    }

    func testRampsAreContinuousAndResistanceFree() {
        // Equal finger travel gives equal log-zoom change anywhere on a ramp.
        let m = ZoomScrubModel()
        m.begin(stops: [0.5, 1, 2, 4, 8], zoom: 1, isFront: false)
        let a = m.position(forZoom: 1.2), b = m.position(forZoom: 1.5)
        XCTAssertEqual(b - a, log(1.5 / 1.2) * ZoomScrubModel.pointsPerLog, accuracy: 1e-6)
        // 1.1× is reachable (and kept) with a deliberate drag.
        _ = scrub(m, to: m.position(forZoom: 1.1))
        XCTAssertEqual(m.zoom, 1.1, accuracy: 1e-6)
        _ = m.end()
        XCTAssertEqual(m.zoom, 1.1, accuracy: 1e-9)
    }

    func testLiftOffJitterIsIgnored() {
        let m = ZoomScrubModel()
        m.begin(stops: [0.5, 1, 2, 4, 8], zoom: 1, isFront: false)
        let edge = m.position(ofStop: 1) + ZoomScrubModel.detent / 2
        _ = scrub(m, to: edge - 4, now: 0.0)
        _ = scrub(m, to: edge, now: 0.5)
        XCTAssertEqual(m.zoom, 1)
        // The finger rolls ~6 pt as it lifts: past the release zone on its own.
        let jitter = edge + 5.8
        XCTAssertGreaterThan(abs(log(m.zoom(at: jitter))), ZoomScrubModel.releaseZone)
        _ = scrub(m, to: jitter, now: 0.55)
        XCTAssertNotEqual(m.zoom, 1)
        XCTAssertEqual(m.end(now: 0.58), .zoom(1), "lift-off roll must not leave 1.1×")
        XCTAssertEqual(m.zoom, 1)
    }

    func testDeliberateEndMovementIsKept() {
        // Same travel, but the finger then rests before lifting: it's meant.
        let m = ZoomScrubModel()
        m.begin(stops: [0.5, 1, 2, 4, 8], zoom: 1, isFront: false)
        let edge = m.position(ofStop: 1) + ZoomScrubModel.detent / 2
        _ = scrub(m, to: edge, now: 0.5)
        _ = scrub(m, to: edge + 5.8, now: 0.52)
        XCTAssertEqual(m.end(now: 0.8), .zoom(1.1))
        XCTAssertEqual(m.zoom, 1.1)

        // A fast move right up to lift-off is well past the jitter threshold.
        let f = ZoomScrubModel()
        f.begin(stops: [0.5, 1, 2, 4, 8], zoom: 1, isFront: false)
        _ = scrub(f, to: f.position(forZoom: 1.5), now: 0.53)
        _ = scrub(f, to: f.position(forZoom: 3), now: 0.545)
        XCTAssertNil(f.end(now: 0.55))
        XCTAssertEqual(f.zoom, 3, accuracy: 1e-9)
    }

    func testReleaseOntoAStopTicks() {
        let m = ZoomScrubModel()
        m.begin(stops: [0.5, 1, 2, 4, 8], zoom: 2, isFront: false)
        _ = scrub(m, to: m.position(forZoom: 1.05))
        let before = m.detentTick
        XCTAssertEqual(m.end(), .zoom(1))
        XCTAssertEqual(m.detentTick, before + 1)
    }

    func testTouchWithoutMovingLeavesAnOffStopZoomAlone() {
        let m = ZoomScrubModel()
        m.begin(stops: [0.5, 1, 2, 4, 8], zoom: 1.03, isFront: false)
        XCTAssertNil(m.update(dy: 0))
        XCTAssertNil(m.end())
        XCTAssertEqual(m.zoom, 1.03, accuracy: 1e-9)
    }

    func testReadoutShowsWhereAReleaseWouldLand() {
        let m = ZoomScrubModel()
        m.begin(stops: [0.5, 1, 2, 4, 8], zoom: 1, isFront: false)
        _ = scrub(m, to: m.position(forZoom: 1.06))
        XCTAssertEqual(ZoomDial.label(m.displayZoom), "1\u{00D7}")
        _ = scrub(m, to: m.position(forZoom: 1.12))
        XCTAssertEqual(ZoomDial.label(m.displayZoom), "1.1\u{00D7}")
        _ = scrub(m, to: m.position(forZoom: 1.24))
        XCTAssertEqual(ZoomDial.label(m.displayZoom), "1.2\u{00D7}")
    }

    func testSettle() {
        let stops: [CGFloat] = [0.5, 1, 2, 4, 8]
        XCTAssertEqual(ZoomScrubModel.settle(1.069, stops: stops), 1)
        XCTAssertEqual(ZoomScrubModel.settle(0.94, stops: stops), 1)
        XCTAssertEqual(ZoomScrubModel.settle(1.08, stops: stops), 1.1)
        XCTAssertEqual(ZoomScrubModel.settle(1.2, stops: stops), 1.2)
        XCTAssertEqual(ZoomScrubModel.settle(0.3, stops: stops), 0.5)
        XCTAssertEqual(ZoomScrubModel.settle(12, stops: stops), 8)
        XCTAssertEqual(ZoomScrubModel.settle(3.3, stops: stops), 3.3)
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
