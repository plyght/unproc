import Foundation
import XCTest
@testable import Unproc

@MainActor
final class SessionMarkerTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000.25)

    private func withTempDir(_ body: (URL) async throws -> Void) async rethrows {
        let dir = TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }

    private func photo(dng: Data? = nil) -> DevelopedPhoto {
        DevelopedPhoto(jpeg: TestSupport.jpegData(width: 16, height: 16), dng: dng, capturedAt: base)
    }

    // MARK: - Naming / parsing

    func testMarkerNaming() {
        let dir = URL(fileURLWithPath: "/tmp/S1", isDirectory: true)
        let jpg = dir.appendingPathComponent("20240101-120000-000-abcd1234.jpg")
        let dng = dir.appendingPathComponent("20240101-120000-000-abcd1234.dng")
        XCTAssertEqual(SessionMarker.url(.saved, forShot: jpg).lastPathComponent, "20240101-120000-000-abcd1234.saved")
        XCTAssertEqual(SessionMarker.url(.saved, forShot: dng), SessionMarker.url(.saved, forShot: jpg))
        XCTAssertEqual(SessionMarker.url(.deleted, forShot: jpg).lastPathComponent, "20240101-120000-000-abcd1234.deleted")
        XCTAssertEqual(SessionMarker.url(.deleted, forShot: SessionMarker.url(.saved, forShot: jpg)).lastPathComponent,
                       "20240101-120000-000-abcd1234.deleted")

        XCTAssertEqual(SessionMarker.kind(of: dir.appendingPathComponent("a.saved")), .saved)
        XCTAssertEqual(SessionMarker.kind(of: dir.appendingPathComponent("a.DELETED")), .deleted)
        XCTAssertNil(SessionMarker.kind(of: jpg))
        XCTAssertNil(SessionMarker.kind(of: dng))
        XCTAssertFalse(SessionMarker.isMarker(dir.appendingPathComponent("notes.txt")))
    }

    func testRecordRoundTripAndRejectsGarbage() throws {
        let record = SessionMarker.Record(localIdentifier: "ABC-123/L0/001", date: base)
        let data = try SessionMarker.encode(record)
        XCTAssertEqual(SessionMarker.decode(data), record)
        XCTAssertNil(SessionMarker.decode(Data()))
        XCTAssertNil(SessionMarker.decode(Data("not json".utf8)))
        XCTAssertNil(SessionMarker.decode(Data(#"{"date":1}"#.utf8)), "missing identifier")
        XCTAssertNil(SessionMarker.decode(Data(#"{"date":1,"localIdentifier":""}"#.utf8)), "empty identifier")
    }

    // MARK: - Saved / deleted transitions

    func testMarkSavedAndDeleteAfterwards() async throws {
        try await withTempDir { dir in
            let jpg = dir.appendingPathComponent("a.jpg")
            try TestSupport.jpegData(width: 8, height: 8).write(to: jpg)

            XCTAssertNil(try SessionMarker.markDeletedIfSaved(forShot: jpg), "never saved: nothing to delete from Photos")
            XCTAssertFalse(SessionMarker.exists(.deleted, forShot: jpg))

            XCTAssertEqual(try SessionMarker.markSaved(localIdentifier: "id-1", forShot: jpg, now: self.base), .saved)
            XCTAssertEqual(SessionMarker.read(.saved, forShot: jpg)?.localIdentifier, "id-1")

            try FileManager.default.removeItem(at: jpg)
            XCTAssertEqual(try SessionMarker.markDeletedIfSaved(forShot: jpg), "id-1")
            XCTAssertFalse(SessionMarker.exists(.saved, forShot: jpg), ".saved replaced")
            XCTAssertEqual(SessionMarker.read(.deleted, forShot: jpg)?.localIdentifier, "id-1")
        }
    }

    func testMarkSavedAfterViewerDeleteWritesDeletion() async throws {
        try await withTempDir { dir in
            let jpg = dir.appendingPathComponent("gone.jpg")
            XCTAssertEqual(try SessionMarker.markSaved(localIdentifier: "id-2", forShot: jpg), .deleted)
            XCTAssertFalse(SessionMarker.exists(.saved, forShot: jpg))
            XCTAssertEqual(SessionMarker.read(.deleted, forShot: jpg)?.localIdentifier, "id-2")
        }
    }

    // MARK: - Sink + lock-screen viewer

    func testSinkMarksDirectSaveAndViewerIgnoresMarkers() async throws {
        try await withTempDir { dir in
            let sink = SessionContentSink(root: dir, library: FakeLibrary(result: .success("asset-9")))
            let id = try await sink.save(self.photo(dng: Data([1, 2])))
            let jpg = URL(fileURLWithPath: id)
            XCTAssertEqual(SessionMarker.read(.saved, forShot: jpg)?.localIdentifier, "asset-9")

            let store = SessionPhotoStore(root: dir)
            await store.reload()
            XCTAssertEqual(store.items.map { URL(fileURLWithPath: $0.id).lastPathComponent }, [jpg.lastPathComponent],
                           "markers and DNGs are never listed")
        }
    }

    func testSinkWithoutAccessWritesNoMarker() async throws {
        try await withTempDir { dir in
            let sink = SessionContentSink(root: dir, library: FakeLibrary(result: .failure(UnprocError.notAuthorized)))
            let id = try await sink.save(self.photo())
            XCTAssertTrue(FileManager.default.fileExists(atPath: id))
            XCTAssertFalse(SessionMarker.exists(.saved, forShot: URL(fileURLWithPath: id)))
        }
    }

    func testDeleteDuringDirectSaveBecomesDeletion() async throws {
        try await withTempDir { dir in
            // The "viewer" deletes every JPEG while Photos is saving.
            let library = FakeLibrary(result: .success("asset-7")) {
                let fm = FileManager.default
                for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".jpg") {
                    try? fm.removeItem(at: dir.appendingPathComponent(name))
                }
            }
            let id = try await SessionContentSink(root: dir, library: library).save(self.photo())
            let jpg = URL(fileURLWithPath: id)
            XCTAssertFalse(SessionMarker.exists(.saved, forShot: jpg))
            XCTAssertEqual(SessionMarker.read(.deleted, forShot: jpg)?.localIdentifier, "asset-7")
        }
    }

    func testViewerDeleteOfSavedShotLeavesDeletionMarker() async throws {
        try await withTempDir { dir in
            let fm = FileManager.default
            let saved = try await SessionContentSink(root: dir, library: FakeLibrary(result: .success("asset-3")))
                .save(self.photo(dng: Data([7])))
            let unsaved = try await SessionContentSink(root: dir).save(self.photo())
            let store = SessionPhotoStore(root: dir)
            await store.reload()
            XCTAssertEqual(store.items.count, 2)

            try await store.delete(store.items)
            let savedJPG = URL(fileURLWithPath: saved)
            let unsavedJPG = URL(fileURLWithPath: unsaved)
            XCTAssertFalse(fm.fileExists(atPath: saved))
            XCTAssertFalse(fm.fileExists(atPath: savedJPG.deletingPathExtension().appendingPathExtension("dng").path))
            XCTAssertFalse(fm.fileExists(atPath: unsaved))
            XCTAssertFalse(SessionMarker.exists(.saved, forShot: savedJPG))
            XCTAssertEqual(SessionMarker.read(.deleted, forShot: savedJPG)?.localIdentifier, "asset-3", "marker outlives the files")
            XCTAssertFalse(SessionMarker.exists(.deleted, forShot: unsavedJPG), "never in Photos: nothing to delete there")

            await store.reload()
            XCTAssertTrue(store.items.isEmpty, "the deletion marker is not a photo")
        }
    }
}
