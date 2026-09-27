import XCTest
@testable import Unproc

final class HoldOrientationTests: XCTestCase {
    func testUprightIsPortrait() {
        XCTAssertEqual(HoldOrientation.classify(x: 0.05, y: -0.98, z: -0.1, previous: .unknown), .portrait)
    }

    func testSlightTiltStaysPortrait() {
        XCTAssertEqual(HoldOrientation.classify(x: 0.55, y: -0.7, z: -0.3, previous: .portrait), .portrait)
    }

    func testClearlySidewaysIsLandscape() {
        XCTAssertEqual(HoldOrientation.classify(x: -0.95, y: -0.1, z: -0.2, previous: .portrait), .landscape)
        XCTAssertEqual(HoldOrientation.classify(x: 0.95, y: 0.05, z: -0.2, previous: .unknown), .landscape)
    }

    func testFlatKeepsPreviousOrPortrait() {
        XCTAssertEqual(HoldOrientation.classify(x: 0.1, y: 0.1, z: -0.99, previous: .landscape), .landscape)
        XCTAssertEqual(HoldOrientation.classify(x: 0.1, y: 0.1, z: -0.99, previous: .unknown), .portrait)
    }

    func testLandscapeNeedsClearUprightToLeave() {
        XCTAssertEqual(HoldOrientation.classify(x: 0.6, y: -0.7, z: 0, previous: .landscape), .landscape)
        XCTAssertEqual(HoldOrientation.classify(x: 0.2, y: -0.95, z: 0, previous: .landscape), .portrait)
    }
}
