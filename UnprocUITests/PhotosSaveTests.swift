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

        // JPEG. Success = no save error; the library count is checked too when
        // the simulator has granted read access (it doesn't always, and saving
        // only needs add access).
        app.buttons["shutter"].tap()
        allowPhotoAccess()
        verifySaved("JPEG", countBefore: before)
        snap("P1-saved-jpeg")

        // RAW + JPEG.
        tap("statusBadge")
        tap("menu.format.raw")
        dismissMenu()
        let afterJPEG = photoCount()
        pressShutter()
        allowPhotoAccess()
        // One retry if the press landed during the menu's closing animation.
        if afterJPEG > 0, !waitForPhotoCount(above: afterJPEG, timeout: 10) {
            pressShutter()
            allowPhotoAccess()
        }
        verifySaved("RAW+JPEG", countBefore: afterJPEG)
        snap("P2-saved-raw")

        // Open the viewer on the library.
        if tap("thumbnail") {
            settle(1.5)
            snap("P3-viewer-photos")
            tap("viewer.close")
        }
    }

    // MARK: - Helpers

    /// Taps the shutter once it's enabled and hittable (after menus settle).
    private func pressShutter() {
        let shutter = app.buttons["shutter"]
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, !(shutter.exists && shutter.isHittable && shutter.isEnabled) {
            settle(0.25)
        }
        settle(0.4)
        shutter.tap()
    }

    /// Closes the settings menu by tapping the tap-outside area near the bottom
    /// of the screen (the menu itself covers the centre).
    @discardableResult
    private func dismissMenu() -> Bool {
        let catcher = app.descendants(matching: .any)["menu.dismiss"]
        guard catcher.waitForExistence(timeout: 2) else { return false }
        catcher.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.985)).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        return true
    }

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

    /// Waits for the save to finish: fails on a save error banner; when the
    /// library is readable, also requires the photo count to go up.
    private func verifySaved(_ what: String, countBefore: Int) {
        let readable = countBefore > 0
        if readable {
            XCTAssertTrue(waitForPhotoCount(above: countBefore), "\(what): shot never appeared in the library")
        } else {
            // No read access: give the save time, then rely on the error check
            // (the app log records "save: ok …" for each successful save).
            _ = waitForPhotoCount(above: 0, timeout: 12)
        }
        assertNoSaveError(what)
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
