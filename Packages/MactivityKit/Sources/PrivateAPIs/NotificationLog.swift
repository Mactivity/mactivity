import Core
import Foundation

/// Which app sent a notification and when, from what `usernoted` writes to the unified log (D-289).
///
/// - Symbol: not a function but two log messages (subsystem `com.apple.unc`, category
///   `application`), read with `/usr/bin/log show`, undocumented. For each notification:
///   `Delivering <NotificationRecord app:"…" … uuid:"E286543B" …> to [ … ]: askBeforePresenting: …`,
///   then `actually deliver E286543B: deliveredChanged: true, …`. Counted when both are there and
///   `deliveredChanged` is true, so each counts once. Checked over a day of real logs on macOS
///   27.2: 240 pairs, always in this order. Left out, as macOS's own lines put it: `… without
///   presentation, just updating existing record` (an update), `… without presenting` with
///   `deliveredChanged: false` (went nowhere), and a system alert shown again with
///   `deliveredChanged: false`. Removals and summaries have other wording, and the predicate
///   never asks for them.
/// - Which shape a line is comes from its `formatString`, not its text: the text holds a category
///   and a request ID that apps choose.
/// - Framework: usernoted and UserNotificationsCore (private).
/// - If Apple changes or removes it: `.unreadable`, for a command that fails, a `Delivering` line
///   of an unknown shape, or one of the two lines without the other. Nothing is recorded and the
///   card says it can't read this. The fallback is no count, as no public API tells this.
/// - macOS keeps these messages for about a day (27 hours seen), so they're read every few hours
///   and Mactivity keeps its own record. Only the app and the time leave this file.
public enum NotificationLog {
    static let predicate = """
    subsystem == "com.apple.unc" AND category == "application" AND process == "usernoted" AND (\
    eventMessage BEGINSWITH "Delivering <NotificationRecord" OR eventMessage BEGINSWITH "actually deliver ")
    """

    static let deliveringFormat = "Delivering %{public}s to %{public}s"
    static let knownShapes = [": askBeforePresenting:", " without presenting.", " without presentation, just updating existing record."]
    static let actuallyFormat = "actually deliver %{public}s"
    static let recordPrefix = "Delivering <NotificationRecord app:\""
    /// Fewer than this of one line with none of the other can be a read cut off mid-pair.
    static let cutOff = 3

    /// Pure: `log show --style ndjson` output as deliveries, oldest first.
    public static func reading(ndjson: Data) -> NotificationLogReading {
        let formatter = LogTimestamp.formatter()
        var waiting: [String: (app: String, at: Date)] = [:]
        var events: [NotificationEvent] = []
        var delivering = 0
        var actually = 0
        var delivered = 0
        for line in ndjson.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let format = entry["formatString"] as? String,
                  let message = entry["eventMessage"] as? String,
                  let stamp = entry["timestamp"] as? String,
                  let at = formatter.date(from: stamp)
            else {
                continue
            }
            if format.hasPrefix(deliveringFormat) {
                guard knownShapes.contains(where: { format.dropFirst(deliveringFormat.count).hasPrefix($0) }),
                      let record = record(in: message)
                else {
                    return .unreadable
                }
                delivering += 1
                waiting[record.uuid] = (record.app, at)
            } else if format.hasPrefix(actuallyFormat) {
                guard let result = deliveredChanged(in: message) else {
                    return .unreadable
                }
                actually += 1
                if result.changed {
                    delivered += 1
                    if let sent = waiting.removeValue(forKey: result.uuid) {
                        events.append(NotificationEvent(at: sent.at, app: sent.app))
                    }
                }
            }
        }
        let oneWithoutTheOther = (delivering >= cutOff && actually == 0) || (actually >= cutOff && delivering == 0)
        let unpaired = delivered >= cutOff && events.isEmpty
        if oneWithoutTheOther || unpaired {
            return .unreadable
        }
        return .read(events.sorted { $0.at < $1.at })
    }

    /// The app and record ID at the start of a `Delivering` line. Both are the record's own
    /// fields, with nothing an app wrote before them but the request ID.
    static func record(in message: String) -> (app: String, uuid: String)? {
        guard message.hasPrefix(recordPrefix) else {
            return nil
        }
        let rest = message.dropFirst(recordPrefix.count)
        guard let end = rest.firstIndex(of: "\""), let uuid = rest.range(of: " uuid:\"") else {
            return nil
        }
        let id = rest[uuid.upperBound...].prefix { $0 != "\"" }
        guard !id.isEmpty, let app = app(String(rest[..<end])) else {
            return nil
        }
        return (app, String(id))
    }

    /// The record's name for its sender as what's kept: macOS's own alerts by their ID, and every
    /// website as one, so a site's name is never stored.
    static func app(_ raw: String) -> String? {
        if raw.hasPrefix("_WEB_CENTER_:") {
            return NotificationEvent.website
        }
        let systemPrefix = "_SYSTEM_CENTER_:"
        let app = raw.hasPrefix(systemPrefix) ? String(raw.dropFirst(systemPrefix.count)) : raw
        return app.isEmpty ? nil : app
    }

    /// "actually deliver E286543B: deliveredChanged: true, alertsChanged: false, …"
    static func deliveredChanged(in message: String) -> (uuid: String, changed: Bool)? {
        let prefix = "actually deliver "
        guard message.hasPrefix(prefix), let colon = message.range(of: ": deliveredChanged: ") else {
            return nil
        }
        let uuid = String(message[message.index(message.startIndex, offsetBy: prefix.count) ..< colon.lowerBound])
        let value = message[colon.upperBound...]
        if value.hasPrefix("true") {
            return (uuid, true)
        }
        return value.hasPrefix("false") ? (uuid, false) : nil
    }

    /// The deliveries between two dates. Blocks while it runs: call it off the main thread.
    public static func read(from: Date, to: Date) -> NotificationLogReading {
        let arguments = [
            "show", "--style", "ndjson", "--start", LogTimestamp.argument(from), "--end", LogTimestamp.argument(to),
            "--predicate", predicate,
        ]
        guard let output = SensorIndicatorLog.run("/usr/bin/log", arguments, timeout: 30) else {
            return .unreadable
        }
        return reading(ndjson: output)
    }
}
