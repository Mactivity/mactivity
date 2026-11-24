import Foundation

/// What wears your SSD (D-281): each app's writes over the last 30 days, beside the internal
/// drive's own lifetime figure. Pure.
///
/// The per-app figures are `ri_diskio_byteswritten` from `proc_pid_rusage`, a count per process
/// with no drive in it, and the whole-Mac figure sums every physical drive. Neither can say how
/// much of it went to the internal SSD, so the card says so; only the drive's own report is that
/// drive alone.
public struct SSDWearReport: Hashable, Sendable {
    /// Apps by bytes written, most first.
    public let writers: [AppTotal]
    /// Every physical drive together over the span, from history.
    public let allDrivesWritten: Double
    /// When the figures start: 30 days ago, or when history does, if that's later.
    public let since: Date
    /// History starts inside the span, so the figures cover less than 30 days.
    public let startsLate: Bool
    /// The internal drive's own report; nil when it doesn't answer.
    public let internalDrive: DriveHealth?

    public init(writers: [AppTotal], allDrivesWritten: Double, since: Date, startsLate: Bool, internalDrive: DriveHealth?) {
        self.writers = writers
        self.allDrivesWritten = allDrivesWritten
        self.since = since
        self.startsLate = startsLate
        self.internalDrive = internalDrive
    }

    public static let span: TimeInterval = 30 * 86400

    public static func make(
        totals: [AppTotal], allDrivesWritten: Double, firstRecorded: Date?, drives: [DriveHealth], now: Date, limit: Int = 6
    ) -> SSDWearReport {
        let start = now.addingTimeInterval(-span)
        let late = firstRecorded.map { $0.timeIntervalSince(start) > SpanTotal.slack } ?? false
        return SSDWearReport(
            writers: Array(totals.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(max(0, limit))),
            allDrivesWritten: allDrivesWritten,
            since: late ? firstRecorded ?? start : start,
            startsLate: late,
            internalDrive: drives.first(where: \.isInternal)
        )
    }
}
