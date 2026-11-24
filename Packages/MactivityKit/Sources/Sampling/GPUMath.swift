import Core
import Foundation

/// Pure GPU parsing (spec 6.6), kept apart from IOKit so it runs on fixtures.
public enum GPUMath {
    /// System-wide figures from an accelerator's "PerformanceStatistics" dictionary.
    /// Nil if it has no "Device Utilization %".
    public static func stats(performanceStatistics: [String: Any], name: String) -> GPUStats? {
        guard let utilization = PropertyValue.double(performanceStatistics["Device Utilization %"]) else {
            return nil
        }
        return GPUStats(
            name: name,
            utilizationPercent: min(max(utilization, 0), 100),
            memoryInUseBytes: PropertyValue.uint64(performanceStatistics["In use system memory"])
        )
    }

    /// The PID and process name from a user client's "IOUserClientCreator", e.g.
    /// `"pid 410, WindowServer"`. The name is the kernel's 16-character `p_comm`, so it may be cut
    /// short, and may itself contain ", ".
    public static func parseCreator(_ creator: String) -> (pid: Int32, name: String)? {
        guard creator.hasPrefix("pid ") else {
            return nil
        }
        let rest = creator.dropFirst(4)
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard let pid = Int32(digits), pid >= 0 else {
            return nil
        }
        let tail = rest.dropFirst(digits.count)
        let name = tail.hasPrefix(", ") ? String(tail.dropFirst(2)) : String(tail)
        return (pid, name)
    }

    /// Sum of "accumulatedGPUTime" (nanoseconds) over a user client's "AppUsage" array, one
    /// element per command queue API. Nil if the value isn't an array of dictionaries.
    public static func accumulatedGPUTime(appUsage: Any?) -> UInt64? {
        guard let entries = appUsage as? [Any] else {
            return nil
        }
        return entries.reduce(UInt64(0)) { total, entry in
            let time = (entry as? [String: Any]).flatMap { PropertyValue.uint64($0["accumulatedGPUTime"]) } ?? 0
            return total &+ time
        }
    }

    /// Cumulative GPU time per PID over every user client of an accelerator. A process usually
    /// holds several clients (WindowServer holds dozens); their times add up. Clients with a
    /// readable creator and no usage yet appear with 0, so "has a GPU client" is visible too.
    public static func clientGPUTime(clients: [[String: Any]]) -> [Int32: UInt64] {
        var times: [Int32: UInt64] = [:]
        for client in clients {
            guard let creator = client["IOUserClientCreator"] as? String,
                  let pid = parseCreator(creator)?.pid
            else {
                continue
            }
            times[pid, default: 0] &+= accumulatedGPUTime(appUsage: client["AppUsage"]) ?? 0
        }
        return times
    }
}
