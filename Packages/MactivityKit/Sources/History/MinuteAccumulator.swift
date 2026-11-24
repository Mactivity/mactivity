import Core
import Foundation

/// Running sum, count, and maximum of one metric over one bucket. Nil inputs are skipped, so an
/// optional metric that was never available stays nil instead of averaging to zero.
struct MetricAccumulator: Hashable {
    private(set) var sum = 0.0
    /// Samples with a value; nil inputs don't count.
    private(set) var reported = 0
    private var maximum = -Double.infinity

    mutating func add(_ value: Double?) {
        guard let value, value.isFinite else {
            return
        }
        sum += value
        reported += 1
        maximum = Swift.max(maximum, value)
    }

    var average: Double? {
        reported > 0 ? sum / Double(reported) : nil
    }

    var max: Double? {
        reported > 0 ? maximum : nil
    }
}

/// One app's accumulators for every metric, in `Metric.allCases` order.
struct BucketAccumulator: Hashable {
    private(set) var samples = 0
    private(set) var metrics = [MetricAccumulator](repeating: MetricAccumulator(), count: Metric.allCases.count)

    mutating func add(_ values: [Double?]) {
        samples += 1
        for index in metrics.indices where index < values.count {
            metrics[index].add(values[index])
        }
    }
}

/// The minute currently being sampled, held in memory until the next minute starts (spec 6.7).
struct MinuteAccumulator {
    /// Bucket start, seconds since 1970.
    let start: Int64
    private(set) var buckets: [AppIdentity.ID: BucketAccumulator] = [:]
    /// Latest identity seen for each app in this minute, upserted into `app` when written.
    private(set) var identities: [AppIdentity.ID: AppIdentity] = [:]

    mutating func add(_ snapshot: Snapshot) {
        buckets[HistorySchema.systemAppID, default: BucketAccumulator()].add(SnapshotValues.system(snapshot))
        for app in snapshot.apps where app.id != HistorySchema.systemAppID {
            buckets[app.id, default: BucketAccumulator()].add(SnapshotValues.app(app))
            identities[app.id] = app.app
        }
    }
}

/// The values one snapshot contributes, in `Metric.allCases` order.
enum SnapshotValues {
    static func app(_ app: AppAggregate) -> [Double?] {
        Metric.allCases.map { app.value(for: $0) }
    }

    /// System-wide figures (`Snapshot.systemValue(for:)`).
    static func system(_ snapshot: Snapshot) -> [Double?] {
        Metric.allCases.map { snapshot.systemValue(for: $0) }
    }
}
