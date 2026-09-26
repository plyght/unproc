import SwiftUI
import UIKit

/// Full-screen viewer: paged photos, film strip, delete with unlimited
/// undo/redo (and shake to undo). Deletions are only applied when the viewer
/// closes and the user confirms.
///
/// Present it with `if showViewer { PhotoViewer(...) }` in the same view tree
/// as the `ThumbnailButton` sharing `namespace`; the button and `onClose` both
/// run inside an animated transaction so the hero transition plays.
struct PhotoViewer: View {
    let store: any PhotoStore
    let namespace: Namespace.ID
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var history = DeletionHistory()
    @State private var currentID: PhotoItem.ID?
    @State private var isZoomed = false
    @State private var confirmingDelete = false
    @State private var isDeleting = false
    /// Dismiss-drag offset held after release while the viewer closes.
    @State private var releasedDrag: CGFloat = 0
    /// Live dismiss-drag offset; springs back by itself if the drag is cancelled.
    @GestureState(resetTransaction: Transaction(animation: ViewerStyle.snapBack))
    private var liveDrag: CGFloat = 0
    /// Page currently playing its "into the bin" exit before it is hidden.
    @State private var leaving: (id: PhotoItem.ID, token: Int, viaRedo: Bool)?
    /// Page just restored by undo, about to play its entrance.
    @State private var arrivingID: PhotoItem.ID?
    @State private var motionToken = 0
    @State private var deleteTick = 0
    @State private var undoTick = 0
    @State private var redoTick = 0

    /// Distance past which letting go dismisses (a flick dismisses sooner).
    private let dismissDistance: CGFloat = 120
    /// Drag distance over which the image shrinks to its smallest and the
    /// background fades out.
    private let dragRange: CGFloat = 400

    init(store: any PhotoStore, namespace: Namespace.ID, onClose: @escaping () -> Void) {
        self.store = store
        self.namespace = namespace
        self.onClose = onClose
        _currentID = State(initialValue: store.items.first?.id)
    }

    // MARK: Derived

    private var visible: [PhotoItem] {
        store.items.filter { !history.isHidden($0.id) }
    }

    private func index(in items: [PhotoItem]) -> Int? {
        guard let currentID else { return nil }
        return items.firstIndex { $0.id == currentID }
    }

    /// Neighbour to land on when `index` goes away: the next (older) one, else the previous.
    private func neighbour(of index: Int, in items: [PhotoItem]) -> PhotoItem? {
        if index + 1 < items.count { return items[index + 1] }
        return index > 0 ? items[index - 1] : nil
    }

    // MARK: Body

