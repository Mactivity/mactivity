import Core
import Foundation
import Sampling

/// Network changes and Wi-Fi over time's recording (D-233, D-234): each change as the path
/// watcher reports it, and the Wi-Fi signal once a minute while joined to one. Real data only.
@MainActor
final class NetworkRecorder {
    private var store: (any NetworkHistoryStore)?
    private var last: (kind: NetworkKind, interface: String?)?
    private var lastWiFiMinute: Int64?

    /// The watcher's changes from now on, and the state it's in.
    func start(watcher: ExpensiveNetworkWatcher) {
        self.watcher = watcher
        watcher.onChange { state in
            Task { @MainActor in NetworkRecorder.shared?.changed(state) }
        }
        Self.shared = self
        changed(watcher.state)
    }

    static var shared: NetworkRecorder?

    /// The pipeline's store; the network it's on now goes in at once, as the log's starting
    /// point (the same network again merges into one stretch when read).
    func attached(to store: any HistoryStore) -> NetworkRecorder {
        attach(store)
        return self
    }

    func attach(_ store: any HistoryStore) {
        self.store = store as? any NetworkHistoryStore
        if let last, let network = self.store {
            let change = NetworkChange(at: Date(), kind: last.kind, interface: last.interface)
            Task { try? await network.recordNetworkChange(change) }
        }
    }

    private weak var watcher: ExpensiveNetworkWatcher?

    /// The Mac is going to sleep, or Mactivity is quitting: the stretch ends here, so a night or
    /// a day closed isn't counted as time on the network before it (D-236).
    func pause(at now: Date = Date()) async {
        guard let store, last?.kind != .asleep else {
            return
        }
        last = (.asleep, nil)
        try? await store.recordNetworkChange(NetworkChange(at: now, kind: .asleep, interface: nil))
    }

    /// Awake again: the network it's on starts a new stretch.
    func resume() {
        if let watcher {
            changed(watcher.state)
        }
    }

    private func changed(_ state: ExpensiveNetworkWatcher.State, at now: Date = Date()) {
        guard state != .unknown, last.map({ $0.kind != state.kind || $0.interface != state.interface }) ?? true else {
            return
        }
        last = (state.kind, state.interface)
        let change = NetworkChange(at: now, kind: state.kind, interface: state.interface)
        if let store {
            Task { try? await store.recordNetworkChange(change) }
        }
    }

    /// Each snapshot: a Wi-Fi reading once a minute.
    func observe(_ snapshot: Snapshot) async {
        let minute = Int64(snapshot.at.timeIntervalSince1970 / 60)
        guard let store, minute != lastWiFiMinute, last?.kind != .offline else {
            return
        }
        lastWiFiMinute = minute
        guard let wifi = LiveNetworkDetails.currentWiFi() else {
            return
        }
        try? await store.recordWiFi(WiFiReading(
            at: snapshot.at, rssi: wifi.rssi, noise: wifi.noise, transmitRate: wifi.transmitRate, channel: wifi.channel
        ))
    }
}
