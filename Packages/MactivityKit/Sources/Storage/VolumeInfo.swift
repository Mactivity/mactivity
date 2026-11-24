import Darwin
import Foundation

/// Volume capacity and the Full Disk Access probe. Public APIs only.
public enum VolumeInfo {
    /// The volume holding `url`, from its resource values. nil if they can't be read.
    public static func summary(for url: URL) -> VolumeSummary? {
        let keys: Set<URLResourceKey> = [
            .volumeLocalizedNameKey, .volumeURLKey, .volumeLocalizedFormatDescriptionKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys), let capacity = values.volumeTotalCapacity else {
            return nil
        }
        let available = UInt64(max(0, values.volumeAvailableCapacity ?? 0))
        let important = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) } ?? available
        return VolumeSummary(
            name: values.volumeLocalizedName ?? url.lastPathComponent,
            mountPath: values.volume?.path ?? "/",
            format: values.volumeLocalizedFormatDescription ?? "",
            capacity: UInt64(max(0, capacity)),
            available: available,
            availableForImportantUsage: important
        )
    }

    /// Locations only Full Disk Access can read. EPERM on any of them means it's off. Opening
    /// them never shows a prompt; that's why they're used and Desktop or Documents aren't.
    static func protectedProbes(home: String) -> [String] {
        [
            home + "/Library/Safari",
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Mail",
            "/Library/Application Support/com.apple.TCC/TCC.db",
        ]
    }

    /// Full Disk Access, judged by trying to open protected locations.
    public static func fullDiskAccess(home: String = NSHomeDirectory()) -> FullDiskAccessStatus {
        fullDiskAccess(probing: protectedProbes(home: home))
    }

    static func fullDiskAccess(probing paths: [String]) -> FullDiskAccessStatus {
        var sawDenial = false
        for path in paths {
            let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
            if fd >= 0 {
                close(fd)
                return .granted
            }
            if errno == EPERM || errno == EACCES {
                sawDenial = true
            }
        }
        return sawDenial ? .denied : .unknown
    }

    /// System Settings → Privacy & Security → Full Disk Access.
    public static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
}
