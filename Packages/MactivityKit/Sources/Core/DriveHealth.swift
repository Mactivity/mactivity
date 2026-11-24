import Foundation

/// A drive's own health report (D-157), from NVMe SMART: how much of its rated life it has used,
/// its spare blocks, what it has written, and the warnings it raises itself.
public struct DriveHealth: Hashable, Sendable, Identifiable {
    public enum Verdict: Hashable, Sendable {
        case good
        /// 80% or more of its rated life used: plan a replacement.
        case worn
        /// The drive warns about itself, its spare is below its threshold, or it has lost data.
        case failing
    }

    public var id: String {
        "\(model)#\(index)"
    }

    public let index: Int
    public let model: String
    public let isInternal: Bool
    /// The maker's estimate of rated life used, percent; can pass 100.
    public let percentUsed: Int
    public let availableSpare: Int
    public let spareThreshold: Int
    /// NVMe critical warning bits: spare, temperature, reliability, read-only, backup.
    public let criticalWarning: Int
    public let temperatureCelsius: Double?
    public let bytesRead: UInt64
    public let bytesWritten: UInt64
    public let powerOnHours: UInt64
    public let unsafeShutdowns: UInt64
    public let mediaErrors: UInt64

    public init(
        index: Int, model: String, isInternal: Bool, percentUsed: Int, availableSpare: Int, spareThreshold: Int,
        criticalWarning: Int, temperatureCelsius: Double?, bytesRead: UInt64, bytesWritten: UInt64, powerOnHours: UInt64,
        unsafeShutdowns: UInt64, mediaErrors: UInt64
    ) {
        self.index = index
        self.model = model
        self.isInternal = isInternal
        self.percentUsed = percentUsed
        self.availableSpare = availableSpare
        self.spareThreshold = spareThreshold
        self.criticalWarning = criticalWarning
        self.temperatureCelsius = temperatureCelsius
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.powerOnHours = powerOnHours
        self.unsafeShutdowns = unsafeShutdowns
        self.mediaErrors = mediaErrors
    }

    /// NVMe counts data in units of 1,000 sectors of 512 bytes.
    public static let dataUnitBytes: UInt64 = 512_000

    public var verdict: Verdict {
        // Bit 5 (persistent memory) isn't a fault; bit 0–4 are.
        if criticalWarning & 0x1F != 0 || (spareThreshold > 0 && availableSpare < spareThreshold) || mediaErrors > 0 {
            return .failing
        }
        return percentUsed >= 80 ? .worn : .good
    }

    /// What's wrong, in plain words; nil when nothing is.
    public var problem: String? {
        if criticalWarning & 0x08 != 0 {
            return String(localized: "The drive has switched itself to read-only to protect your data.", bundle: .strings)
        }
        if criticalWarning & 0x04 != 0 || mediaErrors > 0 {
            return String(localized: "The drive reports errors reading or keeping data.", bundle: .strings)
        }
        if criticalWarning & 0x01 != 0 || (spareThreshold > 0 && availableSpare < spareThreshold) {
            return String(localized: "The drive is running out of spare space to replace worn blocks.", bundle: .strings)
        }
        if criticalWarning & 0x02 != 0 {
            return String(localized: "The drive reports running too hot.", bundle: .strings)
        }
        if percentUsed >= 80 {
            let used = Formatters.percent(Double(percentUsed))
            return String(localized: "\(used) of its rated life is used.", bundle: .strings)
        }
        return nil
    }
}

public protocol DriveHealthSource: Sendable {
    /// Every drive that reports NVMe SMART; the internal one first.
    func drives() async -> [DriveHealth]
}
