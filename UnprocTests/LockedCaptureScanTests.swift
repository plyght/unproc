import Foundation
import XCTest
@testable import Unproc

final class LockedCaptureScanTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000.25)

    private func withTempDir(_ body: (URL) throws -> Void) rethrows {
        let dir = TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func setModified(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: - JPEG completeness

    func testCompleteJPEGDetection() {
        let jpeg = TestSupport.jpegData(width: 16, height: 16)
        XCTAssertTrue(LockedCaptureScan.isCompleteJPEG(jpeg))
        XCTAssertTrue(LockedCaptureScan.isCompleteJPEG(jpeg + Data(repeating: 0, count: 10)), "padding after EOI is fine")
        XCTAssertFalse(LockedCaptureScan.isCompleteJPEG(jpeg.prefix(jpeg.count / 2)), "truncated")
        XCTAssertFalse(LockedCaptureScan.isCompleteJPEG(Data()))
        XCTAssertFalse(LockedCaptureScan.isCompleteJPEG(Data("not a jpeg at all".utf8)))
    }

    // MARK: - Scanning

    func testScanPairsJPEGsWithDNGsAndSkipsTempFiles() throws {
        try withTempDir { dir in
            let jpeg = TestSupport.jpegData(width: 16, height: 16)
            try jpeg.write(to: dir.appendingPathComponent("a.jpg"))
            try Data([1, 2, 3]).write(to: dir.appendingPathComponent("a.dng"))
            try jpeg.write(to: dir.appendingPathComponent("b.JPG"))
            try Data([4]).write(to: dir.appendingPathComponent("c.dng"))
            try Data([5]).write(to: dir.appendingPathComponent(".a.jpg.tmp-atomic"))
            try Data([6]).write(to: dir.appendingPathComponent("notes.txt"))

            let contents = try XCTUnwrap(LockedCaptureScan.scan(dir, directSaveGrace: 0))
            XCTAssertEqual(contents.pairs.map(\.jpeg.lastPathComponent), ["a.jpg", "b.JPG"])
            XCTAssertEqual(contents.pairs.first?.dng?.lastPathComponent, "a.dng")
            XCTAssertNil(contents.pairs.last?.dng)
            XCTAssertEqual(contents.orphanDNGs.map(\.lastPathComponent), ["c.dng"])
            XCTAssertTrue(contents.pendingJPEGs.isEmpty)
            XCTAssertFalse(contents.isEmpty)
        }
    }

    func testTruncatedJPEGWaitsThenIsImportedAnyway() throws {
        try withTempDir { dir in
            let jpeg = TestSupport.jpegData(width: 16, height: 16)
            let url = dir.appendingPathComponent("half.jpg")
            try jpeg.prefix(jpeg.count / 2).write(to: url)

            let fresh = try XCTUnwrap(LockedCaptureScan.scan(dir))
            XCTAssertEqual(fresh.pendingJPEGs.map(\.lastPathComponent), ["half.jpg"])
            XCTAssertTrue(fresh.pairs.isEmpty)

            try setModified(url, Date().addingTimeInterval(-LockedCaptureScan.suspectJPEGGrace - 5))
            let old = try XCTUnwrap(LockedCaptureScan.scan(dir))
            XCTAssertEqual(old.pairs.map(\.jpeg.lastPathComponent), ["half.jpg"], "never silently dropped")
            XCTAssertTrue(old.pendingJPEGs.isEmpty)
        }
    }

    func testScanOfMissingDirectoryIsNil() {
        let ghost = FileManager.default.temporaryDirectory.appendingPathComponent("unproc-missing-\(UUID().uuidString)")
        XCTAssertNil(LockedCaptureScan.scan(ghost))
    }

    func testEmptyDirectoryAndLastActivity() throws {
        try withTempDir { dir in
            let empty = try XCTUnwrap(LockedCaptureScan.scan(dir))
            XCTAssertTrue(empty.isEmpty)

            let url = dir.appendingPathComponent("x.jpg")
            try TestSupport.jpegData(width: 8, height: 8).write(to: url)
            let when = Date().addingTimeInterval(3600)
            try setModified(url, when)
            let contents = try XCTUnwrap(LockedCaptureScan.scan(dir))
            XCTAssertEqual(contents.lastActivity.timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 1)
        }
    }

    func testSinkOutputIsImportable() async throws {
        let dir = TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = SessionContentSink(root: dir)
        let photo = DevelopedPhoto(jpeg: TestSupport.jpegData(width: 16, height: 16), dng: Data([9, 9]), capturedAt: base)
        let a = try await sink.save(photo)
        let b = try await sink.save(photo)
        XCTAssertNotEqual(a, b, "same timestamp must not overwrite")

        let contents = try XCTUnwrap(LockedCaptureScan.scan(dir, directSaveGrace: 0))
        XCTAssertEqual(contents.pairs.count, 2)
        XCTAssertTrue(contents.pairs.allSatisfy { $0.dng != nil })
        XCTAssertTrue(contents.orphanDNGs.isEmpty)
        for pair in contents.pairs {
            let date = try XCTUnwrap(LockedCaptureScan.captureDate(fromName: pair.jpeg.lastPathComponent))
            XCTAssertEqual(date.timeIntervalSince1970, base.timeIntervalSince1970, accuracy: 0.002)
        }
    }

    // MARK: - Direct saves (extension -> Photos)

    private func marker(_ id: String) throws -> Data {
        try SessionMarker.encode(SessionMarker.Record(localIdentifier: id, date: base))
    }

    func testFreshUnmarkedJPEGWaitsForDirectSave() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("a.jpg")
            try TestSupport.jpegData(width: 16, height: 16).write(to: url)

            let fresh = try XCTUnwrap(LockedCaptureScan.scan(dir))
            XCTAssertTrue(fresh.pairs.isEmpty, "the extension may still be saving it to Photos")
            XCTAssertEqual(fresh.awaitingDirectSave.map(\.jpeg.lastPathComponent), ["a.jpg"])
            XCTAssertFalse(fresh.isEmpty)

            let later = try XCTUnwrap(LockedCaptureScan.scan(dir, now: Date().addingTimeInterval(LockedCaptureScan.directSaveGrace + 5)))
            XCTAssertEqual(later.pairs.map(\.jpeg.lastPathComponent), ["a.jpg"], "falls back to importing")
            XCTAssertTrue(later.awaitingDirectSave.isEmpty)
        }
    }

    func testSavedShotsAreSkippedAndMarkersAreNeverPhotos() throws {
        try withTempDir { dir in
            let jpeg = TestSupport.jpegData(width: 16, height: 16)
            // a: saved JPEG+DNG; b: not saved; c: saved, JPEG never written (DNG only);
            // d: saved marker whose files are already gone.
            try jpeg.write(to: dir.appendingPathComponent("a.jpg"))
            try Data([1]).write(to: dir.appendingPathComponent("a.dng"))
            try marker("A").write(to: dir.appendingPathComponent("a.saved"))
            try jpeg.write(to: dir.appendingPathComponent("b.jpg"))
            try Data([2]).write(to: dir.appendingPathComponent("b.dng"))
            try Data([3]).write(to: dir.appendingPathComponent("c.dng"))
            try marker("C").write(to: dir.appendingPathComponent("c.saved"))
            try marker("D").write(to: dir.appendingPathComponent("d.saved"))

            let contents = try XCTUnwrap(LockedCaptureScan.scan(dir, directSaveGrace: 0))
            XCTAssertEqual(contents.pairs.map(\.jpeg.lastPathComponent), ["b.jpg"], "only the unsaved shot is imported")
            XCTAssertEqual(contents.pairs.first?.dng?.lastPathComponent, "b.dng", "pairing unchanged")
            XCTAssertTrue(contents.orphanDNGs.isEmpty, "a saved DNG is not an orphan")
            XCTAssertTrue(contents.pendingJPEGs.isEmpty)
            XCTAssertTrue(contents.deletions.isEmpty)
            XCTAssertEqual(contents.saved.map(\.marker.lastPathComponent), ["a.saved", "c.saved", "d.saved"])
            XCTAssertEqual(contents.saved.map(\.localIdentifier), ["A", "C", "D"])
            XCTAssertEqual(contents.saved[0].files.map(\.lastPathComponent), ["a.dng", "a.jpg"], "DNG before JPEG")
            XCTAssertEqual(contents.saved[1].files.map(\.lastPathComponent), ["c.dng"])
            XCTAssertTrue(contents.saved[2].files.isEmpty)
        }
    }

    func testUnreadableSavedMarkerStillCountsAsSaved() throws {
        try withTempDir { dir in
            try TestSupport.jpegData(width: 16, height: 16).write(to: dir.appendingPathComponent("a.jpg"))
            try Data("garbage".utf8).write(to: dir.appendingPathComponent("a.saved"))
            let contents = try XCTUnwrap(LockedCaptureScan.scan(dir, directSaveGrace: 0))
            XCTAssertTrue(contents.pairs.isEmpty, "never risk a duplicate")
            XCTAssertEqual(contents.saved.count, 1)
            XCTAssertNil(contents.saved.first?.localIdentifier)
        }
    }

    func testDeletionMarkers() throws {
        try withTempDir { dir in
            let jpeg = TestSupport.jpegData(width: 16, height: 16)
            // x: deleted in the viewer (files gone); y: deleted but a DNG and the
            // old .saved marker were left behind; z: unreadable deletion marker.
            try marker("X").write(to: dir.appendingPathComponent("x.deleted"))
            try marker("Y").write(to: dir.appendingPathComponent("y.deleted"))
            try Data([1]).write(to: dir.appendingPathComponent("y.dng"))
            try jpeg.write(to: dir.appendingPathComponent("y.jpg"))
            try marker("Y").write(to: dir.appendingPathComponent("y.saved"))
            try Data().write(to: dir.appendingPathComponent("z.deleted"))

            let contents = try XCTUnwrap(LockedCaptureScan.scan(dir, directSaveGrace: 0))
            XCTAssertTrue(contents.pairs.isEmpty, "deleted shots are never imported")
            XCTAssertTrue(contents.orphanDNGs.isEmpty)
            XCTAssertTrue(contents.saved.isEmpty)
            XCTAssertEqual(contents.deletions.map(\.marker.lastPathComponent), ["x.deleted", "y.deleted", "z.deleted"])
            XCTAssertEqual(contents.deletions.map(\.localIdentifier), ["X", "Y", nil])
            XCTAssertTrue(contents.deletions[0].leftovers.isEmpty)
            XCTAssertEqual(contents.deletions[1].leftovers.map(\.lastPathComponent), ["y.dng", "y.jpg", "y.saved"])
            XCTAssertFalse(contents.isEmpty)
        }
    }

    func testSinkWithDirectSaveIsSkippedByScan() async throws {
        let dir = TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = SessionContentSink(root: dir, library: FakeLibrary(result: .success("asset-1")))
        let photo = DevelopedPhoto(jpeg: TestSupport.jpegData(width: 16, height: 16), dng: Data([9, 9]), capturedAt: base)
        let id = try await sink.save(photo)

        let contents = try XCTUnwrap(LockedCaptureScan.scan(dir, directSaveGrace: 0))
        XCTAssertTrue(contents.pairs.isEmpty)
        XCTAssertTrue(contents.awaitingDirectSave.isEmpty)
        XCTAssertEqual(contents.saved.count, 1)
        XCTAssertEqual(contents.saved.first?.localIdentifier, "asset-1")
        XCTAssertEqual(contents.saved.first?.files.map(\.lastPathComponent),
                       ["dng", "jpg"].map { URL(fileURLWithPath: id).deletingPathExtension().appendingPathExtension($0).lastPathComponent })
    }

    func testSinkWithFailedDirectSaveFallsBackToImport() async throws {
        let dir = TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = SessionContentSink(root: dir, library: FakeLibrary(result: .failure(UnprocError.notAuthorized)))
        let photo = DevelopedPhoto(jpeg: TestSupport.jpegData(width: 16, height: 16), dng: nil, capturedAt: base)
        let id = try await sink.save(photo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: id), "shot kept on disk")
        XCTAssertFalse(SessionMarker.exists(.saved, forShot: URL(fileURLWithPath: id)), "no marker without a confirmed save")

        let contents = try XCTUnwrap(LockedCaptureScan.scan(dir, directSaveGrace: 0))
        XCTAssertEqual(contents.pairs.count, 1)
        XCTAssertTrue(contents.saved.isEmpty)
    }

    // MARK: - Naming

    func testFileStemIsUniqueAndParses() {
        let a = SessionContentSink.fileStem(for: base)
        let b = SessionContentSink.fileStem(for: base)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix(SessionContentSink.baseName(for: base)))
        XCTAssertNotNil(a.range(of: #"^\d{8}-\d{6}-\d{3}-[0-9a-f]{8}$"#, options: .regularExpression), a)
        XCTAssertNil(LockedCaptureScan.captureDate(fromName: "IMG_0001.JPG"))
    }

    func testBookkeepingKeysUseSessionIDOnly() {
        let one = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/AAA/Library/S1", isDirectory: true)
        let two = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/BBB/Library/S1", isDirectory: true)
        let file = one.appendingPathComponent("x.jpg")
        XCTAssertEqual(LockedCaptureScan.doneKey(session: one, file: file),
                       LockedCaptureScan.doneKey(session: two, file: file),
                       "container path changes must not cause re-imports")
        XCTAssertEqual(LockedCaptureScan.migrateLegacyKey(one.path + "|x.jpg"), "S1|x.jpg")
        XCTAssertNil(LockedCaptureScan.migrateLegacyKey("garbage"))
    }

    // MARK: - Releasing

    func testReleaseDecision() {
        let now = Date()
        let quiet: TimeInterval = 90
        XCTAssertEqual(LockedCaptureScan.release(unimported: 1, appActive: true, lastActivity: .distantPast, now: now, quietPeriod: quiet),
                       .keep("1 item(s) not imported yet"))
        XCTAssertEqual(LockedCaptureScan.release(unimported: 0, appActive: false, lastActivity: .distantPast, now: now, quietPeriod: quiet),
                       .keep("app not in foreground"))
        if case .wait(let seconds) = LockedCaptureScan.release(unimported: 0, appActive: true, lastActivity: now.addingTimeInterval(-30), now: now, quietPeriod: quiet) {
            XCTAssertEqual(seconds, 60, accuracy: 0.01)
        } else {
            XCTFail("recently used session should wait")
        }
        XCTAssertEqual(LockedCaptureScan.release(unimported: 0, appActive: true, lastActivity: now.addingTimeInterval(-91), now: now, quietPeriod: quiet),
                       .invalidate)
    }
}

/// Stand-in for `PhotoLibrarySink` in the extension.
final class FakeLibrary: CaptureSink {
    let result: Result<String, Error>
    let onSave: @Sendable () -> Void

    init(result: Result<String, Error>, onSave: @escaping @Sendable () -> Void = {}) {
        self.result = result
        self.onSave = onSave
    }

    func save(_ photo: DevelopedPhoto) async throws -> PhotoItem.ID {
        onSave()
        return try result.get()
    }
}
