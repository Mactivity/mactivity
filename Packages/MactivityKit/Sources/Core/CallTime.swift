import Foundation

/// Time in calls (1.9, D-262): from camera and microphone history, the stretches an app had the
/// microphone for two minutes or more, with or without the camera. Apps that record or listen
/// for dictation aren't calls. Pure.
public enum CallTime {
    /// Shorter than this, it's a voice message or a quick test, not a call.
    public static let minimum: TimeInterval = 120

    /// Apps that use the microphone without anyone on the other end.
    public static let notCalls: Set<String> = [
        "com.apple.VoiceMemos", "com.apple.QuickTimePlayerX", "com.apple.garageband10", "com.apple.logic10",
        "com.apple.SpeechRecognitionCore.speechrecognitiond", "com.apple.Siri", "com.apple.assistantd",
        "com.apple.corespeechd", "com.apple.ScreenSharing",
    ]

    /// Pure: the calls among these sessions, newest first.
    public static func calls(_ sessions: [SensorSession], now: Date) -> [SensorMoment] {
        SensorMoment.moments(sessions, now: now).filter { moment in
            moment.sensors.contains(.microphone)
                && !(moment.app.map(notCalls.contains) ?? false)
                && (moment.end ?? now).timeIntervalSince(moment.start) >= minimum
        }
    }

    /// Pure: seconds in calls for each of the last `days` days (today last), a call over midnight
    /// split between its two days.
    public static func perDay(_ calls: [SensorMoment], days: Int, now: Date, calendar: Calendar = .current) -> [(
        day: Date,
        seconds: TimeInterval
    )] {
        let today = calendar.startOfDay(for: now)
        return (0 ..< days).reversed().compactMap { back in
            guard let start = calendar.date(byAdding: .day, value: -back, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start)
            else {
                return nil
            }
            let seconds = calls.reduce(0.0) { total, call in
                let from = max(call.start, start)
                let to = min(call.end ?? now, end, now)
                return total + max(0, to.timeIntervalSince(from))
            }
            return (start, seconds)
        }
    }

    /// Pure: each app's seconds in calls, most first.
    public static func byApp(_ calls: [SensorMoment], from: Date, now: Date) -> [(app: String?, seconds: TimeInterval)] {
        var seconds: [String: TimeInterval] = [:]
        var unknown: TimeInterval = 0
        for call in calls {
            let length = max(0, min(call.end ?? now, now).timeIntervalSince(max(call.start, from)))
            if let app = call.app {
                seconds[app, default: 0] += length
            } else {
                unknown += length
            }
        }
        var found: [(app: String?, seconds: TimeInterval)] = seconds.map { ($0.key, $0.value) }.sorted { ($0.seconds, $1.app ?? "") > (
            $1.seconds,
            $0.app ?? ""
        ) }
        if unknown > 0 {
            found.append((nil, unknown))
        }
        return found.filter { $0.seconds > 0 }
    }
}
