import Core
import Foundation
import Storage

/// Space the cleanups could give back, and what's in the Trash (D-117, D-119). Each figure is
/// nil when macOS won't let Mactivity look.
struct Reclaimable: Sendable, Equatable {
    struct Backups: Sendable, Equatable {
        let bytes: UInt64
        let oldest: Date
    }

    /// Messages attachments older than a year.
    var messages: UInt64?
    /// Device backups older than six months.
    var backups: Backups?
    /// Installers and archives in Downloads that start ticked.
    var downloads: UInt64?
    /// Mail downloads older than 30 days.
    var mail: UInt64?
    /// Developer caches that come back by themselves (D-120).
    var developer: UInt64?
    /// Screenshots and screen recordings over 30 days old (D-122).
    var screenshots: UInt64?
    var trash: UInt64?

    var total: UInt64 {
        (messages ?? 0) + (backups?.bytes ?? 0) + (downloads ?? 0) + (mail ?? 0) + (developer ?? 0) + (screenshots ?? 0)
    }
}

/// Measures `Reclaimable` in the background, at most once per `maxAge`: sizing a large backup
/// walks hundreds of thousands of files, so it never runs on the sampling path, only when Checkup,
/// its menu bar line, or Storage asks, and again after a cleanup moved something.
@MainActor
enum CleanupSummary {
    static var cached: (at: Date, value: Reclaimable)?
    private static var running: Task<Reclaimable, Never>?
    /// Bumped by `invalidate()`: a measurement started before a cleanup isn't kept, nor joined
    /// (D-140). It was, so the card showed the moved files for 10 minutes, Checkup for an hour.
    private static var generation = 0

    static func current(maxAge: TimeInterval = 3600, now: Date = Date()) async -> Reclaimable {
        if let cached, now.timeIntervalSince(cached.at) < maxAge {
            return cached.value
        }
        let started = generation
        let task = running ?? Task.detached(priority: .utility) { measure(now: now) }
        running = task
        let value = await task.value
        guard started == generation else {
            // A cleanup moved files meanwhile: measure again.
            return await current(maxAge: maxAge, now: Date())
        }
        running = nil
        cached = (now, value)
        return value
    }

    /// After a cleanup: the next ask measures again, whatever is in flight.
    static func invalidate() {
        cached = nil
        running = nil
        generation += 1
    }

    nonisolated static func measure(now: Date) -> Reclaimable {
        var value = Reclaimable()
        if let attachments = try? MessagesAttachments.scan() {
            let old = MessagesAttachments.matching(attachments, MessageAttachmentFilter(olderThanDays: 365), now: now)
            value.messages = old.reduce(0) { $0 + $1.size }
        }
        if let scan = try? DeviceBackups.scan() {
            value.backups = oldBackups(scan.backups, now: now)
        }
        if let mail = try? MailDownloads.scan() {
            let cutoff = now.addingTimeInterval(-30 * 86400)
            value.mail = mail.filter { $0.date < cutoff }.reduce(0) { $0 + $1.size }
        }
        // Downloads can raise macOS's Files and Folders prompt; with Full Disk Access it can't,
        // and a prompt should only ever follow a click (D-118).
        if VolumeInfo.fullDiskAccess() == .granted {
            if let items = try? DownloadsLeftovers.scan() {
                value.downloads = items.filter { DownloadsLeftovers.startsTicked($0, now: now) }.reduce(0) { $0 + $1.size }
            }
            // The Desktop, like Downloads, would otherwise ask (D-122).
            if let captures = try? ScreenCaptures.scan() {
                let cutoff = now.addingTimeInterval(-30 * 86400)
                value.screenshots = captures.filter { $0.date < cutoff }.reduce(0) { $0 + $1.size }
            }
        }
        let developer = DeveloperLens.rebuildableItems()
        value.developer = developer.isEmpty ? nil : developer.reduce(0) { $0 + $1.size }
        value.trash = TrashFolder.size()
        return value
    }

    /// Pure: backups last made over six months ago, their total size and the oldest's date. A
    /// backup whose date is unknown isn't called old.
    nonisolated static func oldBackups(_ backups: [DeviceBackup], now: Date) -> Reclaimable.Backups? {
        let cutoff = now.addingTimeInterval(-182 * 86400)
        let old = backups.filter { $0.date.map { $0 < cutoff } ?? false }
        guard let oldest = old.compactMap(\.date).min() else {
            return nil
        }
        return Reclaimable.Backups(bytes: old.reduce(0) { $0 + $1.size }, oldest: oldest)
    }
}
