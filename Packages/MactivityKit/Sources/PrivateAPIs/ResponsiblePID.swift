import Darwin
import Foundation
import os

/// The "responsible" process for a PID: the app macOS attributes a helper, XPC service, or
/// shell child to. Activity Monitor groups by the same value.
public enum ResponsiblePID {
    private static let log = Logger(subsystem: "app.mactivity.privateapis", category: "responsibility")

    typealias Function = @convention(c) (pid_t) -> pid_t

    /// `responsibility_get_pid_responsible_for_pid`, resolved once with `dlsym`.
    ///
    /// - Symbol: `responsibility_get_pid_responsible_for_pid(pid_t) -> pid_t`
    /// - Framework: libquarantine (`/usr/lib/system/libquarantine.dylib`, part of libSystem). Not
    ///   in any public header.
    /// - If Apple removes it: `dlsym` returns nil, this stays nil, and `lookup` returns nil so
    ///   Grouping falls back to the public parent-PID walk (spec 6.2 step 2). Helpers still group
    ///   under the app that launched them; XPC services launched by launchd fall to their bundle
    ///   path or "Other".
    private static let function: Function? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid")
        else {
            log.notice("responsibility_get_pid_responsible_for_pid unavailable; using the ppid walk")
            return nil
        }
        return unsafeBitCast(symbol, to: Function.self)
    }()

    /// Whether the private symbol resolved on this system.
    public static var isAvailable: Bool {
        function != nil
    }

    /// The responsible PID, or nil when the private call is unavailable or fails. Callers fall
    /// back to walking parent PIDs.
    public static func lookup(_ pid: Int32) -> Int32? {
        lookup(pid, using: function)
    }

    /// Testable seam: pass nil to exercise the fallback path.
    static func lookup(_ pid: Int32, using function: Function?) -> Int32? {
        guard let function else {
            return nil
        }
        let responsible = function(pid)
        return responsible > 0 ? responsible : nil
    }
}
