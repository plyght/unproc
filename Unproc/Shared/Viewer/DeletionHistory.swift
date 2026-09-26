import Foundation

/// Unlimited undo/redo of "hide this photo" actions. Nothing is actually
/// deleted until the viewer closes and the user confirms; until then hidden
/// items just sit in `pending`.
struct DeletionHistory {
    private(set) var pending: [String: PhotoItem] = [:]
    private var undoStack: [PhotoItem] = []
    private var redoStack: [PhotoItem] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var pendingCount: Int { pending.count }
    var isEmpty: Bool { pending.isEmpty }

    func isHidden(_ id: PhotoItem.ID) -> Bool { pending[id] != nil }

    /// Pending items in the order they appear in `order` (newest first), then any leftovers.
    func pendingItems(orderedLike order: [PhotoItem]) -> [PhotoItem] {
        var result = order.filter { pending[$0.id] != nil }
        let listed = Set(result.map(\.id))
        result += pending.values.filter { !listed.contains($0.id) }
        return result
    }

    mutating func hide(_ item: PhotoItem) {
        guard pending[item.id] == nil else { return }
        pending[item.id] = item
        undoStack.append(item)
        redoStack.removeAll()
    }

    /// Restores the most recently hidden item.
    @discardableResult
    mutating func undo() -> PhotoItem? {
        guard let item = undoStack.popLast() else { return nil }
        pending[item.id] = nil
        redoStack.append(item)
        return item
    }

    /// Hides again the most recently restored item.
    @discardableResult
    mutating func redo() -> PhotoItem? {
        guard let item = redoStack.popLast() else { return nil }
        pending[item.id] = item
        undoStack.append(item)
        return item
    }

    /// Forgets everything (after deleting, or when keeping all).
    mutating func reset() {
        pending.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// The item redo would hide next, if any.
    var nextRedo: PhotoItem? { redoStack.last }
}
