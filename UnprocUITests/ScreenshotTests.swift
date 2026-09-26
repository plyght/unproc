import XCTest

/// Walks through the app in the Simulator (fed by the demo camera) and
/// captures screenshots for CI. Every screenshot is attached with
/// `.keepAlways`, then exported from the .xcresult by the workflow.
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-UNPROC_DEMO", "-UNPROC_RESET"]
        app.launch()
    }

    func testTour() {
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 15), "camera screen never appeared")
        settle()
        snap("01-camera")

        // Take a couple of shots so the thumbnail and viewer have content.
        app.buttons["shutter"].tap()
        settle(2)
        app.buttons["shutter"].tap()
        settle(2)
        waitForPhotos()
        snap("02-after-shot")

        // Settings menu.
        if tapIfPresent("statusBadge") {
            settle()
            snap("03-menu")
            // A look and RAW output, then close.
            tapIfPresent("menu.look.s1-01")
            tapIfPresent("menu.format.raw")
            settle()
            snap("04-menu-look-raw")
            if !tapIfPresent("menu.dismiss") { tapIfPresent("statusBadge") }
            settle()
            snap("05-look-applied")
        }

        // Other looks, via swipe on the viewfinder.
        let viewfinder = app.descendants(matching: .any)["viewfinder"]
        if viewfinder.exists {
            for index in 0..<3 {
                viewfinder.swipeLeft()
                settle(0.4)
                snap(String(format: "06-look-swipe-%d", index + 1))
            }
        }

        // Lenses.
        if tapIfPresent("lensButton") {
            settle()
            snap("07-lens-next")
        }
        // PRO mode.
        if tapIfPresent("statusBadge") {
            settle(0.5)
            tapIfPresent("menu.pro.on")
            tapIfPresent("menu.zebras.on")
            tapIfPresent("menu.peaking.on")
            if !tapIfPresent("menu.dismiss") { tapIfPresent("statusBadge") }
            settle()
            snap("09-pro")
            if tapIfPresent("pro.shutter") {
                settle()
                snap("10-pro-shutter-dial")
            }
            if tapIfPresent("pro.iso") {
                settle()
                snap("11-pro-iso-dial")
            }
            if tapIfPresent("pro.aperture") {
                settle()
                snap("11b-pro-aperture-dial")
            }
        }

        // Double exposure.
        if tapIfPresent("statusBadge") {
            settle(0.5)
            tapIfPresent("menu.pro.off")
            tapIfPresent("menu.double.on")
            if !tapIfPresent("menu.dismiss") { tapIfPresent("statusBadge") }
            settle()
            tapIfPresent("shutter")
            settle(2)
            snap("12-double-exposure-first-frame")
            tapIfPresent("shutter")
            settle(2)
        }

        // Frame ratios.
        for (id, name) in [("16:9", "16x9"), ("1:1", "1x1"), ("3:2", "3x2")] {
            if tapIfPresent("statusBadge") {
                settle(0.5)
                tapIfPresent("menu.double.off")
                tapIfPresent("menu.ratio.\(id)")
                if !tapIfPresent("menu.dismiss") { tapIfPresent("statusBadge") }
                settle()
                snap("12b-ratio-\(name)")
            }
        }
        if tapIfPresent("statusBadge") {
            settle(0.5)
            tapIfPresent("menu.pro.on")
            tapIfPresent("menu.ratio.16:9")
            if !tapIfPresent("menu.dismiss") { tapIfPresent("statusBadge") }
            settle()
            snap("12c-ratio-16x9-pro")
            tapIfPresent("statusBadge")
            settle(0.5)
            tapIfPresent("menu.pro.off")
            tapIfPresent("menu.ratio.4:3")
            if !tapIfPresent("menu.dismiss") { tapIfPresent("statusBadge") }
            settle()
        }

        // Viewer.
        waitForPhotos()
        if tapIfPresent("thumbnail") {
            settle(1.5)
            snap("13-viewer")
            tapIfPresent("viewer.delete")
            settle()
            snap("14-viewer-deleted")
            tapIfPresent("viewer.undo")
            settle()
            snap("15-viewer-undo")
            tapIfPresent("viewer.close")
            settle()
        }
    }

    /// Holds the lens button and drags, capturing the zoom track mid-gesture
    /// (XCTest blocks during the drag, so screenshots come from a background queue).
    func testZoomScrub() {
        let lens = app.descendants(matching: .any)["lensButton"]
        XCTAssertTrue(lens.waitForExistence(timeout: 15))
        settle()
        let start = lens.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        // Hold the lens button and drag up: zoom in on the inline dial.
        dragWhileCapturing(from: start, dy: -150, name: "16-zoom-scrub-in")
        settle(0.3)
        snap("17-zoom-after-scrub")
        // Hold again and force it down past .5×, toward the selfie flip.
        dragWhileCapturing(from: start, dy: 110, name: "18-zoom-force-selfie", holdFirst: 0.05)
        settle()
        snap("19-selfie")
    }

    private func dragWhileCapturing(from start: XCUICoordinate, dy: CGFloat, name: String, holdFirst: TimeInterval = 0.4) {
        let shots = Screens()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.6) {
            shots.image = XCUIScreen.main.screenshot()
        }
        start.press(forDuration: holdFirst,
                    thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)),
                    withVelocity: .slow,
                    thenHoldForDuration: 1.6)
        if let image = shots.image {
            let attachment = XCTAttachment(screenshot: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private final class Screens: @unchecked Sendable {
        var image: XCUIScreenshot?
    }

    // MARK: - Helpers

    /// Waits (up to 20 s) until the thumbnail reports at least one photo.
    private func waitForPhotos() {
        let thumb = app.descendants(matching: .any)["thumbnail"]
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let value = thumb.value as? String, let count = Int(value), count > 0 { return }
            settle(0.5)
        }
        XCTFail("no photos appeared (thumbnail value: \(String(describing: thumb.value)))")
    }

    @discardableResult
    private func tapIfPresent(_ id: String, timeout: TimeInterval = 3) -> Bool {
        let element = app.descendants(matching: .any)[id]
        guard element.waitForExistence(timeout: timeout), element.isHittable else { return false }
        element.tap()
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
