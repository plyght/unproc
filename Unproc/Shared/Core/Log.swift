import Foundation
import os

/// Unified logging for unproc. Everything goes to the unified log under the
/// subsystem "lol.peril.unproc", so it shows in Xcode's console, in
/// Console.app (filter: subsystem:lol.peril.unproc) and in the CI run's
/// "App log" step.
///
/// Use `.debug` for chatty per-frame/per-step detail, `.info` for state
/// changes, `.notice` for things worth seeing in a normal log, `.error` for
/// recoverable failures and `.fault` for "this should never happen".
/// Dynamic values are marked `privacy: .public` in call sites where they're
/// not user data (paths, ids, counts, error descriptions), so they're readable
/// outside the debugger.
enum Log {
    static let subsystem = "lol.peril.unproc"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let camera = Logger(subsystem: subsystem, category: "camera")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let controls = Logger(subsystem: subsystem, category: "controls")
    static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    static let save = Logger(subsystem: subsystem, category: "save")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let viewer = Logger(subsystem: subsystem, category: "viewer")
    static let lockscreen = Logger(subsystem: subsystem, category: "lockscreen")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let video = Logger(subsystem: subsystem, category: "video")

    /// Readable description of any error, including NSError domain/code and
    /// the underlying error chain (e.g. "PHPhotosErrorDomain 3300 …").
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var parts = ["\(ns.domain) \(ns.code): \(ns.localizedDescription)"]
        var underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        var depth = 0
        while let u = underlying, depth < 4 {
            parts.append("← \(u.domain) \(u.code): \(u.localizedDescription)")
            underlying = u.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        if let reason = ns.localizedFailureReason { parts.append("reason: \(reason)") }
        return parts.joined(separator: " ")
    }
}
