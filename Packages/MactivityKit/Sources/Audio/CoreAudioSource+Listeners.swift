import CoreAudio
import Foundation

/// HAL listeners. All event-driven: nothing here polls. They exist only while the feature is on or a tap exists.
extension CoreAudioSource {

    // MARK: - Callbacks

    /// Stops IO while a tapped app is quiet (so the output device can sleep) and restarts it when it plays. For a
    /// remembered app without a tap, playing is when its settings reapply.
    func runningOutputChanged(_ pid: Int32) async {
        guard let process = known[pid] else {
            return
        }
        let running = HAL.isRunningOutput(process.object)
        Self.log.debug("Pid \(pid, privacy: .public) running output: \(running)")
        guard let rig = table.rigs[pid] else {
            if running, isEnabled, !blocked.contains(pid) {
                await reconcileQuietly(pid, devices: try? currentDevices())
            }
            return
        }
        if running, !rig.isRunning {
            do {
                try await startAndProbe(pid, token: rig.token)
            } catch {
                if error as? AudioVolumeError == .permissionDenied {
                    blocked.insert(pid)
                }
                Self.log.error("Couldn't resume tap for pid \(pid, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        } else if !running, rig.isRunning {
            table.rigs[pid]?.stop()
        }
    }

    /// A device came or went (headphones plugged in or out, AirPlay, Mactivity's own aggregates).
    func devicesChanged() async {
        deviceListChanges += 1
        await reconcileAll()
    }

    func processListChanged() async {
        guard let infos = try? processInfos() else {
            return
        }
        await sync(infos, apply: true)
    }

    // MARK: - Plumbing

    /// System listeners (default output, device list, process list) run while the feature is on or any tap exists.
    func updateSystemListeners() {
        let needed = isEnabled || !table.rigs.isEmpty
        if needed, table.systemListeners.isEmpty {
            let changes: [(AudioObjectPropertySelector, @Sendable (CoreAudioSource) async -> Void)] = [
                (kAudioHardwarePropertyDefaultOutputDevice, { await $0.reconcileAll() }),
                (kAudioHardwarePropertyDevices, { await $0.devicesChanged() }),
                (kAudioHardwarePropertyProcessObjectList, { await $0.processListChanged() }),
            ]
            for (selector, handler) in changes {
                if let block = addListener(to: HAL.system, selector: selector, action: { [weak self] in
                    Task {
                        if let self {
                            await handler(self)
                        }
                    }
                }) {
                    table.systemListeners.append((HAL.address(selector), block))
                }
            }
        } else if !needed, !table.systemListeners.isEmpty {
            table.removeSystemListeners()
        }
    }

    /// Listens on exactly the processes `ReapplyPlanner.watched` names. The listener is on
    /// `kAudioProcessPropertyIsRunning`, and the callback reads `IsRunningOutput`: on macOS 27, Core Audio never
    /// notifies `IsRunningOutput` itself (checked live: `IsRunning` and output `Devices` fire when afplay starts,
    /// `IsRunningOutput` doesn't).
    func refreshWatches() {
        let wanted = ReapplyPlanner.watched(
            keys: known.mapValues(\.key), memory: memory, tapped: Set(table.rigs.keys), enabled: isEnabled
        )
        for pid in Array(table.watches.keys) where !wanted.contains(pid) {
            table.unwatch(pid)
        }
        for pid in wanted where table.watches[pid] == nil {
            guard let process = known[pid] else {
                continue
            }
            if let block = addListener(to: process.object, selector: RigTable.watchedSelector, action: { [weak self] in
                Task { await self?.runningOutputChanged(pid) }
            }) {
                table.watches[pid] = RigTable.Watch(object: process.object, block: block)
            }
        }
    }

    private func addListener(
        to object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        action: @escaping @Sendable () -> Void
    ) -> AudioObjectPropertyListenerBlock? {
        var address = HAL.address(selector)
        let block = Self.listenerBlock(action)
        let status = AudioObjectAddPropertyListenerBlock(object, &address, RigTable.listenerQueue, block)
        guard status == noErr else {
            Self.log.error("Couldn't listen to \(selector, privacy: .public) on \(object, privacy: .public): \(status)")
            return nil
        }
        return block
    }

    /// Built outside the actor so the block carries no actor isolation (Core Audio calls it on `listenerQueue`).
    private nonisolated static func listenerBlock(_ action: @escaping @Sendable () -> Void) -> AudioObjectPropertyListenerBlock {
        { _, _ in action() }
    }
}

/// The Core Audio objects `CoreAudioSource` owns. A class so its `deinit` can tear everything down
/// without touching actor state from a nonisolated context.
final class RigTable {
    /// Core Audio calls every listener block here. Removal matches on the queue too, so it's one shared queue.
    static let listenerQueue = DispatchQueue(label: "app.mactivity.audio.listeners")

    /// What a process watch listens to. See `CoreAudioSource.refreshWatches()`.
    static let watchedSelector = kAudioProcessPropertyIsRunning

    /// A `watchedSelector` listener on one process.
    struct Watch {
        let object: AudioObjectID
        let block: AudioObjectPropertyListenerBlock
    }

    var rigs: [Int32: TapRig] = [:]
    var watches: [Int32: Watch] = [:]
    var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    deinit {
        for pid in Array(rigs.keys) {
            guard var rig = rigs.removeValue(forKey: pid) else {
                continue
            }
            rig.destroy()
        }
        for pid in Array(watches.keys) {
            unwatch(pid)
        }
        removeSystemListeners()
    }

    func unwatch(_ pid: Int32) {
        guard let watch = watches.removeValue(forKey: pid) else {
            return
        }
        var address = HAL.address(Self.watchedSelector)
        AudioObjectRemovePropertyListenerBlock(watch.object, &address, Self.listenerQueue, watch.block)
    }

    func removeSystemListeners() {
        for (address, block) in systemListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(HAL.system, &address, Self.listenerQueue, block)
        }
        systemListeners.removeAll()
    }
}
