import Foundation
import XCTest
@testable import Unproc

final class DeletionHistoryTests: XCTestCase {
    private func item(_ id: String, age: TimeInterval = 0) -> PhotoItem {
        PhotoItem(id: id, source: .file(URL(fileURLWithPath: "/tmp/\(id).jpg")),
                  createdAt: Date(timeIntervalSince1970: 1_000_000 - age))
    }

    func testStartsEmpty() {
        let h = DeletionHistory()
        XCTAssertTrue(h.isEmpty)
        XCTAssertEqual(h.pendingCount, 0)
        XCTAssertFalse(h.canUndo)
        XCTAssertFalse(h.canRedo)
        XCTAssertNil(h.nextRedo)
    }

    func testUndoOnEmptyAndRedoOnEmptyReturnNil() {
        var h = DeletionHistory()
        XCTAssertNil(h.undo())
        XCTAssertNil(h.redo())
        XCTAssertTrue(h.isEmpty)
    }

    func testHideUndoRedo() {
        var h = DeletionHistory()
        let a = item("a"), b = item("b")
        h.hide(a)
        h.hide(b)
        XCTAssertEqual(h.pendingCount, 2)
        XCTAssertTrue(h.isHidden("a"))
        XCTAssertTrue(h.isHidden("b"))
        XCTAssertTrue(h.canUndo)
        XCTAssertFalse(h.canRedo)

        XCTAssertEqual(h.undo(), b, "undo restores the most recent hide")
        XCTAssertFalse(h.isHidden("b"))
        XCTAssertTrue(h.isHidden("a"))
        XCTAssertTrue(h.canRedo)
        XCTAssertEqual(h.nextRedo, b)

        XCTAssertEqual(h.undo(), a)
        XCTAssertTrue(h.isEmpty)
        XCTAssertFalse(h.canUndo)
        XCTAssertEqual(h.nextRedo, a, "redo re-hides in reverse order of undo")

        XCTAssertEqual(h.redo(), a)
        XCTAssertEqual(h.redo(), b)
        XCTAssertNil(h.redo())
        XCTAssertEqual(h.pendingCount, 2)
        XCTAssertFalse(h.canRedo)
        XCTAssertTrue(h.canUndo)
    }

    func testNewHideClearsRedo() {
        var h = DeletionHistory()
        h.hide(item("a"))
        h.hide(item("b"))
        h.undo()
        XCTAssertTrue(h.canRedo)
        h.hide(item("c"))
        XCTAssertFalse(h.canRedo)
        XCTAssertNil(h.redo())
        XCTAssertEqual(Set(h.pending.keys), ["a", "c"])
    }

    func testHidingTwiceIsIgnored() {
        var h = DeletionHistory()
        h.hide(item("a"))
        h.hide(item("a"))
        XCTAssertEqual(h.pendingCount, 1)
        XCTAssertNotNil(h.undo())
        XCTAssertNil(h.undo(), "a duplicate hide must not leave a second undo step")
        XCTAssertTrue(h.isEmpty)
    }

    func testDuplicateHideDoesNotClearRedo() {
        var h = DeletionHistory()
        h.hide(item("a"))
        h.hide(item("b"))
        h.undo()               // b restored, redo = [b]
        h.hide(item("a"))      // already hidden: no-op
        XCTAssertTrue(h.canRedo)
        XCTAssertEqual(h.redo()?.id, "b")
    }

    func testUnlimitedUndo() {
        var h = DeletionHistory()
        let items = (0..<200).map { item("p\($0)") }
        items.forEach { h.hide($0) }
        XCTAssertEqual(h.pendingCount, 200)
        var restored: [PhotoItem] = []
        while let i = h.undo() { restored.append(i) }
        XCTAssertEqual(restored, items.reversed())
        XCTAssertTrue(h.isEmpty)
    }

    func testPendingItemsFollowGivenOrderThenLeftovers() {
        var h = DeletionHistory()
        let a = item("a", age: 0), b = item("b", age: 10), c = item("c", age: 20), x = item("x", age: 30)
        h.hide(c)
        h.hide(x)
        h.hide(a)
        let ordered = h.pendingItems(orderedLike: [a, b, c])
        XCTAssertEqual(ordered.map(\.id), ["a", "c", "x"], "listed ones in list order, unlisted appended")
        XCTAssertEqual(h.pendingItems(orderedLike: []).count, 3)
    }

    func testReset() {
        var h = DeletionHistory()
        h.hide(item("a"))
        h.hide(item("b"))
        h.undo()
        h.reset()
        XCTAssertTrue(h.isEmpty)
        XCTAssertFalse(h.canUndo)
        XCTAssertFalse(h.canRedo)
        XCTAssertNil(h.nextRedo)
    }
}
