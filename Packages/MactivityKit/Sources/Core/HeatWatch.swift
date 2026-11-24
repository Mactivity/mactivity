import Foundation

/// How long the Mac spent slowed down to cool in the last 10 minutes (thermal pressure serious
/// or worse), fed each snapshot, for the "Mac running hot" alert (D-149). Each snapshot counts
/// until the next one, up to a minute, so a gap (sleep, a stalled sampler) is never heat.
public struct HeatWatch: Sendable {
    public static let window: TimeInterval = 600
    private var samples: [(at: Date, isHot: Bool)] = []

    public init() {}

    /// Records one snapshot's thermal pressure and returns the hot minutes in the window.
    public mutating func record(_ thermal: ThermalPressure?, at now: Date) -> Double {
        samples.removeAll { now.timeIntervalSince($0.at) > Self.window || $0.at > now }
        samples.append((now, thermal.map { $0 >= .serious } ?? false))
        var seconds = 0.0
        for index in samples.indices where samples[index].isHot {
            let next = index + 1 < samples.count ? samples[index + 1].at : now
            seconds += min(60, next.timeIntervalSince(samples[index].at))
        }
        return seconds / 60
    }

    /// The app working hardest in a snapshot, to name in the alert.
    public static func busiest(_ snapshot: Snapshot) -> String? {
        snapshot.apps.filter { $0.app.kind == .app }.max { $0.cpuPercent < $1.cpuPercent }.map(\.app.name)
    }
}
