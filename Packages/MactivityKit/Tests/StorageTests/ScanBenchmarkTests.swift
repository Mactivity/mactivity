import Darwin
import Foundation
@testable import Storage
import Testing

/// Times a real scan of `MACTIVITY_STORAGE_BENCH` (a folder path). Skipped unless it's set, so
/// `swift test` never walks the live disk.
@Suite("Scan benchmark", .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_STORAGE_BENCH"] != nil))
struct ScanBenchmarkTests {
    @Test("Scan a real folder and report the rate")
    func benchmark() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MACTIVITY_STORAGE_BENCH"])
        let workers = ProcessInfo.processInfo.environment["MACTIVITY_STORAGE_BENCH_WORKERS"].flatMap(Int.init) ?? ProcessInfo.processInfo
            .activeProcessorCount
        let engine = BulkScanEngine(
            root: path,
            options: StorageScanOptions(workers: workers),
            isCancelled: { false },
            progress: { _ in }
        )
        let clock = ContinuousClock()
        let start = clock.now
        let scan = try engine.scan()
        let elapsed = clock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let rate = Int(Double(scan.fileCount + scan.directoryCount) / seconds)
        let summary = "BENCH \(path): \(scan.fileCount) files, \(scan.directoryCount) folders, \(scan.root.size) bytes, "
            + "\(scan.unreadable.count) unreadable, \(scan.skipped.count) skipped in \(elapsed) "
            + "(\(rate) entries/s, \(workers) workers)"
        let footprint = Self.footprint()
        FileHandle.standardError.write(Data("BENCH footprint \(footprint / 1_000_000) MB after the scan\n".utf8))
        FileHandle.standardError.write(Data((summary + "\n").utf8))
        #expect(scan.fileCount > 0)
        withExtendedLifetime(scan) {}
    }

    /// This process's physical footprint, as Activity Monitor's Memory column shows it.
    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
