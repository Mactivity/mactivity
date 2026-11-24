import Core
import Foundation

/// Per-app activity in fixed-length buckets, as the alert engine reads it.
///
/// Each snapshot's apps are averaged into the bucket its time falls in. A bucket is complete when
/// a snapshot lands in a later one. Points are trimmed so memory stays bounded whatever the
/// sampling cadence: at the default 60-minute window and 5 s buckets, 721 points per app.
struct ActivityRecorder {
    struct Track {
        var app: AppIdentity
        var points: [AppActivityPoint]
        /// Index of the newest completed bucket this app has a point in.
        var lastBucket: Int64
    }

    let bucketLength: TimeInterval
    private(set) var tracks: [AppIdentity.ID: Track] = [:]
    /// The bucket being filled.
    private var bucket: Int64?
    private var pending: [AppIdentity.ID: Accumulator] = [:]
    /// The newest completed bucket.
    private var completedBucket: Int64?

    init(bucketLength: TimeInterval) {
        self.bucketLength = bucketLength
    }

    /// Adds a snapshot's apps that `watched` accepts (all by default). Returns true when it closed
    /// the previous bucket, so there is new activity to evaluate.
    mutating func record(_ snapshot: Snapshot, watched: (AppIdentity) -> Bool = { _ in true }) -> Bool {
        let index = Int64((snapshot.at.timeIntervalSince1970 / bucketLength).rounded(.down))
        var closed = false
        if let current = bucket, index != current {
            if index > current {
                close(current)
                closed = true
            } else {
                // The clock went backwards: drop the partial bucket and anything newer than this snapshot.
                pending.removeAll()
                dropPoints(notBefore: snapshot.at)
            }
        }
        bucket = index
        for app in snapshot.apps where watched(app.app) {
            pending[app.id, default: Accumulator(app: app.app)].add(app, at: snapshot.at)
        }
        return closed
    }

    /// Drops points older than `cutoff` and caps each app at `maxPoints`. Removes apps left empty.
    mutating func trim(olderThan cutoff: Date, maxPoints: Int) {
        for (id, var track) in tracks {
            let stale = track.points.prefix { $0.at < cutoff }.count
            let excess = max(0, track.points.count - stale - max(1, maxPoints))
            let drop = stale + excess
            if drop >= track.points.count {
                tracks[id] = nil
            } else if drop > 0 {
                track.points.removeFirst(drop)
                tracks[id] = track
            }
        }
    }

    /// Histories for the apps present in the newest completed bucket, sorted by app ID. Apps that
    /// have quit aren't alerted about.
    func currentActivity() -> [AppActivityHistory] {
        guard let completedBucket else {
            return []
        }
        return tracks.values
            .filter { $0.lastBucket == completedBucket }
            .sorted { $0.app.id < $1.app.id }
            .map { AppActivityHistory(app: $0.app, points: $0.points) }
    }

    private mutating func close(_ index: Int64) {
        for (id, accumulator) in pending {
            let point = accumulator.point()
            if var track = tracks[id] {
                track.app = accumulator.app
                track.points.append(point)
                track.lastBucket = index
                tracks[id] = track
            } else {
                tracks[id] = Track(app: accumulator.app, points: [point], lastBucket: index)
            }
        }
        pending.removeAll(keepingCapacity: true)
        completedBucket = index
    }

    private mutating func dropPoints(notBefore date: Date) {
        for (id, var track) in tracks {
            track.points.removeAll { $0.at >= date }
            tracks[id] = track.points.isEmpty ? nil : track
        }
    }
}

/// Running sums for one app within one bucket.
private struct Accumulator {
    var app: AppIdentity
    private var count = 0
    private var time: TimeInterval = 0
    private var cpu: Double = 0
    private var memory: Double = 0
    private var disk: Double = 0
    private var netIn: Double = 0
    private var netInCount = 0
    private var netOut: Double = 0
    private var netOutCount = 0

    init(app: AppIdentity) {
        self.app = app
    }

    mutating func add(_ aggregate: AppAggregate, at date: Date) {
        app = aggregate.app
        count += 1
        time += date.timeIntervalSince1970
        cpu += aggregate.cpuPercent
        memory += Double(aggregate.memoryBytes)
        disk += aggregate.diskWriteBPS
        if let value = aggregate.netInBPS {
            netIn += value
            netInCount += 1
        }
        if let value = aggregate.netOutBPS {
            netOut += value
            netOutCount += 1
        }
    }

    /// The bucket's average. Its time is the mean of its snapshots' times.
    func point() -> AppActivityPoint {
        let samples = Double(max(1, count))
        return AppActivityPoint(
            at: Date(timeIntervalSince1970: time / samples),
            cpuPercent: cpu / samples,
            memoryBytes: UInt64((memory / samples).rounded()),
            diskWriteBPS: disk / samples,
            netInBPS: netInCount > 0 ? netIn / Double(netInCount) : nil,
            netOutBPS: netOutCount > 0 ? netOut / Double(netOutCount) : nil
        )
    }
}
