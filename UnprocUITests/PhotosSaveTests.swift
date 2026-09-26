import XCTest

/// Exercises the real Photos save path (PhotoLibrarySink) in the Simulator:
/// a JPEG shot and a RAW+JPEG shot (the demo returns a real iPhone DNG when
/// CI has bundled one). Fails if a save error banner appears or no photo
/// lands in the library.
final class PhotosSaveTests: XCTestCase {
    private var app: XCUIApplication!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-UNPROC_DEMO", "-UNPROC_RESET", "-UNPROC_PHOTOS"]
        app.launch()
    }

    func testSaveJPEGAndRAWToPhotos() {
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 15), "camera screen never appeared")
        allowPhotoAccess()

        let before = photoCount()

        // JPEG.
        app.buttons["shutter"].tap()
        allowPhotoAccess()
        XCTAssertTrue(waitForPhotoCount(above: before), "JPEG shot never reached Photos")
        assertNoSaveError("JPEG")
        snap("P1-saved-jpeg")

        // RAW + JPEG.
        tap("statusBadge")
        tap("menu.format.raw")
        tap("menu.dismiss")
        let afterJPEG = photoCount()
        app.buttons["shutter"].tap()
        allowPhotoAccess()
        XCTAssertTrue(waitForPhotoCount(above: afterJPEG), "RAW+JPEG shot never reached Photos")
        assertNoSaveError("RAW+JPEG")
        snap("P2-saved-raw")

        // Open the viewer on the library.
        if tap("thumbnail") {
            settle(1.5)
            snap("P3-viewer-photos")
            tap("viewer.close")
        }
    }

    // MARK: - Helpers

    /// Taps through any Photos permission alert (wording varies by prompt/OS).
    private func allowPhotoAccess() {
        let labels = ["Allow Full Access", "Allow Access to All Photos", "Allow", "OK"]
        for _ in 0..<3 {
            var tapped = false
            for label in labels {
                let button = springboard.buttons[label]
                if button.waitForExistence(timeout: 1.5) {
                    button.tap()
                    tapped = true
                    break
                }
            }
            if !tapped { return }
            settle(0.5)
        }
    }

    private func photoCount() -> Int {
        let thumb = app.descendants(matching: .any)["thumbnail"]
        guard thumb.waitForExistence(timeout: 3), let value = thumb.value as? String else { return 0 }
        return Int(value) ?? 0
    }

    private func waitForPhotoCount(above count: Int, timeout: TimeInterval = 25) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if photoCount() > count { return true }
            allowPhotoAccess()
            settle(0.5)
        }
        return false
    }

    private func assertNoSaveError(_ what: String) {
        let error = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'SAVE FAILED' OR label CONTAINS[c] 'FAILED'")).firstMatch
        if error.exists {
            XCTFail("\(what): save error shown: \(error.label)")
            snap("P-error-\(what)")
        }
    }

    @discardableResult
    private func tap(_ id: String, timeout: TimeInterval = 3) -> Bool {
        let element = app.descendants(matching: .any)[id]
        guard element.waitForExistence(timeout: timeout), element.isHittable else { return false }
        element.tap()
        settle(0.4)
        return true
    }

    private func settle(_ seconds: TimeInterval = 1) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
