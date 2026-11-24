import Core
import Foundation

/// Every third renderer is an extension (D-154), for previews and simulated data.
public struct SimulatedProcessArguments: ProcessArgumentReading {
    public init() {}

    public func arguments(_ pid: Int32) -> [String] {
        pid % 3 == 0 ? ["--type=renderer", "--extension-process"] : ["--type=renderer"]
    }
}
