import CoreMotion
import Foundation
import Synchronization
import os

/// How the phone is physically held, from gravity, with hysteresis so a
/// slight tilt never flips a photo to landscape.
///
/// The UI is portrait-only, so photos follow the preview unless the phone is
/// clearly turned sideways. Rotation coordinators alone got this wrong
/// sometimes (stale orientation after lying flat, or right after launch in
/// the lock-screen extension), producing sideways portrait shots.
final class HoldOrientation: @unchecked Sendable {
    enum Hold: String, Sendable {
        case portrait, landscape, unknown
    }

    private let motion = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "lol.peril.unproc.hold"
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private let state = Mutex(Hold.unknown)
    /// Last reading was a real upright hold (not flat, not inferred).
    private let upright = Mutex(false)

    var current: Hold { state.withLock { $0 } }
    /// The phone is visibly held upright right now (gravity mostly along -y),
    /// so the rotation coordinators' readings can be trusted for portrait.
    var isConfidentlyUpright: Bool { upright.withLock { $0 } }
    /// Called (on the motion queue) when the phone becomes confidently upright.
    var onUpright: (@Sendable () -> Void)?

    func start() {
        guard motion.isDeviceMotionAvailable else {
            Log.camera.notice("hold: device motion unavailable; photo orientation from coordinators")
            return
        }
        guard !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 15.0
        motion.startDeviceMotionUpdates(to: queue) { [weak self] data, _ in
            guard let self, let g = data?.gravity else { return }
            self.update(x: g.x, y: g.y, z: g.z)
        }
        Log.camera.info("hold: started")
    }

    func stop() {
        guard motion.isDeviceMotionActive else { return }
        motion.stopDeviceMotionUpdates()
        state.withLock { $0 = .unknown }
        upright.withLock { $0 = false }
        Log.camera.info("hold: stopped")
    }

    private func update(x: Double, y: Double, z: Double) {
        let nowUpright = Self.isUpright(x: x, y: y, z: z)
        let becameUpright = upright.withLock { value -> Bool in
            defer { value = nowUpright }
            return nowUpright && !value
        }
        if becameUpright { onUpright?() }
        let next = Self.classify(x: x, y: y, z: z, previous: current)
        let changed = state.withLock { hold -> Bool in
            guard hold != next else { return false }
            hold = next
            return true
        }
        if changed {
            Log.camera.debug("hold: \(next.rawValue, privacy: .public) (g=\(String(format: "%.2f,%.2f,%.2f", x, y, z), privacy: .public))")
        }
    }

    /// Clearly upright portrait (top of the phone up, not lying flat).
    static func isUpright(x: Double, y: Double, z: Double) -> Bool {
        abs(z) < 0.7 && y < -0.6 && abs(x) < 0.45
    }

    /// Pure classification (unit tested). Flat (screen up/down) keeps the
    /// previous answer (portrait if none yet: the UI is portrait); landscape needs a clear sideways tilt to enter and
    /// a clear upright tilt to leave.
    static func classify(x: Double, y: Double, z: Double, previous: Hold) -> Hold {
        if abs(z) > 0.8 { return previous == .unknown ? .portrait : previous }
        let sideways = abs(x)
        let upright = abs(y)
        switch previous {
        case .landscape:
            return upright > sideways + 0.2 ? .portrait : .landscape
        case .portrait, .unknown:
            return sideways > upright + 0.35 ? .landscape : .portrait
        }
    }
}
