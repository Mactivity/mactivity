import Core
import Foundation

/// argv through `sysctl(KERN_PROCARGS2)`: the person's own processes only, as macOS allows.
public struct LiveProcessArguments: ProcessArgumentReading {
    public init() {}

    public func arguments(_ pid: Int32) -> [String] {
        ProcessInspector.arguments(pid)
    }
}
