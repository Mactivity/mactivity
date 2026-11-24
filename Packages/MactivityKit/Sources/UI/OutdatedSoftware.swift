import Core
import Foundation
import Observation
import os
import Simulated

/// Outdated Software (1.6.5, D-252): what's installed, what needs updating for security, and
/// the confirmed upgrade of Homebrew formulae.
@MainActor
@Observable
public final class OutdatedSoftwareModel {
    private static let logger = Logger(subsystem: "app.mactivity.ui", category: "software")
    /// The vulnerability check runs at most once a day on its own.
    static let checkEvery: TimeInterval = 86400
    /// The local read, at most every 6 hours from the 10-minute checks.
    static let readEvery: TimeInterval = 6 * 3600

    var isPresented = false
    private(set) var items: [InstalledSoftware] = []
    private(set) var isLoading = false
    private(set) var readAt: Date?
    private(set) var isChecking = false
    /// The last vulnerability check, kept across launches.
    private(set) var scan: SavedScan?

    /// Upgrade: the formulae asked about, what Homebrew says will change, and the outcome.
    var confirming: [String]?
    private(set) var plan: [String] = []
    private(set) var isUpgrading = false
    var outcome: String?

    @ObservationIgnored private var source: any InstalledSoftwareSource
    @ObservationIgnored private let defaults: UserDefaults

    public struct SavedScan: Codable, Equatable, Sendable {
        public let found: [String: [Vulnerability]]
        public let skipped: [String]
        public let at: Date
    }

    public init(source: any InstalledSoftwareSource = SimulatedInstalledSoftware(), defaults: UserDefaults = .standard) {
        self.source = source
        self.defaults = defaults
        scan = defaults.data(forKey: PreferenceKey.vulnerabilityScan).flatMap { try? JSONDecoder().decode(SavedScan.self, from: $0) }
    }

    /// Simulated data on or off: another set of software, and no check from the other one.
    func setSource(_ source: any InstalledSoftwareSource) {
        self.source = source
        items = []
        readAt = nil
        confirming = nil
    }

    var checksVulnerabilities: Bool {
        defaults.bool(forKey: PreferenceKey.checksVulnerabilities)
    }

    /// Pure: each item with the last check's vulnerabilities, by Homebrew formula name.
    static func merged(_ items: [InstalledSoftware], scan: SavedScan?) -> [InstalledSoftware] {
        guard let scan else {
            return items
        }
        return items.map { item in
            guard item.origin == .homebrew, let found = scan.found[item.name], !found.isEmpty else {
                return item
            }
            var item = item
            item.vulnerabilities = found
            return item
        }
    }

    /// What needs updating, most urgent first.
    public func findings(now: Date = Date()) -> [(item: InstalledSoftware, concern: SoftwareConcern)] {
        SoftwareAssessment.needingAttention(Self.merged(items, scan: checksVulnerabilities ? scan : nil), now: now)
            .map { (item: $0.0, concern: $0.1) }
    }

    /// Everything else installed, current or nearly so: for the sheet's last section.
    func upToDate(now: Date = Date()) -> [InstalledSoftware] {
        let listed = Set(findings(now: now).map(\.item.id))
        return items.filter { !listed.contains($0.id) && $0.onRequest }.sorted { $0.title < $1.title }
    }

    public func open() {
        isPresented = true
        Task { await refresh(force: true) }
    }

    /// Reads what's installed (local, about 0.3 s), unless it was read recently; and, with the
    /// check on, checks for vulnerabilities once a day.
    public func refresh(force: Bool = false, now: Date = Date()) async {
        if force || readAt.map({ now.timeIntervalSince($0) >= Self.readEvery }) ?? true {
            isLoading = items.isEmpty
            items = await source.installed()
            readAt = now
            isLoading = false
        }
        if checksVulnerabilities, scan.map({ now.timeIntervalSince($0.at) >= Self.checkEvery }) ?? true {
            await checkNow(now: now)
        }
    }

    /// Homebrew's vulnerability check, now: from the sheet's Check Now, or once a day.
    func checkNow(now: Date = Date()) async {
        guard checksVulnerabilities, !isChecking else {
            return
        }
        isChecking = true
        defer { isChecking = false }
        guard let result = await source.vulnerabilities() else {
            Self.logger.error("The vulnerability check didn't run")
            return
        }
        let saved = SavedScan(found: result.found, skipped: result.skipped, at: now)
        scan = saved
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: PreferenceKey.vulnerabilityScan)
        }
    }

    // MARK: Upgrade

    /// Asks before upgrading: reads what Homebrew will change, then shows the confirmation.
    func askToUpgrade(_ formulae: [String]) async {
        guard !formulae.isEmpty, !isUpgrading else {
            return
        }
        plan = await source.upgradePlan(formulae)
        confirming = formulae
    }

    /// The person confirmed: only here is an `UpgradeConfirmation` made (D-252).
    func confirmUpgrade() async {
        guard let formulae = confirming, !isUpgrading else {
            return
        }
        confirming = nil
        isUpgrading = true
        let result = await source.upgrade(UpgradeConfirmation(formulae: formulae, confirmedAt: Date()))
        isUpgrading = false
        let names = formulae.formatted(.list(type: .and))
        outcome = result.succeeded
            ? String(localized: "Upgraded \(names).", bundle: .strings, comment: "Outdated Software: after brew upgrade")
            : String(
                localized: "Homebrew couldn't upgrade \(names). Run brew upgrade in Terminal to see why.",
                bundle: .strings,
                comment: "Outdated Software: brew upgrade failed"
            )
        await refresh(force: true)
        if checksVulnerabilities, result.succeeded {
            await checkNow()
        }
    }

    func cancelUpgrade() {
        confirming = nil
        plan = []
    }
}
