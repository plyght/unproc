import Foundation
import ImageIO
import Observation
import UIKit
import os

/// Photos captured in this lock-screen session: `<yyyyMMdd-HHmmss-SSS>.jpg`
/// (+ optional `.dng`, `.saved` / `.deleted` markers) files in the session
/// content directory. Newest first.
@MainActor
@Observable
final class SessionPhotoStore: PhotoStore {
    let root: URL
    private(set) var items: [PhotoItem] = []

    @ObservationIgnored private var pendingReload: Task<Void, Never>?
    private let watcher: DispatchSourceFileSystemObject?

    init(root: URL) {
        self.root = root
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            Log.viewer.error("session store: create folder failed \(root.path, privacy: .public): \(Log.describe(error), privacy: .public)")
        }

        let fd = open(root.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                                   eventMask: [.write, .delete, .rename],
                                                                   queue: .main)
            source.setCancelHandler { close(fd) }
            watcher = source
        } else {
            let err = errno
            Log.viewer.error("session store: cannot watch folder \(root.path, privacy: .public) errno=\(err, privacy: .public)")
            watcher = nil
        }

        items = Self.scan(root)
        Log.viewer.info("session store: init root=\(root.path, privacy: .public) items=\(self.items.count, privacy: .public) watching=\(self.watcher != nil, privacy: .public)")

        watcher?.setEventHandler { [weak self] in
            Log.viewer.debug("session store: folder event")
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
        let changed = found != items
        if changed { items = found }
        Log.viewer.info("session store: reload count=\(found.count, privacy: .public) changed=\(changed, privacy: .public)")
    }

    /// `side` is in points.
    func thumbnail(for item: PhotoItem, side: CGFloat) async -> UIImage? {
        guard case .file(let url) = item.source else {
            Log.viewer.error("session store: thumbnail for non-file item \(item.id, privacy: .public)")
            return nil
        }
        let pixels = Int((max(side, 1) * 3).rounded(.up))
        let image = await Task.detached(priority: .userInitiated) {
            Self.downsample(url, maxPixel: pixels)
        }.value
        if image == nil {
            Log.viewer.error("session store: thumbnail decode failed \(url.lastPathComponent, privacy: .public)")
        }
        return image
    }

    func fullImage(for item: PhotoItem) async -> UIImage? {
        guard case .file(let url) = item.source else {
            Log.viewer.error("session store: full image for non-file item \(item.id, privacy: .public)")
            return nil
        }
        // Decoded off the main thread and capped so a 48 MP frame doesn't
        // cost ~200 MB of memory in the extension.
        let image = await Task.detached(priority: .userInitiated) {
            Self.downsample(url, maxPixel: 4096)
        }.value
        if image == nil {
            Log.viewer.error("session store: full image decode failed \(url.lastPathComponent, privacy: .public)")
        }
        return image
    }

    func delete(_ items: [PhotoItem]) async throws {
        let fm = FileManager.default
        var firstError: Error?
        var removed = Set<String>()
        Log.viewer.notice("session store: deleting \(items.count, privacy: .public) items")
        for item in items {
            guard case .file(let url) = item.source else { continue }
            do {
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
                removed.insert(item.id)
            } catch {
                Log.viewer.error("session store: delete failed \(url.lastPathComponent, privacy: .public): \(Log.describe(error), privacy: .public)")
                if firstError == nil { firstError = error }
                // Keep the RAW if its JPEG couldn't be removed.
                continue
            }
            let base = url.deletingPathExtension()
            for ext in ["dng", "DNG"] {
                let sibling = base.appendingPathExtension(ext)
                if fm.fileExists(atPath: sibling.path) {
                    do {
                        try fm.removeItem(at: sibling)
                    } catch {
                        Log.viewer.error("session store: delete sibling failed \(sibling.lastPathComponent, privacy: .public): \(Log.describe(error), privacy: .public)")
                    }
                }
            }
            // Already saved to Photos by the extension? Leave a `.deleted`
            // marker so the app deletes the asset on its next (foreground)
            // import sweep. Only reached on a committed delete: the viewer's
            // undo happens before `delete` is ever called.
            do {
                if let assetID = try SessionMarker.markDeletedIfSaved(forShot: url) {
                    Log.lockscreen.notice("session store: \(url.lastPathComponent, privacy: .public) was in Photos (\(assetID, privacy: .public)), marked for deletion by the app")
                }
            } catch {
                Log.lockscreen.error("session store: couldn't mark \(url.lastPathComponent, privacy: .public) for deletion from Photos: \(Log.describe(error), privacy: .public)")
            }
        }
        self.items.removeAll { removed.contains($0.id) }
        let removedCount = removed.count
        let errorText = firstError.map(Log.describe) ?? "none"
        Log.viewer.notice("session store: deleted \(removedCount, privacy: .public)/\(items.count, privacy: .public) error=\(errorText, privacy: .public)")
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
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: root,
                                              includingPropertiesForKeys: [.creationDateKey],
                                              options: [.skipsHiddenFiles])
        } catch {
            Log.viewer.error("session store: scan failed \(root.path, privacy: .public): \(Log.describe(error), privacy: .public)")
            urls = []
        }
        let photos: [PhotoItem] = urls.compactMap { url in
            // Only JPEGs: DNG siblings and `.saved` / `.deleted` markers
            // (`SessionMarker`) are never listed.
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
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            Log.viewer.error("session store: CGImageSource failed for \(url.lastPathComponent, privacy: .public)")
            return nil
        }
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
