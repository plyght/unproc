import CoreGraphics
import XCTest
@testable import Unproc

/// How `LensDiscovery` turns the selfie camera's zoom range into framings.
final class FrontFramingTests: XCTestCase {
    func testMultiplierGivesTheStandardFraming() throws {
        // display zoom = factor × 0.8 → the standard (1×) framing is factor 1.25.
        let framing = try XCTUnwrap(LensDiscovery.frontFraming(minFactor: 1, maxFactor: 8, multiplier: 0.8,
                                                               isSquareSensor: true))
        XCTAssertEqual(framing.wideFactor, 1)
        XCTAssertEqual(framing.tightFactor, 1.25, accuracy: 1e-9)
        XCTAssertEqual(framing.source, "multiplier")
        // Works without the square sensor too, if the device says so.
        XCTAssertNotNil(LensDiscovery.frontFraming(minFactor: 1, maxFactor: 8, multiplier: 0.8, isSquareSensor: false))
    }

    func testSquareSensorFallsBackWhenTheMultiplierIsUseless() throws {
        for multiplier: CGFloat in [1, 0.95, 1.4, 0, .nan] {
            let framing = try XCTUnwrap(LensDiscovery.frontFraming(minFactor: 1, maxFactor: 8, multiplier: multiplier,
                                                                   isSquareSensor: true),
                                        "multiplier \(multiplier)")
            XCTAssertEqual(framing.tightFactor, LensDiscovery.squareFrontFallbackFactor, accuracy: 1e-9)
            XCTAssertEqual(framing.source, "fallback")
        }
    }

    func testOrdinaryFrontCameraStaysSingle() {
        XCTAssertNil(LensDiscovery.frontFraming(minFactor: 1, maxFactor: 16, multiplier: 1, isSquareSensor: false))
        XCTAssertNil(LensDiscovery.frontFraming(minFactor: 1, maxFactor: 16, multiplier: 0.95, isSquareSensor: false),
                     "a stop under 1.1× over the wide one isn't worth it")
    }

    func testTightFactorMustBeReachable() {
        XCTAssertNil(LensDiscovery.frontFraming(minFactor: 1, maxFactor: 1.2, multiplier: 1, isSquareSensor: true))
        // Multiplier stop out of range, fallback in range.
        let framing = LensDiscovery.frontFraming(minFactor: 1, maxFactor: 1.5, multiplier: 0.5, isSquareSensor: true)
        XCTAssertEqual(framing?.source, "fallback")
    }

    func testMinimumAboveOneIsTheWideFraming() throws {
        let framing = try XCTUnwrap(LensDiscovery.frontFraming(minFactor: 1.1, maxFactor: 8, multiplier: 0.5,
                                                               isSquareSensor: true))
        XCTAssertEqual(framing.wideFactor, 1.1, accuracy: 1e-9)
        XCTAssertEqual(framing.tightFactor, 2, accuracy: 1e-9)
    }
}
