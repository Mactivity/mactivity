import Alerts
import AppKit
import Audio
import Core
import Docker
import Foundation
import Grouping
import History
import Observation
import os
import Projects
import Protections
import Readouts
import Sampling
import Sensors
import Simulated
import Startup
import Storage
import UI

extension AppModel {
    /// The sources behind the inspector, sleep, crashes, updates, Storage and Network details:
    /// live, or simulated ones together.
    func replaceSystemSources(simulated: Bool) {
        services.audio = simulated ? SimulatedAudioSource() : Self.audio
        services.processDetails = simulated ? SimulatedProcessDetailsSource() : Self.processDetails
        services.processArguments = simulated ? SimulatedProcessArguments() : LiveProcessArguments()
        services.driveHealth = simulated ? SimulatedDriveHealth() : LiveDriveHealth()
        services.sleepBlockers = simulated ? SimulatedSleepBlockers() : LiveSleepBlockers()
        services.crashReports = simulated ? SimulatedCrashReports() : LiveCrashReports()
        services.softwareUpdates = simulated ? SimulatedSoftwareUpdates() : LiveSoftwareUpdates()
        services.macReports = simulated ? SimulatedMacReports() : LiveMacReports()
        services.storageScanner = simulated ? SimulatedStorageScanner() : LiveStorageScanner()
        services.projectSpaceScanner = simulated ? SimulatedProjectSpaceScanner() : LiveProjectSpaceScanner()
        services.homebrewSource = simulated ? SimulatedHomebrewServices() : LiveHomebrewServices()
        services.softwareSource = simulated ? SimulatedInstalledSoftware() : LiveInstalledSoftware()
        services.devDeviceSource = simulated ? SimulatedDevDevices() : LiveDevDevices { LiveStorageScanner.allocatedSize($0) }
        services.devToolSource = simulated ? SimulatedDevTools() : LiveDevTools()
        services.openPortSource = simulated ? SimulatedOpenPorts() : LiveOpenPorts()
        services.localDatabaseSource = simulated ? SimulatedLocalDatabases() : LiveLocalDatabases()
        services.projectGlanceSource = simulated ? SimulatedProjectGlance() : LiveProjectGlance()
        services.remoteSessionSource = simulated ? SimulatedRemoteSessions() : LiveRemoteSessions()
        services.signatureSource = simulated ? SimulatedCodeSignatures() : LiveCodeSignatures()
        services.securitySource = simulated ? SimulatedSecurity() : LiveSecurity()
        services.deskSource = simulated ? SimulatedDesk() : LiveDesk()
        services.networkDetails.replaceSource(simulated ? SimulatedNetworkDetails() : LiveNetworkDetails())
        services.networkInterfaces.replaceSource(simulated ? SimulatedNetworkInterfaces() : LiveNetworkInterfaces())
        services.wifiChannels.replaceSource(simulated ? SimulatedWiFiScan() : LiveWiFiScan())
        services.profiles.replaceSource(simulated ? SimulatedProfiles() : LiveProfiles())
        services.unlocks.replaceSource(simulated ? SimulatedUnlocks() : LiveUnlocks())
        services.notifications.replaceSource(simulated ? SimulatedNotificationLog() : LiveNotificationLog())
        services.photosLibrary.replaceSource(simulated ? SimulatedPhotosLibrary() : LivePhotosLibrary())
        services.mountedDrives.replaceSource(simulated ? SimulatedMountedDrives() : LiveMountedDrives(), watchesMounts: !simulated)
    }
}

extension AppModel {
    /// The real samplers, the helper's process list among them.
    static func liveSampler() -> SnapshotSampler {
        SnapshotSampler(sources: .init(
            cpu: CPUSampler(),
            memory: MemorySampler(),
            disk: DiskSampler(),
            network: NetworkSampler(),
            gpu: GPUSampler(),
            battery: BatterySampler(),
            processes: helperSource,
            resolver: LiveAppResolver(),
            sensors: SensorSampler(keyCache: SensorKeyCache(defaults: .standard)),
            processNetwork: ProcessNetworkSampler(),
            thermal: { ThermalReader.current() }
        ))
    }
}

extension AppModel {
    /// Notifications that wait while the person presents or is on a call, then come as one
    /// (1.6). Settings → Alerts turns it off.
    static func holdingDeliverer() -> HoldingDeliverer {
        let notifications = NotificationDeliverer()
        return HoldingDeliverer(
            inner: notifications,
            presenting: LivePresenting(),
            isEnabled: { UserDefaults.standard.object(forKey: PreferenceKey.holdsAlertsWhilePresenting) as? Bool ?? true },
            summary: { try await notifications.deliverHeldSummary(title: $0, body: $1) }
        )
    }
}