    var body: some View {
        let items = visible
        let currentIndex = index(in: items)
        let current = currentIndex.map { items[$0] }
        let drag = liveDrag + releasedDrag
        let progress = min(abs(drag) / dragRange, 1)

        VStack(spacing: 0) {
            topBar(current: current, index: currentIndex, count: items.count)
                .opacity(1 - progress)
                .zIndex(1)

            ZStack {
                if items.isEmpty {
                    emptyState
                        .transition(.opacity)
                } else {
                    pager(items)
                        .offset(y: drag)
                        .scaleEffect(reduceMotion ? 1 : 1 - progress * 0.15)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(0)

            Group {
                if !items.isEmpty {
                    FilmStrip(store: store, items: items, currentID: current?.id) { id in
                        withAnimation(ViewerStyle.ui) { currentID = id }
                    }
                }
                bottomBar(current: current)
            }
            .opacity(1 - progress)
            .zIndex(1)
        }
        .background(
            Color.black
                .opacity(1 - progress * 0.9)
                .ignoresSafeArea()
        )
        .background(ShakeDetector { undo() }.allowsHitTesting(false))
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .confirmationDialog(dialogTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { commitDeletions() }
                .accessibilityIdentifier("viewer.confirmDelete")
            Button("Keep") { keepAllAndClose() }
                .accessibilityIdentifier("viewer.keep")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nothing has been deleted yet.")
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: deleteTick)
        .sensoryFeedback(.impact(weight: .light), trigger: undoTick)
        .sensoryFeedback(.impact(weight: .light), trigger: redoTick)
        // A light tick when the dismiss drag crosses the point of no return.
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: abs(liveDrag) > dismissDistance) { old, new in
            !old && new
        }
        .onAppear { ViewerHeroState.shared.viewerAppeared(namespace) }
        .onDisappear { ViewerHeroState.shared.viewerDisappeared(namespace) }
        .onChange(of: items.map(\.id)) { _, ids in
            if let currentID, ids.contains(currentID) { return }
            currentID = ids.first
        }
    }

    // MARK: Pieces

    private func pager(_ items: [PhotoItem]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(items) { item in
                    PhotoPage(store: store,
                              item: item,
                              namespace: namespace,
                              isCurrent: item.id == currentID,
                              isHero: item.id == currentID && !reduceMotion,
                              isZoomed: $isZoomed)
                        .modifier(PageExitEffect(state: pageState(item.id),
                                                 reduceMotion: reduceMotion))
                        .containerRelativeFrame([.horizontal, .vertical])
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentID)
        .scrollDisabled(isZoomed)
        .simultaneousGesture(dismissGesture, including: isZoomed ? .subviews : .all)
    }

    private func pageState(_ id: PhotoItem.ID) -> PageExitEffect.Phase {
        // Hidden pages stay "gone" while the pager removes them, so they never flash back.
        if leaving?.id == id || arrivingID == id || history.isHidden(id) { return .gone }
        return .shown
    }

    private func topBar(current: PhotoItem?, index: Int?, count: Int) -> some View {
        HStack(spacing: 0) {
            ChromeButton(systemName: "xmark", label: "Close", identifier: "viewer.close") { requestClose() }
            Spacer(minLength: 8)
            Text(index.map { "\($0 + 1)/\(count)" } ?? "0/\(count)")
                .font(ViewerStyle.mono(12))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(ViewerStyle.ui, value: index)
                .animation(ViewerStyle.ui, value: count)
                .padding(.trailing, 16)
        }
        .overlay {
            Text(current.map { ViewerDateFormat.string(from: $0.createdAt) } ?? "")
                .font(ViewerStyle.mono(12))
                .foregroundStyle(.white)
                .lineLimit(1)
                .allowsHitTesting(false)
        }
        .frame(height: 48)
    }

    private func bottomBar(current: PhotoItem?) -> some View {
        HStack(spacing: 0) {
            ChromeButton(systemName: "trash", label: "Delete", identifier: "viewer.delete") { hideCurrent() }
                .disabled(current == nil || isDeleting)
            Spacer(minLength: 8)
            if history.pendingCount > 0 {
                Text("\(history.pendingCount) TO DELETE")
                    .font(ViewerStyle.mono(11))
                    .monospacedDigit()
                    .foregroundStyle(ViewerStyle.accent)
                    .contentTransition(reduceMotion ? .opacity : .numericText())
                    .transition(.opacity)
            }
            Spacer(minLength: 8)
            ChromeButton(systemName: "arrow.uturn.backward", label: "Undo", identifier: "viewer.undo") { undo() }
                .disabled(!(history.canUndo || leaving != nil) || isDeleting)
            ChromeButton(systemName: "arrow.uturn.forward", label: "Redo", identifier: "viewer.redo") { redo() }
                .disabled(!history.canRedo || isDeleting)
        }
        .frame(height: 52)
        .animation(ViewerStyle.ui, value: history.pendingCount)
    }

    private var emptyState: some View {
        Text(history.isEmpty ? "NO PHOTOS YET" : "NO PHOTOS LEFT")
            .font(ViewerStyle.mono(12))
            .tracking(1)
            .foregroundStyle(.white.opacity(0.5))
    }

    private var dialogTitle: String {
        let n = history.pendingCount
        return n == 1 ? "DELETE 1 PHOTO?" : "DELETE \(n) PHOTOS?"
    }

    // MARK: Dismiss drag

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($liveDrag) { value, state, _ in
                let t = value.translation
                // Commit to vertical only once it's clearly vertical, then track 1:1.
                if state != 0 || abs(t.height) > abs(t.width) * 1.3 {
                    state = t.height
                }
            }
            .onEnded { value in
                let t = value.translation
                guard abs(t.height) > abs(t.width) * 1.3 else { return }
                let velocity = value.velocity.height
                // Flicking back towards the start cancels, wherever the finger is.
                let flungBack = t.height * velocity < 0 && abs(velocity) > 200
                let projected = value.predictedEndTranslation.height
                guard !flungBack,
                      abs(t.height) > dismissDistance || abs(projected) > dismissDistance * 2.5 else {
                    return   // `liveDrag` springs back on its own.
                }
                // Hold the image where the finger left it; the hero takes it from there.
                releasedDrag = t.height
                requestClose()
            }
    }

    // MARK: Delete / undo / redo

    private func hideCurrent() {
        let items = visible
        guard let i = index(in: items) else { return }
        let item = items[i]
        guard leaving?.id != item.id else { return }   // already on its way out
        if let inFlight = leaving { commitHide(inFlight) }
        deleteTick += 1
        playExit(of: item, viaRedo: false)
    }

    /// The photo shrinks and fades towards the bin, then the pager moves on.
    private func playExit(of item: PhotoItem, viaRedo: Bool) {
        motionToken += 1
        let token = motionToken
        withAnimation(ViewerStyle.ui, completionCriteria: .logicallyComplete) {
            leaving = (item.id, token, viaRedo)
        } completion: {
            guard let inFlight = leaving, inFlight.token == token else { return }   // interrupted
            commitHide(inFlight)
        }
    }

    /// Actually hides the page that finished (or was cut short in) its exit,
    /// and moves the pager to its neighbour.
    private func commitHide(_ inFlight: (id: PhotoItem.ID, token: Int, viaRedo: Bool)) {
        leaving = nil
        let items = visible
        guard let i = items.firstIndex(where: { $0.id == inFlight.id }) else { return }
        let item = items[i]
        let next = neighbour(of: i, in: items)
        let wasCurrent = inFlight.id == currentID
        withAnimation(ViewerStyle.ui) {
            if inFlight.viaRedo, history.nextRedo?.id == inFlight.id {
                history.redo()
            } else {
                history.hide(item)
            }
            if wasCurrent { currentID = next?.id }
        }
    }

