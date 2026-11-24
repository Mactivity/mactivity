import AppKit
import Core
import Darwin
import Foundation
import IOKit.pwr_mgt

/// What's keeping the Mac awake right now (D-096): `IOPMCopyAssertionsByProcess` (public IOKit),
/// read only while a view that shows it is on screen.
public struct LiveSleepBlockers: SleepBlockerSource {
    public init() {}

    public func blockers() async -> [SleepBlocker] {
        var result: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&result) == kIOReturnSuccess,
              let byProcess = result?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else {
            return []
        }
        let raw = Dictionary(uniqueKeysWithValues: byProcess.map { ($0.key.int32Value, $0.value) })
        return await MainActor.run { Self.blockers(from: raw) { Self.app(forPID: $0, processName: $1) } }
    }

    /// Assertion types that stop the Mac, or its display, from idle-sleeping.
    static let systemTypes: Set = ["PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion"]
    static let displayTypes: Set = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]

    /// Pure: the assertions worth naming. Left out: powerd's own "while the display is on",
    /// released ones (level 0), and timed ones shorter than ten minutes (a download, an AirDrop
    /// advertisement), which end by themselves.
    static func blockers(from raw: [Int32: [[String: Any]]], app: (Int32, String) -> AppIdentity) -> [SleepBlocker] {
        var found: [SleepBlocker] = []
        for (pid, assertions) in raw {
            for assertion in assertions {
                guard let type = assertion["AssertType"] as? String,
                      systemTypes.contains(type) || displayTypes.contains(type),
                      (assertion["AssertLevel"] as? Int ?? 255) > 0
                else {
                    continue
                }
                let process = assertion["Process Name"] as? String ?? "pid \(pid)"
                // powerd's own, and Mactivity's Stay Awake (D-147): asked for, not a surprise.
                if process == "powerd" || assertion["AssertName"] as? String == "Mactivity: Stay Awake" {
                    continue
                }
                if let timeout = assertion["TimeoutSeconds"] as? Double, timeout > 0, timeout < 600 {
                    continue
                }
                let name = assertion["AssertName"] as? String ?? type
                let id = (assertion["AssertionId"] as? NSNumber).map { "\($0)" } ?? "\(pid)-\(name)"
                found.append(SleepBlocker(
                    id: id, pid: pid, app: app(pid, process), reason: name,
                    keeps: displayTypes.contains(type) ? .display : .system,
                    since: assertion["AssertStartWhen"] as? Date
                ))
            }
        }
        return found.sorted { ($0.app.name, $0.reason) < ($1.app.name, $1.reason) }
    }

    /// The app a running process belongs to by name and icon, or the process by its own name.
    /// A daemon that's part of macOS gets the `.system` kind under its own name (D-108).
    @MainActor
    static func app(forPID pid: Int32, processName: String) -> AppIdentity {
        if let path = executablePath(pid), isSystemDaemon(path) {
            return AppIdentity(id: "system:\(processName)", name: processName, bundleID: nil, iconKey: "system", kind: .system)
        }
        if let running = NSRunningApplication(processIdentifier: pid), let name = running.localizedName {
            let bundleID = running.bundleIdentifier
            return AppIdentity(
                id: bundleID ?? "pid:\(pid)", name: name, bundleID: bundleID,
                iconKey: running.bundleURL?.path ?? "other", kind: bundleID == nil ? .other : .app
            )
        }
        return .other(executableName: processName)
    }

    /// Pure: an executable macOS installs outside an app (/usr/libexec/sharingd,
    /// /System/Library/CoreServices/…/bluetoothd). Apple's apps in /System/Applications, like
    /// Music, are apps, and /usr/bin tools like `caffeinate` are something the user started.
    static func isSystemDaemon(_ path: String) -> Bool {
        let systemFolders = ["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/"]
        return systemFolders.contains { path.hasPrefix($0) } && !path.contains(".app/")
    }

    private static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return nil
        }
        return String(bytes: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }
}
