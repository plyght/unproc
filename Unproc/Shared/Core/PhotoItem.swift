import AVFoundation
import Foundation
import UIKit

/// An item shown in the in-app viewer / film strip.
struct PhotoItem: Identifiable, Hashable, Sendable {
    enum Source: Hashable, Sendable {
        /// A `PHAsset.localIdentifier` in the user's library.
        case asset(String)
        /// A JPEG on disk (lock-screen session content).
        case file(URL)
    }

    let id: String
    let source: Source
    let createdAt: Date
    /// A movie (shown with a duration badge, played in the viewer).
    var isVideo: Bool = false
    /// Seconds; 0 when unknown or a photo.
    var duration: Double = 0
}

/// Backing store for the viewer. The app uses Photos; the lock-screen extension
/// lists what it captured this session.
@MainActor
protocol PhotoStore: AnyObject, Observable {
    /// Newest first.
    var items: [PhotoItem] { get }
    func reload() async
    func thumbnail(for item: PhotoItem, side: CGFloat) async -> UIImage?
    func fullImage(for item: PhotoItem) async -> UIImage?
    /// Actually removes items (after the user closes the viewer and confirms).
    func delete(_ items: [PhotoItem]) async throws
    /// The playable movie of a video item (nil for photos / unavailable).
    func videoAsset(for item: PhotoItem) async -> AVAsset?
}

extension PhotoStore {
    func videoAsset(for item: PhotoItem) async -> AVAsset? { nil }
}
