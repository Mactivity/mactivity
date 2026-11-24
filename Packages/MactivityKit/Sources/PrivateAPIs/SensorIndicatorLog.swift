import Core
import Foundation
import os

/// Which app used the camera, a microphone, the screen or the location, from the record macOS's
/// privacy indicators keep (1.8, D-259).
///
/// - Symbol: not a function but a log message. ControlCenter (subsystem `com.apple.controlcenter`,
///   category `sensor-indicators`) logs `Active activity attributions changed to [...]` each time
///   the indicator's set changes, with entries like `"cam:us.zoom.xos"`. The message's wording and
///   the codes (cam, mic, scr, loc) aren't documented anywhere. Read with `/usr/bin/log show`.
/// - Framework: ControlCenter.app and SystemStatus.framework (private).
/// - If Apple changes or removes it: `read` returns nil (the command fails) or no changes (the
///   wording moved), and `LiveSensorActivity` falls back to the public device state: that the
///   camera or a microphone was in use, and when, without which app.
/// - macOS keeps these messages for about two days, so they're read at least every few hours
///   and Mactivity keeps its own history.
public enum SensorIndicatorLog {
    private static let log = Logger(subsystem: "app.mactivity.privateapis", category: "sensor-indicators")

    static let marker = "Active activity attributions changed to "
    static let predicate = """
    subsystem == "com.apple.controlcenter" AND category == "sensor-indicators" AND eventMessage BEGINSWITH "\(marker)"
    """

    /// Pure: the uses in one message, or nil for another message. Codes Mactivity doesn't know
    /// are left out.
    public static func uses(in message: String) -> Set<SensorUse>? {
        guard let range = message.range(of: marker),
              let data = message[range.upperBound...].data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [String]
        else {
            return nil
        }
        return Set(entries.compactMap { entry in
            // Apps always have a bundle ID here; an empty one would read as "unknown app".
            SensorUse(code: entry).flatMap { $0.app == nil ? nil : $0 }
        })
    }

    /// Pure: `log show --style ndjson` output as changes, oldest first.
    public static func changes(ndjson: Data) -> [SensorChange] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        var found: [SensorChange] = []
        for line in ndjson.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = entry["eventMessage"] as? String,
                  let stamp = entry["timestamp"] as? String,
                  let at = formatter.date(from: stamp),
                  let active = uses(in: message)
            else {
                continue
            }
            found.append(SensorChange(at: at, active: active))
        }
        return found.sorted { $0.at < $1.at }
    }

    /// The changes between two dates, or nil when the log can't be read (the command is missing,
    /// fails, or takes over 20 seconds). Blocks while it runs: call it off the main thread.
    public static func read(from: Date, to: Date) -> [SensorChange]? {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
        let arguments = [
            "show", "--style", "ndjson", "--start", stamp.string(from: from), "--end", stamp.string(from: to),
            "--predicate", predicate,
        ]
        guard let output = run("/usr/bin/log", arguments, timeout: 20) else {
            return nil
        }
        return changes(ndjson: output)
    }

    /// Runs a command with nothing on its input; its output, or nil on failure or timeout.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            log.notice("Can't run log: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // Read on another thread while it runs, so a full pipe can't stall it and a hung command
        // can't hold this one past the timeout.
        let collected = Collected()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            collected.data = pipe.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        guard read.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            log.notice("log show took too long")
            return nil
        }
        process.waitUntilExit()
        let output = collected.data
        guard process.terminationStatus == 0 else {
            log.notice("log show failed: \(process.terminationStatus, privacy: .public)")
            return nil
        }
        return output
    }
}

/// The output a reading thread hands back; written once, before the semaphore it waits on.
private final class Collected: @unchecked Sendable {
    var data = Data()
}
