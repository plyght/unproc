#if UNPROC_APP
import Foundation
import Observation
import Photos
import UIKit

/// The user's photo library, newest first (most recent ~300 images).
@MainActor
@Observable
final class LibraryPhotoStore: PhotoStore {
    static let fetchLimit = 300

    private(set) var items: [PhotoItem] = []
    /// Last known authorization, for UI that wants to explain an empty library.
    private(set) var authorization: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    @ObservationIgnored private var assets: [String: PHAsset] = [:]
    @ObservationIgnored private var isObserving = false
    @ObservationIgnored private var pendingReload: Task<Void, Never>?
    private let imageManager = PHCachingImageManager()
    private let observer = LibraryChangeObserver()

    init() {
        observer.onChange = { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.scheduleReload() }
        }
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(observer)
    }

    // MARK: PhotoStore

    func reload() async {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        authorization = status
        guard status == .authorized || status == .limited else {
            assets = [:]
            if !items.isEmpty { items = [] }
            return
        }
        if !isObserving {
            isObserving = true
            PHPhotoLibrary.shared().register(observer)
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = Self.fetchLimit
        let result = PHAsset.fetchAssets(with: .image, options: options)

        var newItems: [PhotoItem] = []
        var newAssets: [String: PHAsset] = [:]
        newItems.reserveCapacity(result.count)
        for index in 0..<result.count {
            let asset = result.object(at: index)
            let id = asset.localIdentifier
            newAssets[id] = asset
            newItems.append(PhotoItem(id: id, source: .asset(id), createdAt: asset.creationDate ?? .distantPast))
        }
        assets = newAssets
        if newItems != items { items = newItems }
    }

    /// `side` is in points.
    func thumbnail(for item: PhotoItem, side: CGFloat) async -> UIImage? {
        guard let asset = asset(for: item) else { return nil }
        let pixels = max(side, 1) * 3
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await requestImage(for: asset,
                                  targetSize: CGSize(width: pixels, height: pixels),
                                  contentMode: .aspectFill,
                                  options: options)
    }

    func fullImage(for item: PhotoItem) async -> UIImage? {
        guard let asset = asset(for: item) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        // Big enough for 5× zoom on a phone without decoding 48 MP into memory.
        let longSide: CGFloat = 4096
        return await requestImage(for: asset,
                                  targetSize: CGSize(width: longSide, height: longSide),
                                  contentMode: .aspectFit,
                                  options: options)
    }

    /// iOS presents its own confirmation; throws if the user declines it.
    func delete(_ items: [PhotoItem]) async throws {
        let ids: [String] = items.compactMap {
            if case .asset(let id) = $0.source { return id }
            return nil
        }
        guard !ids.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            let doomed = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            PHAssetChangeRequest.deleteAssets(doomed as NSFastEnumeration)
        }
        let removed = Set(ids)
        for id in ids { assets[id] = nil }
        self.items.removeAll { removed.contains($0.id) }
    }

    // MARK: Private

    private func asset(for item: PhotoItem) -> PHAsset? {
        let id: String
        switch item.source {
        case .asset(let identifier): id = identifier
        case .file: return nil
        }
        if let cached = assets[id] { return cached }
        return PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// Coalesces bursts of library change notifications.
    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    /// Bridges Photos' callback API (which may call back several times with
    /// degraded images) to async, resuming exactly once.
    private func requestImage(for asset: PHAsset,
                              targetSize: CGSize,
                              contentMode: PHImageContentMode,
                              options: PHImageRequestOptions) async -> UIImage? {
        let manager = imageManager
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let gate = ResumeOnce(continuation)
            manager.requestImage(for: asset,
                                 targetSize: targetSize,
                                 contentMode: contentMode,
                                 options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let failed = info?[PHImageErrorKey] != nil
                if degraded && !cancelled && !failed {
                    // A better image will follow; keep this one as a fallback.
                    gate.remember(image)
                    return
                }
                gate.resume(image)
            }
        }
    }
}

/// Resumes a continuation at most once, from any thread.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var fallback: UIImage?

    init(_ continuation: CheckedContinuation<UIImage?, Never>) {
        self.continuation = continuation
    }

    func remember(_ image: UIImage?) {
        lock.lock()
        if let image { fallback = image }
        lock.unlock()
    }

    func resume(_ image: UIImage?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let result = image ?? fallback
        lock.unlock()
        pending?.resume(returning: result)
    }
}

/// `PHPhotoLibraryChangeObserver` must be an NSObject; the store isn't.
private final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    var onChange: (@Sendable () -> Void)?

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange?()
    }
}
#endif
