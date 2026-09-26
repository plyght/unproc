import Foundation
import ImageIO
import Observation
import UIKit

/// Photos captured in this lock-screen session: `<yyyyMMdd-HHmmss-SSS>.jpg`
/// (+ optional `.dng`) files in the session content directory. Newest first.
@MainActor
@Observable
final class SessionPhotoStore: PhotoStore {
    let root: URL
    private(set) var items: [PhotoItem] = []

    @ObservationIgnored private var pendingReload: Task<Void, Never>?
    private let watcher: DispatchSourceFileSystemObject?

    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fd = open(root.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                                   eventMask: [.write, .delete, .rename],
                                                                   queue: .main)
            source.setCancelHandler { close(fd) }
            watcher = source
        } else {
            watcher = nil
        }

        items = Self.scan(root)

        watcher?.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.scheduleReload() }
        }
        watcher?.resume()
    }

    deinit {
        watcher?.cancel()
    }

    // MARK: PhotoStore

    func reload() async {
        let found = Self.scan(root)
        if found != items { items = found }
    }

    /// `side` is in points.
    func thumbnail(for item: PhotoItem, side: CGFloat) async -> UIImage? {
        guard case .file(let url) = item.source else { return nil }
        let pixels = Int((max(side, 1) * 3).rounded(.up))
        return await Task.detached(priority: .userInitiated) {
            Self.downsample(url, maxPixel: pixels)
        }.value
    }

    func fullImage(for item: PhotoItem) async -> UIImage? {
        guard case .file(let url) = item.source else { return nil }
        // Decoded off the main thread and capped so a 48 MP frame doesn't
        // cost ~200 MB of memory in the extension.
        return await Task.detached(priority: .userInitiated) {
            Self.downsample(url, maxPixel: 4096)
        }.value
    }

    func delete(_ items: [PhotoItem]) async throws {
        let fm = FileManager.default
        var firstError: Error?
        var removed = Set<String>()
        for item in items {
            guard case .file(let url) = item.source else { continue }
            do {
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
                removed.insert(item.id)
            } catch {
                if firstError == nil { firstError = error }
            }
            let base = url.deletingPathExtension()
            for ext in ["dng", "DNG"] {
                let sibling = base.appendingPathExtension(ext)
                if fm.fileExists(atPath: sibling.path) { try? fm.removeItem(at: sibling) }
            }
        }
        self.items.removeAll { removed.contains($0.id) }
        if let firstError { throw firstError }
    }

    // MARK: Private

    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    private static func scan(_ root: URL) -> [PhotoItem] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: root,
                                                includingPropertiesForKeys: [.creationDateKey],
                                                options: [.skipsHiddenFiles])) ?? []
        let photos: [PhotoItem] = urls.compactMap { url in
            guard url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "jpeg" else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            let created = parseDate(name)
                ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? .distantPast
            return PhotoItem(id: url.path, source: .file(url), createdAt: created)
        }
        return photos.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id > $1.id
        }
    }

    private static let nameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    private static func parseDate(_ name: String) -> Date? {
        nameFormatter.date(from: String(name.prefix(19)))
    }

    nonisolated private static func downsample(_ url: URL, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
