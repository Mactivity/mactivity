import Foundation

/// The keys of a launchd plist that say what runs, when, and for whom (`man launchd.plist`).
public struct LaunchdPlist: Hashable, Sendable, Codable {
    public var label: String?
    public var program: String?
    public var programArguments: [String]
    /// Relative to the owning app's bundle (`SMAppService` agents and daemons).
    public var bundleProgram: String?
    public var runAtLoad: Bool
    public var keepAlive: KeepAlive
    public var startInterval: Int?
    public var calendarIntervals: [CalendarInterval]
    public var associatedBundleIdentifiers: [String]
    public var disabled: Bool
    /// Keys that make launchd start it on demand: `MachServices`, `Sockets`, `WatchPaths`, …
    public var onDemandTriggers: [String]

    public init(
        label: String? = nil,
        program: String? = nil,
        programArguments: [String] = [],
        bundleProgram: String? = nil,
        runAtLoad: Bool = false,
        keepAlive: KeepAlive = .off,
        startInterval: Int? = nil,
        calendarIntervals: [CalendarInterval] = [],
        associatedBundleIdentifiers: [String] = [],
        disabled: Bool = false,
        onDemandTriggers: [String] = []
    ) {
        self.label = label
        self.program = program
        self.programArguments = programArguments
        self.bundleProgram = bundleProgram
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.startInterval = startInterval
        self.calendarIntervals = calendarIntervals
        self.associatedBundleIdentifiers = associatedBundleIdentifiers
        self.disabled = disabled
        self.onDemandTriggers = onDemandTriggers
    }

    public enum ParseError: Error, Equatable {
        /// Not a property list, or not a dictionary at the top.
        case notADictionary
    }

    static let triggerKeys = ["MachServices", "Sockets", "WatchPaths", "QueueDirectories", "StartOnMount", "LaunchEvents"]

    /// Parses XML, binary, or OpenStep plist data.
    public static func parse(_ data: Data) throws -> LaunchdPlist {
        let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = object as? [String: Any] else {
            throw ParseError.notADictionary
        }
        return parse(dictionary)
    }

    /// Parses an already-decoded dictionary. Wrong-typed keys are ignored, as launchd does.
    public static func parse(_ dictionary: [String: Any]) -> LaunchdPlist {
        var plist = LaunchdPlist()
        plist.label = nonEmpty(dictionary["Label"] as? String)
        plist.program = nonEmpty(dictionary["Program"] as? String)
        plist.programArguments = (dictionary["ProgramArguments"] as? [Any])?.compactMap { $0 as? String } ?? []
        plist.bundleProgram = nonEmpty(dictionary["BundleProgram"] as? String)
        plist.runAtLoad = bool(dictionary["RunAtLoad"]) ?? false
        plist.keepAlive = keepAlive(dictionary["KeepAlive"])
        plist.startInterval = int(dictionary["StartInterval"]).flatMap { $0 > 0 ? $0 : nil }
        plist.calendarIntervals = calendarIntervals(dictionary["StartCalendarInterval"])
        plist.associatedBundleIdentifiers = strings(dictionary["AssociatedBundleIdentifiers"])
        plist.disabled = bool(dictionary["Disabled"]) ?? false
        plist.onDemandTriggers = triggerKeys.filter { dictionary[$0] != nil }
        return plist
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string, !string.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        return string
    }

    /// Booleans only; a number or string is not a boolean to launchd.
    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    private static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number.intValue
    }

    /// A string or an array of strings.
    private static func strings(_ value: Any?) -> [String] {
        if let single = value as? String {
            return [single]
        }
        return (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private static func keepAlive(_ value: Any?) -> KeepAlive {
        if let flag = bool(value) {
            return flag ? .always : .off
        }
        if let conditions = value as? [String: Any] {
            return conditions.isEmpty ? .off : .conditions(conditions.keys.sorted())
        }
        return .off
    }

    /// A dictionary or an array of dictionaries.
    private static func calendarIntervals(_ value: Any?) -> [CalendarInterval] {
        let entries: [[String: Any]] = if let one = value as? [String: Any] {
            [one]
        } else {
            (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        }
        return entries.map { entry in
            CalendarInterval(
                minute: int(entry["Minute"]),
                hour: int(entry["Hour"]),
                day: int(entry["Day"]),
                weekday: int(entry["Weekday"]),
                month: int(entry["Month"])
            )
        }
    }

    /// `Program`, else `ProgramArguments[0]`. `BundleProgram` needs the bundle, so it's resolved elsewhere.
    public var declaredExecutable: String? {
        program ?? programArguments.first.flatMap(Self.nonEmpty)
    }

    /// What it runs with, without the executable itself.
    public var extraArguments: [String] {
        Array(programArguments.dropFirst())
    }

    /// The schedule its keys describe.
    public var schedule: StartupSchedule {
        switch keepAlive {
        case .always:
            return .alwaysRunning(conditional: false)
        case .conditions:
            return .alwaysRunning(conditional: true)
        case .off:
            break
        }
        if let startInterval {
            return .interval(seconds: startInterval, atLoad: runAtLoad)
        }
        if !calendarIntervals.isEmpty {
            return .calendar(calendarIntervals, atLoad: runAtLoad)
        }
        return runAtLoad ? .atLoad : .onDemand
    }
}
