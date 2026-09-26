import AVFoundation
import XCTest
@testable import Unproc

final class SettingsTests: XCTestCase {
    private func decode(_ json: String) throws -> CaptureSettings {
        try JSONDecoder().decode(CaptureSettings.self, from: Data(json.utf8))
    }

    func testDefaults() {
        let d = CaptureSettings()
        XCTAssertEqual(d.output, .jpeg)
        XCTAssertEqual(d.rawFlavor, .bayer)
        XCTAssertEqual(d.lookID, "zero")
        XCTAssertFalse(d.doubleExposure)
        XCTAssertFalse(d.proMode)
        XCTAssertTrue(d.zebras)
        XCTAssertFalse(d.peaking)
        XCTAssertNil(d.lensID)
        XCTAssertEqual(d.ratio, .fourThree)
        XCTAssertEqual(d.accent, AccentID.orange)
        XCTAssertEqual(d.flash, .off)
        XCTAssertFalse(d.lefty)
    }

    func testDecodingEmptyObjectGivesDefaults() throws {
        XCTAssertEqual(try decode("{}"), CaptureSettings())
    }

    func testDecodingOlderPayloadWithoutRatioAndAccentKeepsOtherFields() throws {
        let json = """
        {"output":"raw","rawFlavor":"proRAW","lookID":"s1-03","doubleExposure":true,
         "proMode":true,"zebras":false,"peaking":true,"lensID":"back.tele"}
        """
        let s = try decode(json)
        XCTAssertEqual(s.output, .raw)
        XCTAssertEqual(s.rawFlavor, .proRAW)
        XCTAssertEqual(s.lookID, "s1-03")
        XCTAssertTrue(s.doubleExposure)
        XCTAssertTrue(s.proMode)
        XCTAssertFalse(s.zebras)
        XCTAssertTrue(s.peaking)
        XCTAssertEqual(s.lensID, "back.tele")
        XCTAssertEqual(s.ratio, .fourThree)
        XCTAssertEqual(s.accent, AccentID.orange)
    }

    func testDecodingUnknownEnumValuesFallsBackPerField() throws {
        let json = """
        {"output":"tiff","rawFlavor":"quantum","ratio":"5:4","accent":"purple","lookID":"s1-02","zebras":"yes"}
        """
        let s = try decode(json)
        XCTAssertEqual(s.output, .jpeg)
        XCTAssertEqual(s.rawFlavor, .bayer)
        XCTAssertEqual(s.ratio, .fourThree)
        // Accent is a free-form finish id; unknown ids resolve to orange at display time.
        XCTAssertEqual(s.accent, "purple")
        XCTAssertEqual(s.zebras, true, "wrongly typed value falls back to the default")
        XCTAssertEqual(s.lookID, "s1-02", "valid fields survive invalid neighbours")
    }

    func testDecodingNullsAndExtraKeys() throws {
        let s = try decode(#"{"lensID":null,"ratio":"16:9","futureSetting":42,"accent":"orange"}"#)
        XCTAssertNil(s.lensID)
        XCTAssertEqual(s.ratio, .sixteenNine)
        XCTAssertEqual(s.accent, "orange")
    }

    func testDecodingNonObjectThrows() {
        XCTAssertThrowsError(try decode("[]"))
        XCTAssertThrowsError(try decode("42"))
    }

    func testRoundTrip() throws {
        var s = CaptureSettings()
        s.output = .raw
        s.rawFlavor = .proRAW
        s.lookID = "s1-07"
        s.doubleExposure = true
        s.proMode = true
        s.zebras = false
        s.peaking = true
        s.lensID = "back.wide.crop2"
        s.ratio = .square
        s.accent = "cosmic-orange"
        s.flash = .auto
        s.lefty = true
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(CaptureSettings.self, from: data), s)
        XCTAssertLessThan(data.count, 4096, "must fit the capture intent's app context")

        for ratio in FrameRatio.allCases {
            var r = CaptureSettings()
            r.ratio = ratio
            XCTAssertEqual(try JSONDecoder().decode(CaptureSettings.self, from: JSONEncoder().encode(r)).ratio, ratio)
        }
    }

    func testRoundTripThroughPropertyList() throws {
        var s = CaptureSettings()
        s.ratio = .threeTwo
        s.lensID = "front.wide"
        let data = try PropertyListEncoder().encode(s)
        XCTAssertEqual(try PropertyListDecoder().decode(CaptureSettings.self, from: data), s)
    }

    func testEncodedKeysAreStable() throws {
        var s = CaptureSettings()
        s.lensID = "back.wide"
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any]
        let keys = Set(object?.keys.map { $0 } ?? [])
        for key in ["output", "rawFlavor", "lookID", "doubleExposure", "proMode", "zebras",
                    "peaking", "lensID", "ratio", "accent"] {
            XCTAssertTrue(keys.contains(key), "missing key \(key) in \(keys)")
        }
        XCTAssertEqual(object?["ratio"] as? String, "4:3")
    }

    func testEnumRawValues() {
        XCTAssertEqual(OutputFormat.jpeg.rawValue, "jpeg")
        XCTAssertEqual(OutputFormat.raw.rawValue, "raw")
        XCTAssertEqual(RawFlavor.bayer.rawValue, "bayer")
        XCTAssertEqual(RawFlavor.proRAW.rawValue, "proRAW")
        XCTAssertEqual(FlashSetting.off.rawValue, "off")
        XCTAssertEqual(FlashSetting.auto.rawValue, "auto")
        XCTAssertEqual(FlashSetting.on.rawValue, "on")
        XCTAssertEqual(AccentID.orange, "orange")
    }

    // MARK: Lens labels

    private func lens(_ zoom: CGFloat, kind: Lens.Kind = .wide) -> Lens {
        TestSupport.lens(id: "t", kind: kind, position: kind == .front ? .front : .back, zoom: zoom)
    }

    func testLensLabels() {
        XCTAssertEqual(lens(0.5, kind: .ultraWide).label, "0.5")
        XCTAssertEqual(lens(1).label, "1")
        XCTAssertEqual(lens(2).label, "2")
        XCTAssertEqual(lens(2.4).label, "2.4")
        XCTAssertEqual(lens(4, kind: .tele).label, "4")
        XCTAssertEqual(lens(8, kind: .tele).label, "8")
        XCTAssertEqual(lens(10, kind: .tele).label, "10")
        XCTAssertEqual(lens(1, kind: .front).label, "FRONT")
    }

    func testLensIsFront() {
        XCTAssertTrue(lens(1, kind: .front).isFront)
        XCTAssertFalse(lens(1).isFront)
    }
}
