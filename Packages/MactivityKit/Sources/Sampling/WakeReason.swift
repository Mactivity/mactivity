import Darwin
import Foundation

/// The last wake's reason from `sysctl kern.wakereason` (D-096). A documented sysctl interface,
/// though Apple doesn't document this name's contents: nil when it's missing or empty, and the
/// wake is then recorded without a reason.
public enum WakeReason {
    public static func current() -> String? {
        var size = 0
        guard sysctlbyname("kern.wakereason", nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.wakereason", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let text = String(bytes: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return nil
        }
        return text
    }
}