    private func undo() {
        guard !isDeleting else { return }
        // Undo during the exit: reverse it in place, nothing was hidden yet.
        if leaving != nil {
            motionToken += 1
            withAnimation(ViewerStyle.ui) { leaving = nil }
            undoTick += 1
            return
        }
        guard history.canUndo else { return }
        motionToken += 1
        let token = motionToken
        var restoredID: PhotoItem.ID?
        // Step 1: bring it back (invisible) and move the pager to it.
        withAnimation(ViewerStyle.ui, completionCriteria: .logicallyComplete) {
            if let restored = history.undo() {
                restoredID = restored.id
                arrivingID = restored.id
                currentID = restored.id
            }
        } completion: {
            // Step 2: it grows back from where it left — the exit, reversed.
            guard motionToken == token, let restoredID, arrivingID == restoredID else { return }
            withAnimation(ViewerStyle.ui) { arrivingID = nil }
        }
        undoTick += 1
    }

    private func redo() {
        guard !isDeleting, leaving == nil, let target = history.nextRedo else { return }
        if arrivingID == target.id { arrivingID = nil }
        redoTick += 1
        if target.id == currentID {
            playExit(of: target, viaRedo: true)
        } else {
            // Off screen: nothing to watch, just hide it again.
            withAnimation(ViewerStyle.ui) {
                history.redo()
            }
        }
    }

    // MARK: Closing

    private func requestClose() {
        guard !isDeleting else { return }
        if let inFlight = leaving { commitHide(inFlight) }
        if history.isEmpty {
            finish()
        } else {
            withAnimation(ViewerStyle.snapBack) { releasedDrag = 0 }
            confirmingDelete = true
        }
    }

    private func keepAllAndClose() {
        history.reset()
        finish()
    }

    private func commitDeletions() {
        let doomed = history.pendingItems(orderedLike: store.items)
        isDeleting = true
        Task {
            do {
                try await store.delete(doomed)
            } catch {
                // Declined (Photos shows its own prompt) or failed: nothing we
                // hid is gone, so simply show everything again.
            }
            history.reset()
            isDeleting = false
            finish()
        }
    }

    private func finish() {
        withAnimation(ViewerStyle.heroAnimation(reduceMotion: reduceMotion)) {
            ViewerHeroState.shared.setOpen(false, for: namespace)
            onClose()
        }
    }
}

/// The "into the bin" exit (and its reverse for undo): shrink to 0.9 towards
/// the bin in the bottom-left corner and fade. Reduce Motion: fade only.
private struct PageExitEffect: ViewModifier {
    enum Phase { case shown, gone }
    let state: Phase
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        let gone = state == .gone
        return content
            .scaleEffect(gone && !reduceMotion ? 0.9 : 1, anchor: .bottomLeading)
            .opacity(gone ? 0 : 1)
    }
}

// MARK: - Page

/// One page of the pager: shows the best cached image immediately (so the hero
/// has something to grow), then the thumbnail, then the full image.
private struct PhotoPage: View {
    let store: any PhotoStore
    let item: PhotoItem
    let namespace: Namespace.ID
    let isCurrent: Bool
    /// Carries the hero id (current page, unless Reduce Motion is on).
    let isHero: Bool
    @Binding var isZoomed: Bool

    @State private var image: UIImage?

    init(store: any PhotoStore, item: PhotoItem, namespace: Namespace.ID,
         isCurrent: Bool, isHero: Bool, isZoomed: Binding<Bool>) {
        self.store = store
        self.item = item
        self.namespace = namespace
        self.isCurrent = isCurrent
        self.isHero = isHero
        _isZoomed = isZoomed
        _image = State(initialValue: ViewerImageCache.preview(item.id))
    }

    var body: some View {
        ZoomableImage(image: image,
                      heroID: isHero ? ViewerStyle.heroID : "photo-page-\(item.id)",
                      namespace: namespace,
                      isActive: isCurrent,
                      isZoomed: $isZoomed)
            .task(id: item.id) { await load() }
    }

    private func load() async {
        if let full = ViewerImageCache.full(item.id) {
            image = full
            return
        }
        if image == nil {
            if let thumb = await store.thumbnail(for: item, side: 300) {
                ViewerImageCache.setThumb(thumb, for: item.id, side: 300)
                if image == nil { image = thumb }
            }
        }
        guard !Task.isCancelled else { return }
        if let full = await store.fullImage(for: item) {
            ViewerImageCache.setFull(full, for: item.id)
            image = full
        }
    }
}

// MARK: - Chrome

private struct ChromeButton: View {
    let systemName: String
    let label: String
    let identifier: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.28))
                .frame(width: 52, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(ViewerPressStyle())
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(identifier)
    }
}

@MainActor
private enum ViewerDateFormat {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy.MM.dd  HH:mm"
        return formatter
    }()

    static func string(from date: Date) -> String {
        guard date != .distantPast else { return "" }
        return formatter.string(from: date).uppercased()
    }
}
