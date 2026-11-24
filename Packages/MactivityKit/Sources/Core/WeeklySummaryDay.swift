import Foundation

/// When the weekly summary goes out (D-273). Every morning at 9, and Sunday evening at 6. Kept in
/// the app's defaults; Monday morning, as it always was, when nothing's chosen.
public enum WeeklySummaryDay: String, CaseIterable, Identifiable, Sendable {
    case sundayEvening
    case sunday, monday, tuesday, wednesday, thursday, friday, saturday

    public var id: String {
        rawValue
    }

    /// As `Calendar` numbers them: 1 is Sunday.
    public var weekday: Int {
        switch self {
        case .sunday, .sundayEvening: 1
        case .monday: 2
        case .tuesday: 3
        case .wednesday: 4
        case .thursday: 5
        case .friday: 6
        case .saturday: 7
        }
    }

    public var hour: Int {
        self == .sundayEvening ? 18 : 9
    }

    public var isEvening: Bool {
        self == .sundayEvening
    }

    /// The picker's order: the Mac's first day of the week first, Sunday evening right after
    /// Sunday (D-220).
    public static func offered(calendar: Calendar = .current) -> [WeeklySummaryDay] {
        BusiestHours.weekdays(calendar: calendar).flatMap { weekday in
            allCases.filter { $0.weekday == weekday }.sorted { !$0.isEvening && $1.isEvening }
        }
    }

    /// "Monday", or "Sunday evening": in the Mac's language, and from the Mac's calendar.
    public func title(calendar: Calendar = .current) -> String {
        guard !isEvening else {
            return String(localized: "Sunday evening", bundle: .strings, comment: "Weekly summary: sent at 6 pm on Sunday")
        }
        let symbols = calendar.weekdaySymbols
        return symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : ""
    }
}
