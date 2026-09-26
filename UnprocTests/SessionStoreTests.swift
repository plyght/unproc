import Foundation
import UIKit
import XCTest
@testable import Unproc

@MainActor
final class SessionStoreTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000.25)

    private func photo(at date: Date, dng: Data? = nil, size: Int = 40) -> DevelopedPhoto {
        DevelopedPhoto(jpeg: TestSupport.jpegData(width: size, height: size * 4 / 3), dng: dng, capturedAt: date)
    }

    private func name(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private func names(_ items: [PhotoItem]) -> [String] {
        items.map { name($0.id) }
    }

    private func withTempDir(_ body: (URL) async throws -> Void) async rethrows {
        let dir = TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }

    func testBaseNameFormat() {
        let name = SessionContentSink.baseName(for: base)
        XCTAssertEqual(name.count, 19)
        XCTAssertNotNil(name.range(of: #"^\d{8}-\d{6}-\d{3}$"#, options: .regularExpression), name)
        XCTAssertTrue(name.hasSuffix("-250"), "milliseconds should be encoded: \(name)")
    }

    func testSaveListThumbnailAndDelete() async throws {
        try await withTempDir { dir in
            let fm = FileManager.default
            let sink = SessionContentSink(root: dir)
            let dngBytes = Data("pretend-dng".utf8)

            let olderID = try await sink.save(photo(at: base, dng: dngBytes))
            let newerID = try await sink.save(photo(at: base.addingTimeInterval(5)))

            XCTAssertTrue(olderID.hasSuffix(".jpg"))
            XCTAssertTrue(newerID.hasSuffix(".jpg"))
            XCTAssertNotEqual(olderID, newerID)
            XCTAssertTrue(fm.fileExists(atPath: olderID))
            XCTAssertTrue(fm.fileExists(atPath: newerID))
            let olderDNG = URL(fileURLWithPath: olderID).deletingPathExtension().appendingPathExtension("dng")
            let newerDNG = URL(fileURLWithPath: newerID).deletingPathExtension().appendingPathExtension("dng")
            XCTAssertTrue(fm.fileExists(atPath: olderDNG.path))
            XCTAssertEqual(try Data(contentsOf: olderDNG), dngBytes)
            XCTAssertFalse(fm.fileExists(atPath: newerDNG.path))

            let store = SessionPhotoStore(root: dir)
            await store.reload()
            XCTAssertEqual(store.items.count, 2, "only JPEGs are listed")
            XCTAssertEqual(names(store.items), [name(newerID), name(olderID)], "newest first")
            XCTAssertEqual(store.items[0].createdAt.timeIntervalSince1970,
                           base.addingTimeInterval(5).timeIntervalSince1970, accuracy: 0.002)
            XCTAssertEqual(store.items[1].createdAt.timeIntervalSince1970,
                           base.timeIntervalSince1970, accuracy: 0.002)

            let thumb = await store.thumbnail(for: store.items[0], side: 20)
            XCTAssertNotNil(thumb)
            if let thumb {
                XCTAssertLessThanOrEqual(max(thumb.size.width * thumb.scale, thumb.size.height * thumb.scale), 60)
            }
            let full = await store.fullImage(for: store.items[1])
            XCTAssertNotNil(full)

            let older = store.items[1]
            try await store.delete([older])
            XCTAssertFalse(fm.fileExists(atPath: olderID), "JPEG removed")
            XCTAssertFalse(fm.fileExists(atPath: olderDNG.path), "its DNG sibling removed too")
            XCTAssertTrue(fm.fileExists(atPath: newerID), "other photo untouched")
            XCTAssertEqual(names(store.items), [name(newerID)])

            await store.reload()
            XCTAssertEqual(names(store.items), [name(newerID)])
        }
    }

    func testSameTimestampNeverOverwrites() async throws {
        try await withTempDir { dir in
            let sink = SessionContentSink(root: dir)
            let a = try await sink.save(photo(at: base, size: 20))
            let b = try await sink.save(photo(at: base, size: 24))
            let c = try await sink.save(photo(at: base, dng: Data([1, 2, 3]), size: 28))
            XCTAssertEqual(Set([a, b, c]).count, 3)
            for path in [a, b, c] { XCTAssertTrue(FileManager.default.fileExists(atPath: path)) }

            let store = SessionPhotoStore(root: dir)
            await store.reload()
            XCTAssertEqual(store.items.count, 3)
            XCTAssertEqual(Set(names(store.items)), Set([a, b, c].map(name)))
        }
    }

    func testSinkCreatesMissingDirectory() async throws {
        try await withTempDir { dir in
            let nested = dir.appendingPathComponent("a/b/c", isDirectory: true)
            let id = try await SessionContentSink(root: nested).save(photo(at: base))
            XCTAssertTrue(FileManager.default.fileExists(atPath: id))
        }
    }

    func testStoreIgnoresNonJPEGFilesAndParsesForeignNames() async throws {
        try await withTempDir { dir in
            let jpeg = TestSupport.jpegData(width: 8, height: 8)
            try Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))
            try Data("x".utf8).write(to: dir.appendingPathComponent("orphan.dng"))
            try Data("x".utf8).write(to: dir.appendingPathComponent(".hidden.jpg"))
            try jpeg.write(to: dir.appendingPathComponent("IMG_0001.JPG"))
            try jpeg.write(to: dir.appendingPathComponent("20240101-120000-000.jpeg"))

            let store = SessionPhotoStore(root: dir)
            await store.reload()
            XCTAssertEqual(Set(names(store.items)), ["IMG_0001.JPG", "20240101-120000-000.jpeg"])
            for item in store.items {
                XCTAssertNotEqual(item.createdAt, .distantPast)
            }
        }
    }

    func testEmptyStore() async {
        await withTempDir { dir in
            let store = SessionPhotoStore(root: dir)
            await store.reload()
            XCTAssertTrue(store.items.isEmpty)
        }
    }

    func testThumbnailOfMissingFileIsNil() async {
        await withTempDir { dir in
            let store = SessionPhotoStore(root: dir)
            let ghost = PhotoItem(id: "ghost", source: .file(dir.appendingPathComponent("ghost.jpg")), createdAt: Date())
            let thumb = await store.thumbnail(for: ghost, side: 40)
            XCTAssertNil(thumb)
            let asset = PhotoItem(id: "asset", source: .asset("x"), createdAt: Date())
            let assetThumb = await store.thumbnail(for: asset, side: 40)
            XCTAssertNil(assetThumb)
        }
    }

    func testDeletingMissingFileDoesNotThrow() async throws {
        try await withTempDir { dir in
            let store = SessionPhotoStore(root: dir)
            let ghost = PhotoItem(id: "ghost", source: .file(dir.appendingPathComponent("ghost.jpg")), createdAt: Date())
            try await store.delete([ghost])
        }
    }
}
