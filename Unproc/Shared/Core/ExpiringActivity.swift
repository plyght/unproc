import Foundation
import os

/// Asks the system for time to finish a piece of work (e.g. developing and
/// writing a shot) if the process is about to be suspended — the lock-screen
/// extension can be dismissed right after the shutter press. Wraps
/// `ProcessInfo.performExpiringActivity`, which works in apps and extensions.
///
/// Call `end()` exactly when the work is done (extra calls are harmless).
final class ExpiringActivity: @unchecked Sendable {
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var ended = false

    private init() {}

    static func begin(_ reason: String) -> ExpiringActivity {
        let activity = ExpiringActivity()
        ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { expired in
            if expired {
                // Either no time was granted or it just ran out.
                Log.save.error("activity: '\(reason, privacy: .public)' expired before it finished")
                activity.end()
            } else {
                // The activity lasts as long as this (background-queue) block runs.
                activity.finished.wait()
            }
        }
        return activity
    }

    func end() {
        lock.lock()
        let first = !ended
        ended = true
        lock.unlock()
        if first { finished.signal() }
    }
}
