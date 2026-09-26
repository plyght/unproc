import SwiftUI

/// Accent focus marker drawn over the viewfinder in PRO mode.
/// Coordinates are normalised to the 3:4 frame ((0,0) top-left).
struct FocusOverlay: View {
    /// Focus/exposure point, nil = centre continuous AF (nothing drawn).
    let point: CGPoint?
    let isTracking: Bool
    let trackedRect: CGRect?
    var side: CGFloat = 58

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(point: CGPoint?, isTracking: Bool, trackedRect: CGRect?, side: CGFloat = 58) {
        self.point = point
        self.isTracking = isTracking
        self.trackedRect = trackedRect
        self.side = side
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                if isTracking, let rect = trackedRect {
                    let frame = CGRect(
                        x: rect.minX * size.width,
                        y: rect.minY * size.height,
                        width: max(rect.width * size.width, 24),
                        height: max(rect.height * size.height, 24)
                    )
                    // Follows the subject: a critically damped spring keeps it smooth and interruptible.
                    Brackets()
                        .stroke(Theme.accent, lineWidth: 1.5)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .transition(.opacity)
                } else if let point {
                    FocusSquare(side: side)
                        .position(x: point.x * size.width, y: point.y * size.height)
                        // New point → new square that lands 1.15 → 1.0. The positioned
                        // view fills the overlay, so the scale anchor is the point itself.
                        .id(PointKey(point))
                        .transition(
                            .asymmetric(
                                insertion: reduceMotion
                                    ? .opacity
                                    : .scale(scale: 1.15, anchor: UnitPoint(x: point.x, y: point.y))
                                        .combined(with: .opacity),
                                removal: .opacity.animation(Theme.exit)
                            )
                        )
                }
            }
            .animation(Theme.snappy, value: trackedRect.map(RectKey.init))
            .animation(Theme.snappy, value: point.map(PointKey.init))
            .animation(Theme.snappy, value: isTracking)
        }
        .allowsHitTesting(false)
    }

    private struct PointKey: Hashable {
        let x: Double, y: Double
        init(_ p: CGPoint) { x = Double(p.x); y = Double(p.y) }
    }

    private struct RectKey: Equatable {
        let x: Double, y: Double, w: Double, h: Double
        init(_ r: CGRect) { x = Double(r.minX); y = Double(r.minY); w = Double(r.width); h = Double(r.height) }
    }
}

/// The tap-to-focus square: full opacity when it lands, then settles to 60 %
/// so it stays readable without competing with the image.
private struct FocusSquare: View {
    let side: CGFloat
    @State private var settled = false

    var body: some View {
        Rectangle()
            .stroke(Theme.accent, lineWidth: 1.2)
            .frame(width: side, height: side)
            .overlay {
                Rectangle().fill(Theme.accent).frame(width: 2, height: 2)
            }
            .opacity(settled ? 0.6 : 1)
            .task {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                withAnimation(Theme.fade) { settled = true }
            }
    }
}

/// Four corner brackets (tracking marker).
private struct Brackets: Shape {
    func path(in rect: CGRect) -> Path {
        let l = min(rect.width, rect.height) * 0.22
        var p = Path()
        // top-left
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + l))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))
        // top-right
        p.move(to: CGPoint(x: rect.maxX - l, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))
        // bottom-right
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - l))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
        // bottom-left
        p.move(to: CGPoint(x: rect.minX + l, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - l))
        return p
    }
}
